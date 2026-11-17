#+build linux
package baldr

// The Linux keychain backend: the Secret Service (org.freedesktop.secrets),
// which GNOME Keyring and KWallet both answer. Runs on the op's own thread,
// so every call here may block: a locked keyring prompts the person.
//
// The session is "plain": the secret crosses the session bus unencrypted.
// An encrypted session would hide it from a program watching the bus, but
// only this user's programs can watch it, and any of those may simply ask
// the keyring for the same secret: the Secret Service does not tell one of
// a user's programs from another. The bytes are zeroed once read, here and
// in the D-Bus buffers they passed through.

import "baldr:dbus"
import "core:strings"

@(private = "file") SECRETS_NAME    :: "org.freedesktop.secrets"
@(private = "file") SERVICE_PATH    :: "/org/freedesktop/secrets"
@(private = "file") SERVICE_IFACE   :: "org.freedesktop.Secret.Service"
@(private = "file") ITEM_IFACE      :: "org.freedesktop.Secret.Item"
@(private = "file") COLLECTION_IFACE :: "org.freedesktop.Secret.Collection"
@(private = "file") IS_LOCKED       :: "org.freedesktop.Secret.Error.IsLocked"
@(private = "file") PROMPT_IFACE    :: "org.freedesktop.Secret.Prompt"
@(private = "file") DEFAULT_ALIAS   :: "/org/freedesktop/secrets/aliases/default"
@(private = "file") CALL_MS         :: i32(25_000) // a person may be typing their login password
@(private = "file") PROMPT_MS       :: i32(120_000)

// secret_platform does one keychain call and fills the op in.
@(private)
secret_platform :: proc(op: ^Secret_Op($Msg)) {
	conn, cerr := dbus.connect_session(context.allocator)
	if cerr != .None || conn == nil {
		secret_fail(op, .No_Keyring, "no session bus")
		return
	}
	defer dbus.disconnect(conn) // connect_session has already done SASL and Hello
	session, ok := secret_open_session(conn)
	if !ok {
		secret_fail(op, .No_Keyring, "no Secret Service on this desktop")
		return
	}
	defer secret_close_session(conn, session)

	#partial switch op.kind {
	case .Secret_Get:    secret_lookup(op, conn, session)
	case .Secret_Set:    secret_store(op, conn, session)
	case .Secret_Delete: secret_remove(op, conn)
	}
}

// secret_open_session opens a plain session and returns its object path.
@(private = "file")
secret_open_session :: proc(conn: ^dbus.Connection) -> (string, bool) {
	empty := dbus.Value("")
	m := dbus.method_call(SECRETS_NAME, SERVICE_PATH, SERVICE_IFACE, "OpenSession",
		{dbus.Value("plain"), dbus.variant(empty, context.temp_allocator)})
	reply, err := dbus.call(conn, &m, CALL_MS, context.temp_allocator)
	if err != .None || len(reply.body) < 2 do return "", false
	path, has := dbus.as_object_path(reply.body[1])
	return strings.clone(path, context.temp_allocator), has
}

@(private = "file")
secret_close_session :: proc(conn: ^dbus.Connection, session: string) {
	if len(session) == 0 do return
	m := dbus.method_call(SECRETS_NAME, session, "org.freedesktop.Secret.Session", "Close")
	_, _ = dbus.call(conn, &m, CALL_MS, context.temp_allocator)
}

// secret_paths reads an `ao`, an array of object paths, which is what the
// Secret Service answers with. dbus.as_strings takes `as` only, so it would
// quietly give nothing and a found item would read as not found.
@(private = "file")
secret_paths :: proc(v: dbus.Value) -> []string {
	arr, ok := dbus.as_array(v)
	if !ok do return nil
	out := make([dynamic]string, 0, len(arr.items), context.temp_allocator)
	for it in arr.items {
		if p, is := dbus.as_object_path(it); is do append(&out, p)
	}
	return out[:]
}

