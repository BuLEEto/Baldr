#+build windows
package baldr

// The Windows keychain backend: Credential Manager, which keeps a generic
// credential per target name behind the person's own login. Runs on the
// op's own thread; these calls are quick and do not prompt, but they are
// kept off the main thread so every platform behaves the same way.

import "core:strings"
import win "core:sys/windows"

foreign import advapi32 "system:Advapi32.lib"

@(private = "file") CRED_TYPE_GENERIC        :: win.DWORD(1)
@(private = "file") CRED_PERSIST_LOCAL_MACHINE :: win.DWORD(2)
@(private = "file") ERROR_NOT_FOUND          :: win.DWORD(1168)
// Credential Manager is a per-logon store, and a logon with none (a service,
// a session started for an ssh command, a container) answers every Cred call
// with this, read and write alike. It means "no keyring here", as a missing
// Secret Service does on Linux, and must stay distinct from "no such secret".
@(private = "file") ERROR_NO_SUCH_LOGON_SESSION :: win.DWORD(1312)

// CREDENTIALW as Advapi32 reads it. core:sys/windows has no Cred API, so
// the struct and the three calls are declared here, in the order the
// documented layout gives (a field out of order is a wild pointer).
@(private = "file")
CREDENTIALW :: struct {
	Flags:              win.DWORD,
	Type:               win.DWORD,
	TargetName:         win.wstring,
	Comment:            win.wstring,
	LastWritten:        win.FILETIME,
	CredentialBlobSize: win.DWORD,
	CredentialBlob:     ^u8,
	Persist:            win.DWORD,
	AttributeCount:     win.DWORD,
	Attributes:         rawptr,
	TargetAlias:        win.wstring,
	UserName:           win.wstring,
}

@(default_calling_convention = "system")
foreign advapi32 {
	CredWriteW  :: proc(credential: ^CREDENTIALW, flags: win.DWORD) -> win.BOOL ---
	CredReadW   :: proc(target: win.wstring, type: win.DWORD, flags: win.DWORD, credential: ^^CREDENTIALW) -> win.BOOL ---
	CredDeleteW :: proc(target: win.wstring, type: win.DWORD, flags: win.DWORD) -> win.BOOL ---
	CredFree    :: proc(buffer: rawptr) ---
}

// secret_target is the name Credential Manager files it under. The app's
// name comes first so two apps asking for the same service and account do
// not collide, which is what the Linux side's attributes do.
@(private = "file")
secret_target :: proc(op: ^Secret_Op($Msg)) -> win.wstring {
	name := strings.concatenate({"baldr:", op.service, ":", op.account}, context.temp_allocator)
	return win.utf8_to_wstring(name, context.temp_allocator)
}

@(private)
secret_platform :: proc(op: ^Secret_Op($Msg)) {
	target := secret_target(op)
	#partial switch op.kind {
	case .Secret_Set:
		cred := CREDENTIALW{
			Type = CRED_TYPE_GENERIC,
			TargetName = target,
			Persist = CRED_PERSIST_LOCAL_MACHINE,
			CredentialBlobSize = win.DWORD(len(op.value)),
			CredentialBlob = raw_data(op.value),
			UserName = win.utf8_to_wstring(op.account, context.temp_allocator),
		}
		if CredWriteW(&cred, 0) != win.FALSE {
			op.status = .Ok
		} else if win.GetLastError() == ERROR_NO_SUCH_LOGON_SESSION {
			secret_fail(op, .No_Keyring, "this logon session has no credential store")
		} else {
			secret_fail(op, .Failed, "Credential Manager would not store it")
		}
	case .Secret_Get:
		out: ^CREDENTIALW
		if CredReadW(target, CRED_TYPE_GENERIC, 0, &out) == win.FALSE {
			switch win.GetLastError() {
			case ERROR_NOT_FOUND:             op.status = .Not_Found
			case ERROR_NO_SUCH_LOGON_SESSION: secret_fail(op, .No_Keyring, "this logon session has no credential store")
			case:                             secret_fail(op, .Failed, "Credential Manager would not read it")
			}
			return
		}
		defer CredFree(out)
		n := int(out.CredentialBlobSize)
		if n > 0 && out.CredentialBlob != nil {
			op.value = make([]u8, n, op.allocator)
			copy(op.value, ([^]u8)(out.CredentialBlob)[:n])
		}
		op.status = .Ok
	case .Secret_Delete:
		if CredDeleteW(target, CRED_TYPE_GENERIC, 0) != win.FALSE {
			op.status = .Ok
		} else {
			switch win.GetLastError() {
			case ERROR_NOT_FOUND:             op.status = .Not_Found // nothing to remove is not a failure
			case ERROR_NO_SUCH_LOGON_SESSION: secret_fail(op, .No_Keyring, "this logon session has no credential store")
			case:                             secret_fail(op, .Failed, "Credential Manager would not delete it")
			}
		}
	}
}
