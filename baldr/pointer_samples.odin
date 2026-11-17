package baldr

import "baldr:platform"

// Every pointer sample: a canvas hears the whole path the pointer or pen
// took, not one position a frame. A 1000 Hz mouse or a 200 Hz pen moves
// many times between two frames, and a brush stroke is that path, with its
// timing (a velocity brush, smoothing), the buttons and keys held (a
// right-drag, Shift for a straight line), and for a pen its pressure, tilt,
// rotation, distance and which end is down. The samples come in one message
// a frame, so an app is not woken a thousand times a second.

// Pen_Tool is what made a sample: the mouse, or a tablet tool — a pen, its
// eraser end, a brush, a pencil, an airbrush, a finger, a puck, a lens.
Pen_Tool :: enum u8 { Mouse, Pen, Eraser, Brush, Pencil, Airbrush, Finger, Lens }

// Mouse_Buttons is the buttons held; a pen's tip down is Left, its barrel
// buttons Right and Middle.
Mouse_Buttons :: bit_set[Mouse_Button; u8]

// Sample_Kind is what a sample is: a move, a button (or the pen's tip)
// pressed or let go, or a pen coming near the tablet over the node and
// going away (a brush outline follows a hovering pen between the two).
Sample_Kind :: enum u8 { Move, Press, Release, Enter, Leave }

// Pointer_Sample is one input event over a node that hears them.
Pointer_Sample :: struct {
	kind:     Sample_Kind,
	pos:      [2]f32,        // from the node's top-left, sub-pixel
	time_ms:  f64,           // the event's own time, on the compositor's clock: differences are what mean anything
	button:   Mouse_Button,  // Press / Release: which
	buttons:  Mouse_Buttons, // held once this sample is taken
	mods:     Mods,
	tool:     Pen_Tool,
	pressure: f32,           // 0..1; a mouse: 1 while a button is held
	tilt:     [2]f32,        // degrees from upright, along x and y
	rotation: f32,           // degrees, where the pen reports it
	distance: f32,           // 0..1 above the tablet while hovering; -1 where it isn't reported
	contact:  bool,          // the pen's tip is down (a mouse: its left button is)
	clicks:   int,           // Press: 1, 2 for a double click, 3 for a triple (the same button, soon and near the last); else 0
}

// Pointer_Samples is a frame's samples over a node, oldest first, and the
// node's size. `samples` is the node's own: valid while the message is
// handled (the next frame's samples go elsewhere), so copy what you keep.
Pointer_Samples :: struct {
	samples: []Pointer_Sample,
	size:    [2]f32,
}

// Sample_Area is a node that hears samples, and what it has gathered.
@(private)
Sample_Area :: struct($Msg: typeid) {
	handler: Handler(Msg, Pointer_Samples),
	hover:   bool, // samples without a button held too, while over it
	held:    bool, // a press began on it: it hears everything until the last button lets go
	samples: [dynamic]Pointer_Sample, // gathered since the last frame
	sent:    [dynamic]Pointer_Sample, // the batch last handed out: its message is handled after the frame that sent it, when the frame's temp memory is gone
}

// pointer_samples makes node `n` (a canvas) hear every pointer or pen
// sample through `on_samples`: all of them while a press that began on it
// is held, wherever they go, through to the release; and with `hover`,
// while the pointer or pen is over it with nothing held too (a brush
// outline following the pen). They come in one message a frame. A pen's
// tip also presses and drags as the left button everywhere else, so the
// rest of the window works with it; `pointer_track` still gives the one
// position a frame for what needs no more. nil stops it.
pointer_samples :: proc(ui: ^Ui($Msg), n: Node, on_samples: Handler(Msg, Pointer_Samples), hover := false) {
	if node_get(&ui.tree, n) == nil do return
	if !handler_live(on_samples) {
		samples_forget(ui, n)
		return
	}
	a, has := &ui.sample_areas[n]
	if !has {
		ui.sample_areas[n] = Sample_Area(Msg){samples = make([dynamic]Pointer_Sample, ui.allocator), sent = make([dynamic]Pointer_Sample, ui.allocator)}
		a = &ui.sample_areas[n]
	}
	a.handler, a.hover = on_samples, hover
}

// pointer_sample takes one input event at `pos` (tree coordinates): the
// areas it falls to keep it. A press over an area holds it; the release
// that lets the last button go is its last held sample.
pointer_sample :: proc(ui: ^Ui($Msg), s: Pointer_Sample, pos: [2]f32) {
	if len(ui.sample_areas) == 0 do return
	t := &ui.tree
	hit := hit_test(t, pos)
	for n, &a in ui.sample_areas {
		d := node_get(t, n)
		if d == nil do continue
		over := node_within(t, hit, n)
		if s.kind == .Press && over do a.held = true
		keep := a.held || (a.hover && over && s.buttons == {}) || (a.hover && (s.kind == .Enter || s.kind == .Leave) && over)
		if !keep do continue
		local := s
		local.pos = pos - {d.abs.x, d.abs.y}
		append(&a.samples, local)
		if s.kind == .Release && s.buttons == {} do a.held = false
	}
}

// samples_tick sends each area what it gathered since the last frame.
@(private)
samples_tick :: proc(ui: ^Ui($Msg)) {
	t := &ui.tree
	for n, &a in ui.sample_areas {
		if len(a.samples) == 0 do continue
		d := node_get(t, n)
		// the gathered become the sent, and the last sent (handled by now) gathers the next frame's
		a.samples, a.sent = a.sent, a.samples
		clear(&a.samples)
		handler_send(ui, a.handler, Pointer_Samples{samples = a.sent[:], size = {d.abs.w, d.abs.h} if d != nil else {}}, n)
	}
}

