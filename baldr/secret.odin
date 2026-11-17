package baldr

// Secrets in the OS keychain: a token or a password an app must
// not leave in a file. The desktop keeps it — GNOME Keyring or KWallet over
// the Secret Service on Linux, Credential Manager on Windows — behind
// whatever lock the person already has.
//
// They are commands, like file IO, because a keyring can take its time: it
// may be locked, and unlocking it shows the person a prompt. Nothing waits
// on the main thread.
//
//	case Sign_In:  return baldr.secret_set(Msg, "acme", "openai", token,
//	                   on_done = proc(e: baldr.Ev(baldr.Secret)) -> Msg { return Stored{e.value.status} })
//	case Start:    return baldr.secret_get(Msg, "acme", "openai",
//	                   proc(e: baldr.Ev(baldr.Secret)) -> Msg { return Token{e.value} })
//	case Sign_Out: return baldr.secret_delete(Msg, "acme", "openai")
//
// A call says *why* it did not do what was asked, because an app's answer
// differs: `.Not_Found` means ask the person to sign in again; `.No_Keyring`
// means this desktop has none and the app must decide for itself whether a
// file is acceptable; `.Locked` means "unlock your keyring" — a locked one is
// asked to unlock first, for a write as for a read, and this is what is left
// when it could not be; `.Denied` means the person dismissed its prompt; and
// `.Failed` that the keyring itself went wrong. Baldr never writes a secret
// to a file on its own.
//
// Name the service for the app (its reverse-DNS id, say): two apps that pass
// the same service and account share one secret, as the keyring sees it.

import "base:intrinsics"
import "base:runtime"
import "core:strings"
import "core:thread"

// Secret_Status is how a keychain call ended.
Secret_Status :: enum u8 {
	Ok,          // stored, deleted, or found
	Not_Found,   // the keyring works and holds no such secret
	No_Keyring,  // this desktop has no keyring (or it refused to start)
	Denied,      // the person said no: they dismissed the keyring's prompt
	Locked,      // the keyring is locked and nothing could unlock it: tell the person to unlock their keyring
	Failed,      // something else went wrong; `error` says what
}

// Secret is what a lookup found. `value` is the app's to keep — and to
// scrub when it is done with it (`secret_scrub`), the way a password
// field's text is. It is empty unless `status` is `.Ok`. `error` and the
// names live only while the message is handled; clone what you keep.
Secret :: struct {
	service: string,
	account: string,
	value:   []u8,
	status:  Secret_Status,
	error:   string, // what failed, when the status is .Failed
}

// secret_get looks a secret up by service and account. The handler gets a
// `Secret` whose `value` is the app's, and `secret_scrub` frees it without
// leaving the bytes behind in freed memory.
//
// Keychain calls run one at a time, in the order they were asked for, so an
// app may ask for all three of its secrets at once: a locked keyring
// prompts on the first and the rest go through behind it. None of them
// blocks the run loop, and the handlers are called as each answers.
secret_get :: proc($Msg: typeid, service, account: string, on_done: Handler(Msg, Secret), tag: u64 = 0) -> Cmd(Msg) {
	return {kind = .Secret_Get, service = temp_clone(service), account = temp_clone(account), on_secret = on_done, tag = tag}
}

// secret_set stores (or replaces) a secret. `value` is copied at once, and
// the copy is scrubbed once the keyring has it. It takes its turn in the
// keychain queue, so a `secret_get` of the same account asked for after it
// reads back what was written rather than racing it.
secret_set :: proc($Msg: typeid, service, account: string, value: []u8, on_done: Handler(Msg, Secret) = nil, tag: u64 = 0) -> Cmd(Msg) {
	bytes := make([]u8, len(value), context.temp_allocator) // the command outlives the update that wrote it
	copy(bytes, value)
	return {kind = .Secret_Set, service = temp_clone(service), account = temp_clone(account), bytes = bytes,
		on_secret = on_done, tag = tag}
}

// secret_delete removes a secret — signing out. `.Not_Found` is not an
// error: there was nothing to remove.
secret_delete :: proc($Msg: typeid, service, account: string, on_done: Handler(Msg, Secret) = nil, tag: u64 = 0) -> Cmd(Msg) {
	return {kind = .Secret_Delete, service = temp_clone(service), account = temp_clone(account),
		on_secret = on_done, tag = tag}
}

// secret_scrub overwrites a secret's bytes and frees them, or overwrites
// any buffer in place. Call it as soon as the value has been used: a token
// left in freed memory is a token in whatever allocation lands there next.
//
//	baldr.secret_scrub(&s.token)            // the Secret a get handed over
//	baldr.secret_scrub(header[:])           // the line it was pasted into
//
// The bytes go through volatile stores, because a plain loop over memory
// about to be freed is exactly what an optimiser removes. The buffer form
// only overwrites: whoever made it still frees it.
secret_scrub :: proc{secret_scrub_value, secret_scrub_bytes}

