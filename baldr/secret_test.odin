package baldr

// Secrets in the OS keychain. What a test can hold to without a keyring of
// its own is the contract around it: the commands carry what was asked, a
// value is scrubbed rather than just freed, and a lookup for something
// nobody stored answers *why* it found nothing.

import "core:strings"
import "core:testing"

when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Sec_Msg :: union { Secret }

@(test)
secret_commands_carry_what_was_asked :: proc(t: ^testing.T) {
	get := secret_get(Sec_Msg, "acme", "openai", proc(e: Ev(Secret)) -> Sec_Msg { return e.value })
	testing.expect_value(t, get.kind, Cmd_Kind.Secret_Get)
	testing.expect_value(t, get.service, "acme")
	testing.expect_value(t, get.account, "openai")

	token := transmute([]u8)string("sk-token")
	set := secret_set(Sec_Msg, "acme", "openai", token)
	testing.expect_value(t, set.kind, Cmd_Kind.Secret_Set)
	testing.expect_value(t, string(set.bytes), "sk-token")
	testing.expect(t, raw_data(set.bytes) != raw_data(token), "the value is copied: the command outlives the update")

	del := secret_delete(Sec_Msg, "acme", "openai")
	testing.expect_value(t, del.kind, Cmd_Kind.Secret_Delete)
	testing.expect_value(t, del.account, "openai")
}

@(test)
secret_scrub_leaves_nothing_behind :: proc(t: ^testing.T) {
	// A token freed but not overwritten is a token in whatever allocation
	// lands there next.
	s := Secret{status = .Ok, value = make([]u8, 16)}
	copy(s.value, "sk-abcdefghijkl")
	seen := s.value // the same memory, to read after the scrub
	secret_scrub(&s)
	zeroed := true
	for b in seen do if b != 0 do zeroed = false
	testing.expect(t, zeroed, "the bytes are overwritten before they are freed")
	testing.expect(t, s.value == nil, "…and the secret no longer points at them")
	testing.expect_value(t, s.status, Secret_Status.Not_Found)
}

@(test)
secret_says_why_it_found_nothing :: proc(t: ^testing.T) {
	// The distinction that matters: "the keyring has no such
	// secret" (ask the person to sign in again) is not "this desktop has no
	// keyring" (the app decides what to do instead). A machine with no
	// keyring — a build box, a container — must answer the second, never
	// the first, and neither is an error.
	op := Secret_Op(Sec_Msg){
		kind = .Secret_Get,
		service = strings.clone("baldr-test-nothing-is-stored-here"),
		account = strings.clone("nobody"),
		allocator = context.allocator,
	}
	defer {
		delete(op.service)
		delete(op.account)
		if len(op.error) > 0 do delete(op.error)
	}
	secret_platform(&op)
	testing.expect(t, op.status == .Not_Found || op.status == .No_Keyring,
		"a secret nobody stored is Not_Found where there is a keyring, No_Keyring where there is none")
	testing.expect_value(t, len(op.value), 0)
}

} // when ODIN_TEST