// samples_forget: node `n` is gone.
@(private)
samples_forget :: proc(ui: ^Ui($Msg), n: Node) {
	if a, has := &ui.sample_areas[n]; has {
		delete(a.samples)
		delete(a.sent)
	}
	delete_key(&ui.sample_areas, n)
}

// Click_Count is the run of presses of one button, each soon after the
// last (MULTI_CLICK_MS) and near it (MULTI_CLICK_PX).
@(private)
Click_Count :: struct {
	button: Mouse_Button,
	ms:     f64,
	at:     [2]f32,
	count:  int,
}

// click_count counts a press of `button` at `time_ms` (the event's clock)
// and `pos`: one more than the last in its run, or 1 to start one.
@(private)
click_count :: proc(c: ^Click_Count, button: Mouse_Button, time_ms: f64, pos: [2]f32) -> int {
	near := abs(pos.x - c.at.x) <= MULTI_CLICK_PX && abs(pos.y - c.at.y) <= MULTI_CLICK_PX
	if c.count > 0 && c.button == button && near && time_ms - c.ms <= MULTI_CLICK_MS && time_ms >= c.ms {
		c.count += 1
	} else {
		c.count = 1
	}
	c.button, c.ms, c.at = button, time_ms, pos
	return c.count
}

// mouse_sample takes a mouse event of `kind` at `pos` as a sample, after the
// pointer has acted on it (so `buttons` is what is held now). `counted` says
// the press was already counted — by `mouse_button_event`, which counts
// *before* the press acts — so it is read here rather than counted twice.
mouse_sample :: proc(ui: ^Ui($Msg), kind: Sample_Kind, button: Mouse_Button, time_ms: u32, pos: [2]f32, counted := false) {
	held := ui.pointer.buttons
	clicks := 0
	if kind == .Press {
		clicks = ui.pointer.clicks.count if counted else click_count(&ui.pointer.clicks, button, f64(time_ms), pos)
	}
	pointer_sample(ui, Pointer_Sample{
		kind = kind, time_ms = f64(time_ms), button = button, buttons = held, mods = ui.pointer.mods,
		tool = .Mouse, pressure = 1 if held != {} else 0, distance = -1, contact = .Left in held, clicks = clicks,
	}, pos)
}

// pen_count counts a pen press the way `mouse_button_event` counts a mouse
// one: before anything reads the count.
@(private)
pen_count :: proc(ui: ^Ui($Msg), button: Mouse_Button, time_ms: u32, at: [2]f32) {
	ui.pointer.time_ms = f64(time_ms)
	click_count(&ui.pointer.clicks, button, f64(time_ms), at)
}

// mouse_button_event is a mouse button as the run loop delivers it, and the
// one place its order lives: counted first, then acted on, then taken as a
// sample. A widget that reads a double click (selecting a word) reads
// `ui.pointer.clicks.count` while the press is handled, so counting after
// would hand it the previous press's count. Tests go through this too, so
// they exercise the same order.
mouse_button_event :: proc(ui: ^Ui($Msg), button: Mouse_Button, pressed: bool, at: [2]f32, time_ms: u32) -> (changed: bool) {
	ui.pointer.time_ms = f64(time_ms) // every multi-click is timed on this, not the frame clock
	if pressed do click_count(&ui.pointer.clicks, button, f64(time_ms), at)
	changed = pointer_button(ui, button, pressed, at)
	mouse_sample(ui, .Press if pressed else .Release, button, time_ms, at, counted = true)
	return
}

// pen_event acts on a tablet tool's frame: the tip is the left button, the
// first barrel button the right and the second the middle, coming near and
// going away the pointer arriving and leaving (so a pen works the whole
// window), and the frame is a sample, with its pressure,
// tilt, rotation and distance, for a node that hears them. `at` is the
// frame's position in the tree. True when something visible changed.
pen_event :: proc(ui: ^Ui($Msg), e: platform.Ev_Pen, at: [2]f32) -> (changed: bool) {
	ui.pointer.mods = map_mods(e.mods)
	kind := Sample_Kind.Move
	button := Mouse_Button.Left
	switch e.phase {
	case .Near:
		changed = pointer_move(ui, at)
		kind = .Enter
	case .Move:
		changed = pointer_move(ui, at)
	case .Down:
		ui.pointer.press_serial = e.serial
		pen_count(ui, .Left, e.time_ms, at) // before the press acts, as mouse_button_event does
		changed = pointer_button(ui, .Left, true, at)
		kind = .Press
	case .Up:
		changed = pointer_button(ui, .Left, false, at)
		kind = .Release
	case .Button:
		button = .Right if e.button == 0 else .Middle
		if e.pressed {
			ui.pointer.press_serial = e.serial
			pen_count(ui, button, e.time_ms, at)
		}
		changed = pointer_button(ui, button, e.pressed, at)
		kind = .Press if e.pressed else .Release
	case .Away:
		changed = pointer_leave(ui)
		kind = .Leave
	}
	tool: Pen_Tool
	switch e.tool {
	case .Pen:      tool = .Pen
	case .Eraser:   tool = .Eraser
	case .Brush:    tool = .Brush
	case .Pencil:   tool = .Pencil
	case .Airbrush: tool = .Airbrush
	case .Finger:   tool = .Finger
	case .Mouse:    tool = .Mouse
	case .Lens:     tool = .Lens
	}
	pointer_sample(ui, Pointer_Sample{
		kind = kind, time_ms = f64(e.time_ms), button = button, buttons = ui.pointer.buttons, mods = ui.pointer.mods,
		tool = tool, pressure = e.pressure, tilt = e.tilt, rotation = e.rotation, distance = e.distance, contact = e.contact,
		clicks = ui.pointer.clicks.count if kind == .Press else 0, // counted before the press acted (pen_count)
	}, at)
	return
}
