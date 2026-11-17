#+build !linux
#+build !windows
#+build !darwin
package baldr

// No keychain on this platform yet. Saying so is the contract: an app told
// `.No_Keyring` knows the desktop has none and can decide for itself what
// to do, where a silent failure would send it looking for a bug. Baldr will
// not write a secret to a file to paper over its absence.
@(private)
secret_platform :: proc(op: ^Secret_Op($Msg)) {
	secret_fail(op, .No_Keyring, "no keychain on this platform yet")
}