// secret_attrs is how a secret is named to the keyring: the pair the app
// gave us, plus the application, so two apps asking for the same service
// and account do not collide.
@(private = "file")
secret_attrs :: proc(op: ^Secret_Op($Msg)) -> dbus.Value {
	entries := make([]dbus.Dict_Entry, 3, context.temp_allocator)
	entries[0] = {key = dbus.Value("service"), value = dbus.Value(op.service)}
	entries[1] = {key = dbus.Value("account"), value = dbus.Value(op.account)}
	entries[2] = {key = dbus.Value("application"), value = dbus.Value("baldr")}
	return dbus.Dict{key_sig = "s", value_sig = "s", entries = entries}
}

// secret_search returns the item paths that match, unlocking them if the
// keyring asks. An empty result is "not found", which is not an error.
@(private = "file")
secret_search :: proc(op: ^Secret_Op($Msg), conn: ^dbus.Connection) -> ([]string, bool) {
	m := dbus.method_call(SECRETS_NAME, SERVICE_PATH, SERVICE_IFACE, "SearchItems", {secret_attrs(op)})
	reply, err := dbus.call(conn, &m, CALL_MS, context.temp_allocator)
	if err != .None || len(reply.body) < 2 {
		secret_fail(op, .Failed, "the keyring would not search")
		return nil, false
	}
	unlocked := secret_paths(reply.body[0])
	locked := secret_paths(reply.body[1])
	if len(unlocked) > 0 do return unlocked, true
	if len(locked) == 0 do return nil, true // nothing of ours in there
	opened, ok := secret_unlock(op, conn, locked)
	return opened, ok
}

// secret_unlock asks for the locked items, waiting on the prompt the
// keyring shows the person if it shows one.
@(private = "file")
secret_unlock :: proc(op: ^Secret_Op($Msg), conn: ^dbus.Connection, items: []string) -> ([]string, bool) {
	paths := make([]dbus.Value, len(items), context.temp_allocator)
	for it, i in items do paths[i] = dbus.Object_Path{path = it}
	m := dbus.method_call(SECRETS_NAME, SERVICE_PATH, SERVICE_IFACE, "Unlock",
		{dbus.Array{sig = "o", items = paths}})
	reply, err := dbus.call(conn, &m, CALL_MS, context.temp_allocator)
	if err != .None || len(reply.body) < 2 {
		secret_fail(op, .Failed, "the keyring would not unlock")
		return nil, false
	}
	unlocked := secret_paths(reply.body[0])
	prompt, _ := dbus.as_object_path(reply.body[1])
	if len(unlocked) > 0 do return unlocked, true
	if prompt == "" || prompt == "/" {
		secret_fail(op, .Locked, "the keyring stayed locked")
		return nil, false
	}
	if !secret_prompt(op, conn, prompt) do return nil, false
	// after a prompt the search is worth repeating: the items are unlocked now
	m2 := dbus.method_call(SECRETS_NAME, SERVICE_PATH, SERVICE_IFACE, "SearchItems", {secret_attrs(op)})
	reply2, err2 := dbus.call(conn, &m2, CALL_MS, context.temp_allocator)
	if err2 != .None || len(reply2.body) < 1 do return nil, false
	return secret_paths(reply2.body[0]), true
}

// secret_prompt shows the keyring's prompt and waits for it to complete.
// The person may take a while, or dismiss it — which is `.Denied`, not a
// failure: they said no. The wait is a dispatch loop on this op's own
// thread, so nothing in the app is held up by it.
@(private = "file")
Prompt_Wait :: struct {
	path:      string,
	done:      bool,
	dismissed: bool,
}

