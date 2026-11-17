package baldr

// Time and subscriptions. `delay` is a command: one message after N
// milliseconds. Subscriptions are declared from state, like surfaces:
// `every` sends a message on an interval and `watch` reports changes to a
// path; the runtime starts and stops them as the declared list changes
// after each update, keeping a timer's phase when its line stays. Due
// times feed the run loop's wait, so nothing polls.

import "baldr:platform"

// Sub_Kind: what a subscription is.
Sub_Kind :: enum u8 { None, Every, Watch, Outputs, Toplevels, Workspaces, Frames }

// Sub is one line of an app's `subscriptions` list: `every(Msg, ms, msg)`
// or `watch(Msg, path, on_change)`. Two lines with the same kind, timing
// or path and `tag` are the same subscription across updates.
Sub :: struct($Msg: typeid) {
	kind:      Sub_Kind,
	ms:        i64,                       // Every
	msg:       Msg,                       // Every, Outputs, Toplevels, Workspaces: what is sent
	path:      string,                    // Watch
	on_change: Handler(Msg, File_Change), // Watch
	on_frame:  Handler(Msg, Frame_Time),  // Frames
	tag:       u64,
}

// Change_Kind: what happened under a watched path.
Change_Kind :: platform.Watch_Kind

// File_Change is what a watch reports: the watched `path`, the entry
// `name` inside it when the path is a directory ("" for the path
// itself), and what happened. Strings live only while the message is
// handled — clone what you keep.
File_Change :: struct {
	path: string,
	name: string,
	kind: Change_Kind,
}

// outputs_changed sends `msg` whenever a screen is added, removed or
// changes; `outputs()` then has the new set.
//
//	append(out, baldr.outputs_changed(Msg, Screens_Changed{}))
outputs_changed :: proc($Msg: typeid, msg: Msg, tag: u64 = 0) -> Sub(Msg) {
	return {kind = .Outputs, msg = msg, tag = tag}
}

// delay sends `msg` once, `ms` milliseconds from now.
//
//	case Saved: s.notice = "Saved"; return baldr.delay(Msg, 2000, Hide_Notice{})
delay :: proc($Msg: typeid, ms: i64, msg: Msg) -> Cmd(Msg) {
	return {kind = .Delay, ms = ms, msg = msg}
}

// every sends `msg` each `ms` milliseconds while the line stays declared.
// A blocked app gets one message when it wakes, not a burst.
every :: proc($Msg: typeid, ms: i64, msg: Msg, tag: u64 = 0) -> Sub(Msg) {
	return {kind = .Every, ms = ms, msg = msg, tag = tag}
}

// Frame_Time is when a frame will be seen. `present_ms` is the moment the
// frame the app is about to draw is expected on screen; `now_ms` is the
// toolkit's clock as it was told; `refresh_ms` is the display's interval.
//
// `estimated` is true when the compositor does not report presentation
// times and these were worked out from the frame callback and the refresh
// rate instead. An app tuning motion should know which it has.
Frame_Time :: struct {
	now_ms:     f64,
	present_ms: f64,
	refresh_ms: f64,
	estimated:  bool,
}

// frames sends a message for every frame the display is about to show,
// while the line stays declared, with the time that frame is expected on
// screen. It is for anything that must keep in step with the display (a
// video player, an animation driven from outside the toolkit), which a
// timer cannot: nothing ties `every(16)` to the screen. It paints at the
// screen's rate for as long as it is declared, where Baldr otherwise draws
// only when something changed, so declare it only while it is needed; a
// player drops the line when it pauses.
//
//	if s.playing do append(out, baldr.frames(Msg, proc(e: baldr.Ev(baldr.Frame_Time)) -> Msg {
//		return Tick{e.value.present_ms}
//	}))
frames :: proc($Msg: typeid, on_frame: Handler(Msg, Frame_Time), tag: u64 = 0) -> Sub(Msg) {
	return {kind = .Frames, on_frame = on_frame, tag = tag}
}

// watch reports changes to `path` while the line stays declared: a file
// (also when it is replaced by a save-and-rename), or a directory and its
// entries. The handler gets File_Change with the sub's `tag`. Linux
// (inotify) today; a backend without watches reports nothing.
//
//	baldr.watch(Msg, s.path, proc(e: baldr.Ev(baldr.File_Change)) -> Msg { return Reload{} })
watch :: proc($Msg: typeid, path: string, on_change: Handler(Msg, File_Change), tag: u64 = 0) -> Sub(Msg) {
	return {kind = .Watch, path = path, on_change = on_change, tag = tag}
}

