#+build windows
package baldr

// One instance of an app on Windows, and what a second launch does. The
// shape is the POSIX side's (`instance_posix.odin`), with a named pipe for
// the socket.
//
// The pipe is the lock: `FILE_FLAG_FIRST_PIPE_INSTANCE` makes the create
// fail when a pipe of that name exists, so one call claims or refuses the
// instance. The kernel removes a crashed process's pipe with its handle, so
// there is no staleness to detect.
//
// Pipe names are machine-wide, so the name carries the user and the logon
// session, the pipe admits only this user and no other machine, and a launch
// that finds the pipe already there checks who serves it before handing over
// anything: another user who made a pipe of that name first gets nothing,
// and this copy simply runs.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import win "core:sys/windows"
import "core:thread"

@(private = "file") FILE_FLAG_FIRST_PIPE_INSTANCE :: win.DWORD(0x00080000)
@(private = "file") PIPE_BUF :: win.DWORD(4096)
@(private = "file") PIPE_UNLIMITED_INSTANCES :: win.DWORD(255)
@(private = "file") SECURITY_IDENTIFICATION :: win.DWORD(0x00010000) // SecurityIdentification << 16

foreign import instance_kernel32 "system:Kernel32.lib"
foreign import instance_advapi32 "system:Advapi32.lib"

@(private = "file", default_calling_convention = "system")
foreign instance_kernel32 {
	GetNamedPipeServerProcessId :: proc(Pipe: win.HANDLE, ServerProcessId: ^win.ULONG) -> win.BOOL ---
	ProcessIdToSessionId :: proc(dwProcessId: win.DWORD, pSessionId: ^win.DWORD) -> win.BOOL ---
}

@(private = "file", default_calling_convention = "system")
foreign instance_advapi32 {
	EqualSid :: proc(pSid1, pSid2: ^win.SID) -> win.BOOL ---
	ConvertStringSecurityDescriptorToSecurityDescriptorW :: proc(StringSecurityDescriptor: win.LPCWSTR, StringSDRevision: win.DWORD, SecurityDescriptor: ^win.LPVOID, SecurityDescriptorSize: ^win.ULONG) -> win.BOOL ---
}

// process_user is the user a process runs as, as a TOKEN_USER in `buf`.
@(private = "file")
process_user :: proc(process: win.HANDLE, buf: []u8) -> (^win.SID, bool) {
	token: win.HANDLE
	if win.OpenProcessToken(process, win.TOKEN_QUERY, &token) == win.FALSE do return nil, false
	defer win.CloseHandle(token)
	got: win.DWORD
	if win.GetTokenInformation(token, .TokenUser, raw_data(buf), win.DWORD(len(buf)), &got) == win.FALSE do return nil, false
	return (^win.SID)((^win.TOKEN_USER)(raw_data(buf)).User.Sid), true
}

// instance_user is this user's SID as text and this logon session's number.
@(private = "file")
instance_user :: proc() -> (sid: string, session: win.DWORD, ok: bool) {
	buf: [256]u8
	me, mok := process_user(win.GetCurrentProcess(), buf[:])
	if !mok do return
	text: win.LPCWSTR
	if win.ConvertSidToStringSidW(me, &text) == win.FALSE do return
	defer win.LocalFree(rawptr(text))
	s, err := win.wstring_to_utf8(win.wstring(text), -1, context.temp_allocator)
	if err != nil do return
	if ProcessIdToSessionId(win.GetCurrentProcessId(), &session) == win.FALSE do return
	return s, session, true
}

// served_by_me says whether the pipe's server runs as this user. A process
// this user cannot open is someone else's.
@(private = "file")
served_by_me :: proc(pipe: win.HANDLE) -> bool {
	pid: win.ULONG
	if GetNamedPipeServerProcessId(pipe, &pid) == win.FALSE do return false
	proc_h := win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, win.FALSE, win.DWORD(pid))
	if proc_h == nil do return false
	defer win.CloseHandle(proc_h)
	mine, theirs: [256]u8
	me, mok := process_user(win.GetCurrentProcess(), mine[:])
	them, tok := process_user(proc_h, theirs[:])
	return mok && tok && EqualSid(me, them) != win.FALSE
}

@(private)
Instance :: struct {
	pipe:   win.HANDLE,
	name:   string, // owned
	stop:   bool,
	worker: ^thread.Thread,
	alloc:  runtime.Allocator,
}

@(private)
instance_path :: proc(app_id: string, allocator := context.allocator) -> string {
	safe := strings.builder_make(context.temp_allocator)
	for r in app_id {
		// A pipe name may not carry a backslash: that is the separator
		// between the server and the name itself.
		if r == '\\' || r == 0 {
			strings.write_rune(&safe, '_')
		} else {
			strings.write_rune(&safe, r)
		}
	}
	sid, session, ok := instance_user()
	if !ok do return ""
	return strings.concatenate({`\\.\pipe\baldr-`, sid, "-", fmt.tprint(session), "-", strings.to_string(safe)}, allocator)
}