@(private = "file")
secret_prompt :: proc(op: ^Secret_Op($Msg), conn: ^dbus.Connection, prompt: string) -> bool {
	wait := Prompt_Wait{path = prompt}
	rule := strings.concatenate({"type='signal',interface='", PROMPT_IFACE, "',member='Completed'"}, context.temp_allocator)
	if err := dbus.add_match(conn, rule, CALL_MS); err != .None {
		secret_fail(op, .Failed, "could not listen for the keyring's prompt")
		return false
	}
	id := dbus.on_signal(conn, PROMPT_IFACE, "Completed", proc(conn: ^dbus.Connection, sig: ^dbus.Message, user: rawptr) {
		w := (^Prompt_Wait)(user)
		if sig.path != w.path do return
		w.done = true
		if len(sig.body) > 0 do w.dismissed, _ = dbus.as_bool(sig.body[0])
	}, rawptr(&wait), path = prompt)
	// `rawptr(&wait)` tells the escape analysis this is deliberate: the
	// handler holds the pointer only until the `off_signal` below, which runs
	// before this frame goes.
	defer dbus.off_signal(conn, id)

	m := dbus.method_call(SECRETS_NAME, prompt, PROMPT_IFACE, "Prompt", {dbus.Value("")})
	if _, err := dbus.call(conn, &m, CALL_MS, context.temp_allocator); err != .None {
		secret_fail(op, .Failed, "the keyring would not prompt")
		return false
	}
	waited := i32(0)
	for !wait.done && waited < PROMPT_MS {
		if readable, err := dbus.wait_readable(conn, 100); err != .None {
			secret_fail(op, .Failed, "the bus went away while the prompt was up")
			return false
		} else if !readable {
			waited += 100
			continue
		}
		if _, err := dbus.dispatch(conn); err != .None {
			secret_fail(op, .Failed, "the bus went away while the prompt was up")
			return false
		}
	}
	if !wait.done {
		secret_fail(op, .Denied, "the keyring's prompt went unanswered")
		return false
	}
	if wait.dismissed {
		secret_fail(op, .Denied, "")
		return false
	}
	return true
}

@(private = "file")
secret_lookup :: proc(op: ^Secret_Op($Msg), conn: ^dbus.Connection, session: string) {
	items, ok := secret_search(op, conn)
	if !ok do return
	if len(items) == 0 {
		op.status = .Not_Found
		return
	}
	m := dbus.method_call(SECRETS_NAME, items[0], ITEM_IFACE, "GetSecret", {dbus.Object_Path{path = session}})
	reply, err := dbus.call(conn, &m, CALL_MS, context.temp_allocator)
	if err != .None || len(reply.body) < 1 {
		secret_fail(op, .Failed, "the keyring would not give the secret up")
		return
	}
	st, is_struct := dbus.as_struct(reply.body[0])
	if !is_struct || len(st.fields) < 3 {
		secret_fail(op, .Failed, "the keyring answered with something else")
		return
	}
	bytes, has := dbus.as_bytes(st.fields[2]) // (session o, parameters ay, value ay, content_type s)
	if !has {
		secret_fail(op, .Failed, "the secret had no value")
		return
	}
	op.value = make([]u8, len(bytes), op.allocator)
	copy(op.value, bytes)
	secret_scrub_bytes(bytes)
	op.status = .Ok
}

// secret_store_target is the collection a new secret goes into, unlocked. A
// locked collection does not answer `CreateItem` with a prompt (GNOME
// Keyring answers `IsLocked`), so the `default` alias is resolved to its
// collection (`ReadAlias`: `Unlock` takes a collection, not an alias), asked
// whether it is locked, and unlocked if it is, showing the keyring's prompt
// when it has one. A keyring that cannot resolve the alias is written to
// through the alias. Reading needs none of this: `secret_search` unlocks
// what it finds.
@(private = "file")
secret_store_target :: proc(op: ^Secret_Op($Msg), conn: ^dbus.Connection) -> (string, bool) {
	m := dbus.method_call(SECRETS_NAME, SERVICE_PATH, SERVICE_IFACE, "ReadAlias", {dbus.Value("default")})
	reply, err := dbus.call(conn, &m, CALL_MS, context.temp_allocator)
	if err != .None || len(reply.body) < 1 do return DEFAULT_ALIAS, true
	coll, is := dbus.as_object_path(reply.body[0])
	if !is || coll == "" || coll == "/" do return DEFAULT_ALIAS, true // no default collection to resolve: let CreateItem answer
	coll = strings.clone(coll, context.temp_allocator)

	get := dbus.method_call(SECRETS_NAME, coll, "org.freedesktop.DBus.Properties", "Get",
		{dbus.Value(COLLECTION_IFACE), dbus.Value("Locked")})
	if r, gerr := dbus.call(conn, &get, CALL_MS, context.temp_allocator); gerr == .None && len(r.body) > 0 {
		if locked, ok := dbus.as_bool(dbus.unwrap(r.body[0])); ok && !locked do return coll, true
	}
	if !secret_unlock_collection(op, conn, coll) do return "", false
	return coll, true
}