// ------------------------------------------------------------- runtime

@(private)
Delayed :: struct($Msg: typeid) {
	at:  f64, // ms on the runtime's clock
	msg: Msg,
}

@(private)
Every_Timer :: struct($Msg: typeid) {
	ms:   i64,
	tag:  u64,
	msg:  Msg,
	next: f64,
	keep: bool, // scratch for sched_sync
}

@(private)
Watched :: struct($Msg: typeid) {
	path:      string, // owned
	tag:       u64,
	token:     u64,
	on_change: Handler(Msg, File_Change),
	ok:        bool, // the backend took it
	keep:      bool,
}

// Sched holds the runtime's delays, interval timers and watches.
@(private)
Sched :: struct($Msg: typeid) {
	delayed:    [dynamic]Delayed(Msg),
	every:      [dynamic]Every_Timer(Msg),
	watches:    [dynamic]Watched(Msg),
	outputs:    [dynamic]Signal_Sub(Msg),
	toplevels:  [dynamic]Signal_Sub(Msg),
	workspaces: [dynamic]Signal_Sub(Msg),
	frames:     [dynamic]Frame_Sub(Msg), // a message per frame the display shows
	next_token: u64,
}

// Frame_Sub is a `frames` line: who to tell about each frame.
@(private)
Frame_Sub :: struct($Msg: typeid) {
	on_frame: Handler(Msg, Frame_Time),
	tag:      u64,
	keep:     bool,
}

// Signal_Sub is a line that sends its message when something the desktop
// reports changes (screens, windows, workspaces).
@(private)
Signal_Sub :: struct($Msg: typeid) {
	tag:  u64,
	msg:  Msg,
	keep: bool,
}

@(private)
Watch_Start :: proc(user: rawptr, path: string, token: u64) -> bool
@(private)
Watch_Stop :: proc(user: rawptr, token: u64)

@(private)
sched_delay :: proc(s: ^Sched($Msg), now: f64, ms: i64, msg: Msg) {
	append(&s.delayed, Delayed(Msg){at = now + f64(max(ms, 0)), msg = msg})
}

// sched_timeout is how long the loop may sleep before something is due
// (ms, -1 for nothing scheduled).
@(private)
sched_timeout :: proc(s: ^Sched($Msg), now: f64) -> i32 {
	best := f64(-1)
	for d in s.delayed do if best < 0 || d.at < best do best = d.at
	for t in s.every do if best < 0 || t.next < best do best = t.next
	if best < 0 do return -1
	return i32(max(best - now, 0))
}

// sched_fire delivers what is due: delays once, timers again `ms` later
// counted from now. True when anything fired.
@(private)
sched_fire :: proc(s: ^Sched($Msg), now: f64, out: ^[dynamic]Msg) -> bool {
	fired := false
	for i := 0; i < len(s.delayed); {
		if s.delayed[i].at > now {
			i += 1
			continue
		}
		append(out, s.delayed[i].msg)
		ordered_remove(&s.delayed, i)
		fired = true
	}
	for &t in s.every {
		if t.next > now do continue
		append(out, t.msg)
		t.next = now + f64(t.ms)
		fired = true
	}
	return fired
}