// secret_scrub_value overwrites a secret's bytes and frees them. Call it
// through `secret_scrub`.
secret_scrub_value :: proc(s: ^Secret, allocator := context.allocator) {
	if s == nil do return
	secret_scrub_bytes(s.value)
	if len(s.value) > 0 do delete(s.value, allocator)
	s.value = nil
	s.status = .Not_Found
}

// secret_scrub_bytes overwrites `b` in place and frees nothing. Call it
// through `secret_scrub`.
secret_scrub_bytes :: proc(b: []u8) {
	for i in 0 ..< len(b) do intrinsics.volatile_store(&b[i], 0)
}

// ------------------------------------------------------------- runtime

// Keychain calls run one at a time, in the order the app asked, on a thread
// each. A locked keyring prompts on the first call, and the calls behind it
// go through on the collection the person just unlocked; run together, each
// would ask the Secret Service to unlock and could get a prompt of its own.
// The order also means a set followed by a get of the same account reads
// back what was just written, instead of racing it.

// Secret_Op is one keychain call: queued, then run on a thread of its own,
// because it may sit on a prompt for as long as the person takes and the
// run loop must not.
@(private)
Secret_Op :: struct($Msg: typeid) {
	kind:      Cmd_Kind,
	service:   string, // owned
	account:   string, // owned
	value:     []u8,   // owned: what to store, then what was found
	status:    Secret_Status,
	error:     string, // owned
	tag:       u64,
	on_secret: Handler(Msg, Secret), // every kind answers with a Secret: it carries *why*, which a bare status cannot
	mailbox:   ^Mailbox(Msg),
	allocator: runtime.Allocator,
	thread:    ^thread.Thread,
}

// secret_run queues one keychain call and returns at once; it starts now if
// the keyring is free, and when its turn comes if it is not. What differs
// between a Secret Service, a Credential Manager and a Keychain is
// `secret_platform`, and nothing else.
@(private)
secret_run :: proc(mailbox: ^Mailbox($Msg), cmd: Cmd(Msg)) {
	op := new(Secret_Op(Msg))
	op^ = Secret_Op(Msg){
		kind = cmd.kind,
		service = strings.clone(cmd.service),
		account = strings.clone(cmd.account),
		tag = cmd.tag,
		on_secret = cmd.on_secret,
		mailbox = mailbox,
		allocator = context.allocator,
	}
	if cmd.kind == .Secret_Set {
		op.value = make([]u8, len(cmd.bytes))
		copy(op.value, cmd.bytes)
		secret_scrub_bytes(cmd.bytes) // the command's copy, which would otherwise wait in freed temporary memory
	}
	append(&mailbox.secret_queue, op)
	secret_next(mailbox)
}

// secret_next starts the call at the head of the queue, if the keyring is
// free. mailbox_drain calls it again as each one answers, so the queue
// empties in order. Never called with the mailbox's lock held: the thread it
// starts may finish and post before it returns.
@(private)
secret_next :: proc(mb: ^Mailbox($Msg)) {
	// A nested proc, as a job's worker is: it needs this Msg, and a proc
	// literal of its own cannot name it.
	secret_main :: proc(p: rawptr) {
		op := (^Secret_Op(Msg))(p)
		context.allocator = op.allocator
		secret_platform(op)
		mailbox_post(op.mailbox, Mail(Msg){secret = op}) // last: the op is the mailbox's now
	}
	for !mb.secret_busy && len(mb.secret_queue) > 0 {
		op := mb.secret_queue[0]
		ordered_remove(&mb.secret_queue, 0) // in the order the app asked
		if t := thread.create_and_start_with_data(op, secret_main); t != nil {
			op.thread = t
			mb.secret_busy = true
			return
		}
		// No thread to give it: say so rather than leave the app waiting,
		// and go on to the next — one failure must not stall the queue.
		op.status = .Failed
		op.error = strings.clone("no thread for the keyring", op.allocator)
		mailbox_post(mb, Mail(Msg){secret = op})
	}
}

// secret_op_free scrubs and frees an op once its message has been handled.
@(private)
secret_op_free :: proc(op: ^Secret_Op($Msg), value_too := true) {
	if op == nil do return
	if value_too {
		secret_scrub_bytes(op.value)
		if len(op.value) > 0 do delete(op.value, op.allocator)
	}
	delete(op.service, op.allocator)
	delete(op.account, op.allocator)
	if len(op.error) > 0 do delete(op.error, op.allocator)
	if op.thread != nil do thread.destroy(op.thread)
	free(op, op.allocator)
}

// secret_fail fills an op in with a message of its own. The platform side
// calls it, so "no keyring here" reads the same on every desktop.
@(private)
secret_fail :: proc(op: ^Secret_Op($Msg), status: Secret_Status, why: string = "") {
	op.status = status
	if len(why) > 0 && len(op.error) == 0 do op.error = strings.clone(why)
}