@(private)
instance_claim :: proc(app_id: string, args: []string, allocator := context.allocator) -> (inst: Instance, owner: bool) {
	name := instance_path(app_id, allocator)
	if name == "" do return {}, true // no user to name it by: no single instance, but the app runs
	wide := win.utf8_to_wstring(name, context.temp_allocator)
	// Only this user may open it: the default would let anyone connect and
	// hold the one pipe instance open.
	sid, _, _ := instance_user()
	sddl := win.utf8_to_wstring(strings.concatenate({"D:P(A;;GA;;;", sid, ")"}, context.temp_allocator), context.temp_allocator)
	sd: win.LPVOID
	if ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, 1, &sd, nil) == win.FALSE {
		delete(name, allocator)
		return {}, true
	}
	defer win.LocalFree(sd)
	sa := win.SECURITY_ATTRIBUTES{nLength = size_of(win.SECURITY_ATTRIBUTES), lpSecurityDescriptor = sd}
	pipe := win.CreateNamedPipeW(wide,
		win.PIPE_ACCESS_INBOUND | FILE_FLAG_FIRST_PIPE_INSTANCE,
		win.PIPE_TYPE_BYTE | win.PIPE_READMODE_BYTE | win.PIPE_WAIT | win.PIPE_REJECT_REMOTE_CLIENTS,
		PIPE_UNLIMITED_INSTANCES, PIPE_BUF, PIPE_BUF, 0, &sa)
	if pipe != win.INVALID_HANDLE_VALUE {
		return Instance{pipe = pipe, name = name, alloc = allocator}, true
	}
	// Somebody owns it: hand over what this launch was asked to open, once
	// it is known to be this user's own copy. Identification only, so the
	// server can tell who connected but never act as them.
	h := win.CreateFileW(wide, win.GENERIC_WRITE, 0, nil, win.OPEN_EXISTING, win.SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nil)
	if h == win.INVALID_HANDLE_VALUE || !served_by_me(h) {
		// A copy shutting down, or a pipe someone else made: carrying on
		// as a second instance is better than refusing to start at all.
		if h != win.INVALID_HANDLE_VALUE do win.CloseHandle(h)
		delete(name, allocator)
		return {}, true
	}
	b := strings.builder_make(context.temp_allocator)
	for a, i in args {
		if i > 0 do strings.write_byte(&b, 0)
		strings.write_string(&b, a)
	}
	bytes := transmute([]u8)strings.to_string(b)
	written: win.DWORD
	if len(bytes) > 0 do win.WriteFile(h, raw_data(bytes), win.DWORD(len(bytes)), &written, nil)
	win.CloseHandle(h)
	delete(name, allocator)
	return {}, false
}

@(private)
instance_listen :: proc(inst: ^Instance, mb: ^Mailbox($Msg), on: Handler(Msg, Relaunch)) {
	if inst.pipe == nil || inst.pipe == win.INVALID_HANDLE_VALUE do return
	Watch :: struct($M: typeid) {
		inst: ^Instance,
		mb:   ^Mailbox(M),
		on:   Handler(M, Relaunch),
	}
	w := new(Watch(Msg), inst.alloc)
	w^ = {inst = inst, mb = mb, on = on}
	inst.worker = thread.create_and_start_with_data(rawptr(w), proc(data: rawptr) {
		w := (^Watch(Msg))(data)
		defer free(w, w.inst.alloc) // the thread owns it, and it ends here
		buf: [4096]u8
		for !sync.atomic_load(&w.inst.stop) {
			// A launch that connected, wrote and closed before this thread got
			// here is ERROR_NO_DATA, and what it wrote is still there to read.
			ok := win.ConnectNamedPipe(w.inst.pipe, nil) != win.FALSE
			if e := win.GetLastError(); !ok && e != win.ERROR_PIPE_CONNECTED && e != win.ERROR_NO_DATA {
				win.DisconnectNamedPipe(w.inst.pipe)
				continue
			}
			n: win.DWORD
			total := 0
			for total < len(buf) {
				if win.ReadFile(w.inst.pipe, raw_data(buf[total:]), win.DWORD(len(buf) - total), &n, nil) == win.FALSE do break
				if n == 0 do break
				total += int(n)
			}
			win.DisconnectNamedPipe(w.inst.pipe)
			if sync.atomic_load(&w.inst.stop) do break // the wake-up knock, not a launch
			if total == 0 do continue
			// The main thread turns it into a message, and the mailbox frees
			// this once that update ran. The arguments are copied:
			// `strings.split` slices into `buf`, which this thread reuses, so
			// the text would change under the app and freeing it would free
			// into the middle of a stack array.
			raw := strings.split(string(buf[:total]), "\x00", context.temp_allocator)
			op := new(Relaunch_Op(Msg), w.inst.alloc)
			op.args = make([]string, len(raw), w.inst.alloc)
			for part, i in raw do op.args[i] = strings.clone(part, w.inst.alloc)
			op.on = w.on
			op.allocator = w.inst.alloc
			mailbox_post(w.mb, Mail(Msg){relaunch = op})
		}
	})
}

@(private)
instance_stop :: proc(inst: ^Instance) {
	if inst.pipe == nil || inst.pipe == win.INVALID_HANDLE_VALUE do return
	sync.atomic_store(&inst.stop, true)
	// The thread is waiting in ConnectNamedPipe for a client; connecting to
	// our own pipe wakes it, or the app would not exit.
	wide := win.utf8_to_wstring(inst.name, context.temp_allocator)
	if h := win.CreateFileW(wide, win.GENERIC_WRITE, 0, nil, win.OPEN_EXISTING, 0, nil); h != win.INVALID_HANDLE_VALUE {
		win.CloseHandle(h)
	}
	if inst.worker != nil {
		thread.join(inst.worker)
		thread.destroy(inst.worker)
	}
	win.CloseHandle(inst.pipe)
	delete(inst.name, inst.alloc)
	inst^ = {}
}

// Relaunch_Op is one later launch waiting for the loop; see the POSIX file.
@(private)
Relaunch_Op :: struct($Msg: typeid) {
	args:      []string,
	on:        Handler(Msg, Relaunch),
	allocator: runtime.Allocator,
}

@(private)
relaunch_op_free :: proc(op: ^Relaunch_Op($Msg)) {
	if op == nil do return
	a := op.allocator
	for s in op.args do delete(s, a)
	delete(op.args, a)
	free(op, a)
}