// sched_sync makes the running timers and watches match `wanted`: a line
// that is still there keeps its timer phase (its message is refreshed),
// a new one starts, a gone one stops.
@(private)
sched_sync :: proc(s: ^Sched($Msg), wanted: []Sub(Msg), now: f64, start: Watch_Start, stop: Watch_Stop, user: rawptr) {
	for &t in s.every do t.keep = false
	for &w in s.watches do w.keep = false
	for &o in s.outputs do o.keep = false
	for &o in s.toplevels do o.keep = false
	for &o in s.workspaces do o.keep = false
	for &f in s.frames do f.keep = false
	for sub in wanted {
		switch sub.kind {
		case .None:
		case .Every:
			found := false
			for &t in s.every {
				if t.keep || t.ms != sub.ms || t.tag != sub.tag do continue
				t.msg = sub.msg
				t.keep = true
				found = true
				break
			}
			if !found do append(&s.every, Every_Timer(Msg){ms = sub.ms, tag = sub.tag, msg = sub.msg, next = now + f64(max(sub.ms, 1)), keep = true})
		case .Watch:
			found := false
			for &w in s.watches {
				if w.keep || w.path != sub.path || w.tag != sub.tag do continue
				w.on_change = sub.on_change
				w.keep = true
				found = true
				break
			}
			if !found {
				s.next_token += 1
				w := Watched(Msg){path = clone_string(sub.path), tag = sub.tag, token = s.next_token, on_change = sub.on_change, keep = true}
				w.ok = start != nil && start(user, w.path, w.token)
				append(&s.watches, w)
			}
		case .Outputs:    signal_keep(&s.outputs, sub)
		case .Toplevels:  signal_keep(&s.toplevels, sub)
		case .Workspaces: signal_keep(&s.workspaces, sub)
		case .Frames:
			found := false
			for &f in s.frames {
				if f.keep || f.tag != sub.tag do continue
				f.on_frame = sub.on_frame
				f.keep = true
				found = true
				break
			}
			if !found do append(&s.frames, Frame_Sub(Msg){on_frame = sub.on_frame, tag = sub.tag, keep = true})
		}
	}
	for i := len(s.every) - 1; i >= 0; i -= 1 do if !s.every[i].keep do ordered_remove(&s.every, i)
	for i := len(s.outputs) - 1; i >= 0; i -= 1 do if !s.outputs[i].keep do ordered_remove(&s.outputs, i)
	for i := len(s.toplevels) - 1; i >= 0; i -= 1 do if !s.toplevels[i].keep do ordered_remove(&s.toplevels, i)
	for i := len(s.workspaces) - 1; i >= 0; i -= 1 do if !s.workspaces[i].keep do ordered_remove(&s.workspaces, i)
	for i := len(s.frames) - 1; i >= 0; i -= 1 do if !s.frames[i].keep do ordered_remove(&s.frames, i)
	for i := len(s.watches) - 1; i >= 0; i -= 1 {
		w := s.watches[i]
		if w.keep do continue
		if w.ok && stop != nil do stop(user, w.token)
		delete(w.path)
		ordered_remove(&s.watches, i)
	}
}

// signal_keep keeps a declared signal line (its message refreshed), or starts it.
@(private)
signal_keep :: proc(list: ^[dynamic]Signal_Sub($Msg), sub: Sub(Msg)) {
	for &o in list {
		if o.keep || o.tag != sub.tag do continue
		o.msg = sub.msg
		o.keep = true
		return
	}
	append(list, Signal_Sub(Msg){tag = sub.tag, msg = sub.msg, keep = true})
}

// sched_signal sends every line's message; false when there is none.
@(private)
sched_signal :: proc(lines: []Signal_Sub($Msg), out: ^[dynamic]Msg) -> bool {
	for o in lines do append(out, o.msg)
	return len(lines) > 0
}

// sched_outputs_changed sends every outputs_changed line's message.
@(private)
sched_outputs_changed :: proc(s: ^Sched($Msg), out: ^[dynamic]Msg) -> bool {
	return sched_signal(s.outputs[:], out)
}

// sched_watch_event turns a backend's change report into the watch's
// message.
@(private)
sched_watch_event :: proc(s: ^Sched($Msg), token: u64, name: string, kind: Change_Kind, out: ^[dynamic]Msg) -> bool {
	for w in s.watches {
		if w.token != token do continue
		return handler_deliver(w.on_change, File_Change{path = w.path, name = name, kind = kind}, w.tag, out)
	}
	return false
}

@(private)
sched_destroy :: proc(s: ^Sched($Msg), stop: Watch_Stop, user: rawptr) {
	for w in s.watches {
		if w.ok && stop != nil do stop(user, w.token)
		delete(w.path)
	}
	delete(s.watches)
	delete(s.every)
	delete(s.outputs)
	delete(s.toplevels)
	delete(s.workspaces)
	delete(s.frames)
	delete(s.delayed)
	s^ = {}
}

@(private)
clone_string :: proc(s: string, allocator := context.allocator) -> string {
	if len(s) == 0 do return ""
	out := make([]u8, len(s), allocator)
	copy(out, s)
	return string(out)
}

// sched_wants_frames: any `frames` line is declared, so the runtime keeps
// asking the compositor for them and painting at the screen's rate.
@(private)
sched_wants_frames :: proc(s: ^Sched($Msg)) -> bool {
	return len(s.frames) > 0
}

// sched_frame_event hands one frame's timing to every line that asked.
@(private)
sched_frame_event :: proc(s: ^Sched($Msg), ft: Frame_Time, out: ^[dynamic]Msg) {
	for f in s.frames do handler_deliver(f.on_frame, ft, f.tag, out)
}
