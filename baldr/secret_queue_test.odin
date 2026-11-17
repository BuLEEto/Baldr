package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Keychain calls take their turn rather than running together, so a locked
// keyring prompts once (secret.odin). The keyring itself is not reachable
// from a test — and asking it would put a prompt on whoever is running the
// suite — so what is checked here is the queue: that a call waits while one
// is in flight, that the order is the order the app asked, and that calls
// that never get their turn are freed rather than leaked.

@(private = "file")
Sec_Msg :: union { Secret_Told }

@(private = "file")
Secret_Told :: struct { account: string }

@(private = "file")
secret_told :: proc(e: Ev(Secret)) -> Sec_Msg { return Secret_Told{e.value.account} }

@(private = "file")
ask :: proc(mb: ^Mailbox(Sec_Msg), account: string) {
	secret_run(mb, Cmd(Sec_Msg){kind = .Secret_Get, service = "baldr-test", account = account, on_secret = secret_told})
}

@(test)
keychain_calls_take_their_turn_in_order :: proc(t: ^testing.T) {
	mb: Mailbox(Sec_Msg)
	// Held as though a call were already on the keyring: nothing starts, and
	// no test ever talks to the real thing.
	mb.secret_busy = true
	defer {
		for op in mb.secret_queue do secret_op_free(op)
		delete(mb.secret_queue)
		delete(mb.mail)
	}

	ask(&mb, "chatgpt")
	ask(&mb, "epicor")
	ask(&mb, "linkup")

	testing.expect_value(t, len(mb.secret_queue), 3)
	testing.expect(t, mb.secret_busy, "the one in flight still has the keyring")
	testing.expect_value(t, mb.secret_queue[0].account, "chatgpt")
	testing.expect_value(t, mb.secret_queue[1].account, "epicor")
	testing.expect_value(t, mb.secret_queue[2].account, "linkup")

	// Asking again while one is in flight starts nothing: three asks, three
	// waiting, and not a thread among them.
	secret_next(&mb)
	testing.expect_value(t, len(mb.secret_queue), 3)
	for op in mb.secret_queue do testing.expect(t, op.thread == nil, "nothing has been started")
}

// A queued call that never runs — the window closed while the keyring was
// still being asked — must still be freed, value scrubbed and all. The
// suite's leak check is half the assertion here.
@(test)
keychain_calls_that_never_run_are_freed :: proc(t: ^testing.T) {
	mb: Mailbox(Sec_Msg)
	mb.secret_busy = true
	defer delete(mb.mail)

	value := []u8{'h', 'u', 'n', 't', 'e', 'r', '2'}
	secret_run(&mb, Cmd(Sec_Msg){kind = .Secret_Set, service = "baldr-test", account = "epicor", bytes = value})
	ask(&mb, "chatgpt")
	testing.expect_value(t, len(mb.secret_queue), 2)

	kept := mb.secret_queue[0]
	testing.expect_value(t, len(kept.value), len(value)) // copied at once, not aliased
	testing.expect(t, raw_data(kept.value) != raw_data(value), "the command's own copy")

	for op in mb.secret_queue do secret_op_free(op)
	clear(&mb.secret_queue)
	delete(mb.secret_queue)
	testing.expect_value(t, len(mb.secret_queue), 0)
}

}