// secret_unlock_collection asks the keyring to unlock one collection,
// waiting on its prompt if it shows one. Dismissed is `.Denied`; locked with
// no prompt to show is `.Locked`.
@(private = "file")
secret_unlock_collection :: proc(op: ^Secret_Op($Msg), conn: ^dbus.Connection, coll: string) -> bool {
	paths := []dbus.Value{dbus.Object_Path{path = coll}}
	m := dbus.method_call(SECRETS_NAME, SERVICE_PATH, SERVICE_IFACE, "Unlock", {dbus.Array{sig = "o", items = paths}})
	reply, err := dbus.call(conn, &m, CALL_MS, context.temp_allocator)
	if err != .None || len(reply.body) < 2 {
		secret_fail(op, .Failed, "the keyring would not unlock")
		return false
	}
	for u in secret_paths(reply.body[0]) do if u == coll do return true
	prompt, _ := dbus.as_object_path(reply.body[1])
	if prompt == "" || prompt == "/" {
		secret_fail(op, .Locked, "the keyring is locked and did not ask to be unlocked")
		return false
	}
	return secret_prompt(op, conn, prompt)
}

@(private = "file")
secret_store :: proc(op: ^Secret_Op($Msg), conn: ^dbus.Connection, session: string) {
	target, ready := secret_store_target(op, conn)
	if !ready do return
	label := strings.concatenate({op.service, " — ", op.account}, context.temp_allocator)
	props := dbus.Dict{key_sig = "s", value_sig = "v", entries = {
		{key = dbus.Value(ITEM_IFACE + ".Label"), value = dbus.variant(dbus.Value(label), context.temp_allocator)},
		{key = dbus.Value(ITEM_IFACE + ".Attributes"), value = dbus.variant(secret_attrs(op), context.temp_allocator)},
	}}
	secret := dbus.Struct{fields = {
		dbus.Object_Path{path = session},
		dbus.Value([]u8{}),      // parameters: none, this session is plain
		dbus.Value(op.value),    // the secret itself
		dbus.Value("text/plain"),
	}}
	m := dbus.method_call(SECRETS_NAME, target, COLLECTION_IFACE, "CreateItem",
		{props, secret, dbus.Value(bool(true))}) // replace: storing again replaces
	reply, err := dbus.call(conn, &m, CALL_MS, context.temp_allocator)
	if err == .Remote && reply.error_name == IS_LOCKED {
		secret_fail(op, .Locked, "the keyring is locked") // locked again between the unlock and the write, or never resolved
		return
	}
	if err != .None || len(reply.body) < 2 {
		secret_fail(op, .Failed, "the keyring would not store it")
		return
	}
	item, _ := dbus.as_object_path(reply.body[0])
	prompt, _ := dbus.as_object_path(reply.body[1])
	if item != "" && item != "/" {
		op.status = .Ok
		return
	}
	if prompt == "" || prompt == "/" {
		secret_fail(op, .Failed, "the keyring stored nothing and asked nothing")
		return
	}
	if secret_prompt(op, conn, prompt) do op.status = .Ok
}

@(private = "file")
secret_remove :: proc(op: ^Secret_Op($Msg), conn: ^dbus.Connection) {
	items, ok := secret_search(op, conn)
	if !ok do return
	if len(items) == 0 {
		op.status = .Not_Found // nothing to remove is not a failure
		return
	}
	for it in items {
		m := dbus.method_call(SECRETS_NAME, it, ITEM_IFACE, "Delete")
		reply, err := dbus.call(conn, &m, CALL_MS, context.temp_allocator)
		if err != .None {
			secret_fail(op, .Failed, "the keyring would not delete it")
			return
		}
		if len(reply.body) > 0 {
			if prompt, _ := dbus.as_object_path(reply.body[0]); prompt != "" && prompt != "/" {
				if !secret_prompt(op, conn, prompt) do return
			}
		}
	}
	op.status = .Ok
}
