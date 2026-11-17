package baldr

// Surfaces: what an app opens on the desktop. A plain app has one window
// and never touches this file (run opens it from App.title / App.size). A
// shell — the compositor's panel, dock, launcher, wallpaper, lock screen — declares
// several surfaces by tag in App.surfaces and switches on ui.surface.tag in
// its view; the runtime opens what is new and closes what is gone after
// every update, so a surface's lifetime is a fact about the state, not a
// command to remember. Each surface has its own tree, focus and layers; the
// state, update, view, theme and text engine are shared.
//
//	surfaces :: proc(s: ^State, out: ^[dynamic]baldr.Surface_Desc(Msg)) {
//		append(out, baldr.Surface_Desc(Msg){tag = PANEL, kind = .Layer, size = {0, 36},
//			layer = {level = .Top, anchor = {.Top, .Left, .Right}, exclusive_zone = 36, keyboard = .On_Demand},
//			transparent = true, backdrop = .Blur, on_close = Msg.Quit})
//		if s.launcher do append(out, baldr.Surface_Desc(Msg){tag = LAUNCHER, kind = .Layer, …})
//	}
//
// On Wayland a .Layer surface is a wlr-layer-shell surface; without layer
// shell (other platforms, or a compositor lacking it) it becomes an
// undecorated window. A Blur backdrop needs the compositor
// (ext-background-effect-v1); without it, or with the OS "reduce
// transparency" setting on, the surface is cleared with the same material
// colour made opaque — text on it stays readable either way.

import "baldr:platform"

Surface_Kind           :: platform.Surface_Kind
Layer_Desc             :: platform.Layer_Desc
Layer_Level            :: platform.Layer_Level
Edge                   :: platform.Edge
// Keyboard_Interactivity is how much of the keyboard a layer surface asks
// for — none, on demand, or exclusive. A bar wants none, a launcher with a
// search field wants it outright.
Keyboard_Interactivity :: platform.Keyboard_Interactivity
Keyboard_Landing       :: platform.Keyboard_Landing
Backdrop               :: platform.Backdrop
Applet_Desc            :: platform.Applet_Desc
Applet_Keyboard        :: platform.Applet_Keyboard

// FIT as a .Layer's `size` along an axis makes the surface as long as its
// content there: a dock or a floating bar, anchored to one edge to sit in
// its middle, or to an edge and a side to sit at that end. Baldr measures
// the view's natural length at the surface's thickness, capped at the
// screen's length less its margins, and asks for it when it changes; the
// frame at the old length is skipped. Content longer than the screen
// shortens what gives, as a tight row does.
FIT :: f32(-1)

// FIT_START_LEN is the length a FIT surface opens at, before its content is measured.
FIT_START_LEN :: f32(64)

// Surface_Desc describes one surface the app wants open. `tag` identifies
// it across updates (0 is fine for a single surface); `on_close` is sent
// when the user or compositor closes it — leave it nil and a close quits
// the app. `size` is logical px; a .Layer stretched between two opposite
// anchors leaves that dimension 0 and takes the output's, and one as long
// as its content along an axis gives that dimension FIT.
Surface_Desc :: struct($Msg: typeid) {
	tag:         u64,
	kind:        Surface_Kind,
	title:       string,
	size:        [2]f32,
	layer:       Layer_Desc, // .Layer only: level, anchors, exclusive zone, margins, keyboard, output
	applet:      Applet_Desc, // .Applet only: the slot's token ("" = RIKKITI_APPLET_TOKEN, read when it opens) and whether a click gives it the keyboard (live)
	output:      string,     // .Lock only: the screen it covers, by its name in outputs(); it is that screen's size (lock.odin)
	transparent: bool,       // alpha composites with the desktop (rounded corners, margins, glass)
	// What the desktop does behind this surface. `.Blur` is glass (needs
	// `transparent`). `.Measure` blurs nothing and reports the brightness
	// behind, read with `backdrop_range`: for text drawn straight on the
	// wallpaper, which picks its colour with `legible_ink`.
	backdrop:    Backdrop,
	backdrop_region: Backdrop_Region, // …behind the whole surface, or only its backdrop_area nodes (clear elsewhere); live
	undecorated: bool,       // .Window: no server-side frame
	fixed_size:  bool,       // .Window: not resizable
	// .Window: how small and how large the desktop may let it be dragged,
	// in logical px; zero on an axis is no limit (`{480, 0}` floors the width
	// only). Limits, not a size: `size` is clamped into them before the
	// desktop is asked, so a restored size below a newer minimum still lays
	// out. `fixed_size` wins over both, and is how a window that cannot be
	// resized says so (not equal limits). A request: the compositor may
	// ignore it, and what happened arrives in `on_state`.
	min_size:    [2]f32,
	max_size:    [2]f32,
	// .Window: ask the desktop for the whole screen (a reading or focus
	// mode, a slideshow, a video). It is a request — the compositor decides
	// and may say no — so build from `ui.surface.fullscreen`, which is what
	// it actually did, never from what was asked. Live.
	fullscreen:  bool,
	// .Window: ask the desktop to open it maximised, for a window coming
	// back the way it was left. A request, honoured at creation only: what
	// happened is `ui.surface.maximized`, which `on_state` also reports and
	// which is what to save.
	maximized:   bool,
	// .Window: ask the desktop to open it at this position, in the desktop's
	// own coordinates (`Output.pos`). A request, honoured at creation only;
	// nil asks for nothing, and Wayland ignores it. A position whose screen
	// has gone is dropped so the window is never placed out of reach (size
	// and maximised still apply), so pass back whatever was saved. Save
	// `Window_State.position` from `on_state`, not while maximised: that
	// position is the maximised one.
	position:    Maybe([2]i32),
	// .Window: the tag of the window this one belongs to — a preferences or a
	// details window — which the desktop keeps it above and minimises with.
	// Declare it after that window, which must be open. Wayland, X11 and
	// Windows honour it; on macOS windows stay independent, as Mac apps' do.
	parent:      Maybe(u64),
	input:       Surface_Input, // where it takes the pointer: everywhere, the input_area nodes, or nowhere; live
	hide:        Layer_Hide,    // .Layer on one edge: slides off it while hidden (autohide, intellihide); live
	radius:      f32,           // a transparent glass .Layer's corners (a floating bar, a dock): its tint and highlight round, it is clear outside, and with input = .All the corners take no pointer; live
	square:      Corners,       // …the corners it keeps square (a bar attached to an edge: those at the edge)
	clear:       Maybe(Color),  // what it is cleared to: nil, the theme's (a glass layer's panel tint); a colour keeps its blur without the tint, so the view draws its own scrim (a launcher's dimmed desktop; {} fully clear)
	on_close:    Maybe(Msg),
	// on_state is what the app hears when the desktop changes this
	// surface's size, keyboard focus, or maximised / full-screen / tiled
	// state. See `Window_State`.
	on_state:    Handler(Msg, Window_State),
}

// Window_State is what the desktop has done with a surface (not what was
// asked for), delivered to `update` through `Surface_Desc.on_state` or
// `App.on_state`, for decisions made outside `view`: whether the window has
// the keyboard, and the size and maximised state to save and pass back as
// `Surface_Desc.size` / `.maximized`. It arrives once the surface is first
// configured and then only on a change, so keeping the latest is enough.
Window_State :: struct {
	tag:        u64,     // which surface, for an app with several
	size:       [2]f32,  // logical pixels
	keyboard:   bool,    // it (or a popup of it) has the keyboard
	maximized:  bool,
	fullscreen: bool,
	tiled:      bool,    // against a neighbour or a screen edge: sized by the desktop
	scale:      f32,     // device pixels per logical pixel
	// Where the window is, in the desktop's own coordinates (`Output.pos`),
	// frame included, so passing it back as `Surface_Desc.position` puts the
	// window where it was. Nil where the platform will not say: Wayland, and
	// any backend before the first configure.
	position:   Maybe([2]i32),
}

// Surface_Info is what a view learns about the surface it is building:
// ui.surface.tag picks the layout, ui.surface.glass says whether translucent
// materials will show blurred desktop behind them (else paint opaque).
// `kind` is what the surface opened as (an applet with no shell to embed it
// is a window; a layer surface without layer shell too). `edge` is the
// screen edge a bar or applet is on: a layer surface's anchored edge, an
// applet's bar's (the shell can move it: the view is built again); none for
// a window. A side bar's content runs down it.
Surface_Info :: struct {
	tag:   u64,
	kind:  Surface_Kind,
	glass: bool,
	edge:  Maybe(Edge),
	// what the desktop has actually done with the window, from its latest
	// configure — not what the app asked for. A view that hides its chrome
	// full screen, or its own title bar when maximised, reads these.
	fullscreen: bool,
	maximized:  bool,
	tiled:      bool, // against a neighbour or a screen edge: sized by the desktop, as when maximised
	rolled:     bool, // rolled up to its title bar (window_chrome): only the bar shows, laid out at its full size still
	keyboard:   bool, // it (or a popup of it) has the keyboard: a lock screen's password card goes on this one
	scale:      f32, // device pixels per logical pixel, from the same configure (0 before it: device_scale says 1)
}

// surface_resolve maps a description onto what the backend can do: .Layer
// degrades to an undecorated window without layer shell, transparency and
// blur are dropped when unsupported. Sizes a stretched layer would take
// from the output get a window default instead.
//
// An applet binds to its bar with its token (the declared one, else
// RIKKITI_APPLET_TOKEN) where the backend can embed applets, transparent;
// without a token or the capability it becomes a small window.
surface_resolve :: proc(desc: Surface_Desc($Msg), caps: platform.Caps, app_id: string) -> platform.Surface_Desc {
	if desc.kind == .Lock { // the app's own opaque drawing at the screen's size, and nothing else: no frame, no glass, never a window
		return {kind = .Lock, title = desc.title, app_id = app_id, output = desc.output}
	}
	out := platform.Surface_Desc{
		kind = desc.kind, title = desc.title, app_id = app_id, size = desc.size,
		undecorated = desc.undecorated, fixed_size = desc.fixed_size,
		min_size = desc.min_size if desc.kind == .Window else {},
		max_size = desc.max_size if desc.kind == .Window else {},
		fullscreen = desc.fullscreen && desc.kind == .Window,
		maximized = desc.maximized && desc.kind == .Window,
		position = desc.position if desc.kind == .Window else nil,
		transparent = desc.transparent && .Transparent in caps,
		layer = layer_placed(desc),
	}
	// Clamp the opening size into the range before the desktop sees it, so a
	// restored size below the minimum still lays out. For a minimum above the
	// maximum the minimum wins: too large is usable, too small is not.
	if desc.kind == .Window && !desc.fixed_size {
		for i in 0 ..< 2 {
			if out.max_size[i] > 0 && out.size[i] > out.max_size[i] do out.size[i] = out.max_size[i]
			if out.min_size[i] > 0 && out.size[i] < out.min_size[i] do out.size[i] = out.min_size[i]
		}
	}
	if desc.kind == .Layer && .Layer_Shell in caps {
		for i in 0 ..< 2 do if out.size[i] == FIT do out.size[i] = FIT_START_LEN // measured once it has content (fit_sync)
	}
	if desc.kind == .Layer && .Layer_Shell not_in caps {
		out.kind = .Window
		out.undecorated = true
		if out.size.x <= 0 do out.size.x = 800
		if out.size.y <= 0 do out.size.y = 600
	}
	if desc.kind == .Applet {
		token := applet_token(desc)
		if .Applets in caps && token != "" {
			out.transparent = .Transparent in caps // on its bar's glass: nothing is drawn behind it
			out.applet = {token = token, keyboard = desc.applet.keyboard}
			return out
		}
		out.kind = .Window // no shell to embed it: a small window of its own
		out.transparent = false
		if out.size.x <= 0 do out.size.x = APPLET_WINDOW_SIZE.x
		if out.size.y <= 0 do out.size.y = APPLET_WINDOW_SIZE.y
	}
	if desc.backdrop == .Blur && out.transparent && .Backdrop_Blur in caps do out.backdrop = .Blur
	// .Measure asks for the brightness alone, so it needs no blur — only a
	// surface the desktop shows through and a compositor that measures.
	if desc.backdrop == .Measure && out.transparent && .Backdrop_Luminance in caps do out.backdrop = .Measure
	return out
}

// layer_edge is the screen edge a layer surface sits along: an anchored
// edge whose opposite isn't (a bar stretched between Left and Right is on
// Top or Bottom); for a corner, its exclusive edge. None for a surface on
// no single edge (a launcher in a corner, a centred dialog).
layer_edge :: proc "contextless" (l: Layer_Desc) -> Maybe(Edge) {
	a := l.anchor
	top, bottom := .Top in a && .Bottom not_in a, .Bottom in a && .Top not_in a
	left, right := .Left in a && .Right not_in a, .Right in a && .Left not_in a
	if (top || bottom) && (left || right) {
		only: Maybe(Edge)
		count := 0
		for e in Edge do if e in l.exclusive_edge {
			only = e
			count += 1
		}
		return only if count == 1 else nil
	}
	switch {
	case top:    return .Top
	case bottom: return .Bottom
	case left:   return .Left
	case right:  return .Right
	}
	return nil
}

// surface_glass says whether blurred desktop will actually show through
// the surface: the theme's glass isn't Solid (OS "reduce transparency" makes
// it so), the app asked for a blur backdrop, and the compositor can do it.
surface_glass :: proc(desc: Surface_Desc($Msg), caps: platform.Caps, level: Glass_Level) -> bool {
	return level != .Solid && desc.transparent && desc.backdrop == .Blur && .Transparent in caps && .Backdrop_Blur in caps
}

// surface_watches_backdrop: whether this surface asked to be told how
// bright what is behind it is without being glass (`Backdrop.Measure`), the
// desktop shows through it, and the compositor measures. Glass asks on its
// own account; this is the surface that draws straight on the desktop and
// reads the numbers in its view (`backdrop_range`).
surface_watches_backdrop :: proc(desc: Surface_Desc($Msg), caps: platform.Caps) -> bool {
	return desc.backdrop == .Measure && desc.transparent && .Transparent in caps && .Backdrop_Luminance in caps
}

// surface_popups_glass: whether the popups a surface opens are glass over
// the desktop. Not the same as whether the surface is: a desktop asks for
// no blur because it is the wallpaper, yet its menus open over that
// wallpaper and must be glass (and measured for contrast) on it.
surface_popups_glass :: proc(desc: Surface_Desc($Msg), caps: platform.Caps, level: Glass_Level) -> bool {
	return level != .Solid && desc.transparent && .Transparent in caps && .Backdrop_Blur in caps
}

// Backdrop_Region is where a surface's blur backdrop reaches: the whole
// surface, or only the nodes marked with backdrop_area, following layout
// (separate glass toast cards on one surface), the surface clear elsewhere.
Backdrop_Region :: enum u8 { All, Marked }

// Surface_Input is how much of a surface answers the pointer. It is live, so
// a dock can take clicks only on its reveal strip while hidden and
// everywhere once shown.
Surface_Input :: enum u8 {
	All,    // the whole surface
	Marked, // the nodes marked with input_area, following layout (a floating bar's shape, a hidden dock's reveal strip)
	None,   // nowhere: drawn only (a toast fading out)
}

// Surface_Change names a difference between how an open surface was
// declared and how it is declared now.
Surface_Change :: enum u8 { Title, Backdrop, Kind, Transparent, Decoration, Resizable, Layer, Size, Output, Input, Applet, Shape, Hide, Fullscreen }
Surface_Changes :: bit_set[Surface_Change; u16]

// SURFACE_LIVE_CHANGES apply to an open surface: a layer surface's
// placement and size in place, and its screen by a new platform surface
// under the same tree; an applet's keyboard setting. The rest need a new tag.
SURFACE_LIVE_CHANGES :: Surface_Changes{.Title, .Backdrop, .Layer, .Size, .Output, .Input, .Applet, .Shape, .Hide, .Fullscreen}

// Hide_Mode is when a layer surface hides at its edge: Never; Always
// (autohide: hidden until the pointer reaches its edge); Overlap
// (intellihide: hidden while Layer_Hide.covered says a window covers it).
Hide_Mode :: enum u8 { Never, Always, Overlap }

// Layer_Hide makes a layer surface anchored to one screen edge hide at it.
// Hidden, its drawing and blur slide off towards the edge and `strip` px
// along the edge take the pointer and reveal it; it takes no exclusive zone
// while hiding is on. It shows while the pointer is on it or its popups, a
// popover or menu is open on it, or it has the keyboard, and hides
// `delay_ms` after the pointer has left them all. `covered` is the app's
// answer for Overlap (surface_rect gives where it shows). Give it a
// transparent surface. Its margin on that edge holds while it shows and is
// dropped while hidden, so the strip sits at the screen's own edge.
Layer_Hide :: struct {
	mode:     Hide_Mode,
	covered:  bool, // Overlap: a window covers where it shows
	delay_ms: f32,  // after the pointer leaves (0: HIDE_DELAY_MS)
	strip:    f32,  // logical px along its edge that reveal it (0: HIDE_STRIP)
}

// layer_placed is the placement a surface asks the compositor for: as
// declared, without an exclusive zone while it hides (windows go under it),
// and — while it is hidden and fully slid out (`at_edge`) — without the
// margin on the edge it hides at, so its reveal strip lies along the
// screen's own edge and the pointer shoved into the corner finds it. The
// margin is given back as it slides out again.
layer_placed :: proc "contextless" (d: Surface_Desc($Msg), at_edge := false) -> Layer_Desc {
	l := d.layer
	if d.hide.mode == .Never do return l
	l.exclusive_zone = 0
	if !at_edge do return l
	if edge, on_edge := layer_edge(l).?; on_edge {
		switch edge {
		case .Top:    l.margin[0] = 0
		case .Right:  l.margin[1] = 0
		case .Bottom: l.margin[2] = 0
		case .Left:   l.margin[3] = 0
		}
	}
	return l
}

// surface_changes compares two declarations of the same surface (the
// close message is always taken as it is now; `size` follows the
// declaration for a window and a layer surface alike, as a layer surface's
// placement and screen do).
surface_changes :: proc(old, new: Surface_Desc($Msg)) -> (ch: Surface_Changes) {
	if old.title != new.title do ch += {.Title}
	if old.backdrop != new.backdrop || old.backdrop_region != new.backdrop_region do ch += {.Backdrop}
	if old.kind != new.kind do ch += {.Kind}
	if old.transparent != new.transparent do ch += {.Transparent}
	if old.undecorated != new.undecorated do ch += {.Decoration}
	if old.fixed_size != new.fixed_size do ch += {.Resizable}
	if old.input != new.input do ch += {.Input}
	if old.radius != new.radius || old.square != new.square do ch += {.Shape}
	if old.hide != new.hide do ch += {.Hide}
	if old.fullscreen != new.fullscreen do ch += {.Fullscreen}
	if new.kind == .Applet && old.applet.keyboard != new.applet.keyboard do ch += {.Applet}
	if new.kind == .Layer {
		lo, ln := old.layer, new.layer
		lo.output, ln.output = "", ""
		if lo != ln do ch += {.Layer}
		if old.layer.output != new.layer.output do ch += {.Output}
	}
	// A window may change its own size while the desktop is not sizing it.
	// Only these two kinds: an applet's size is its bar's business and a
	// popup's is its parent's.
	if new.kind == .Layer || new.kind == .Window {
		if old.size != new.size do ch += {.Size}
	}
	return
}

// surface_clear is the colour the runtime clears a surface with before the
// view paints: the theme background for an opaque surface; the panel /
// window material tint over blurred desktop when glass is live (its alpha
// raised as far as the text needs over what is behind, glass.odin); Solid
// glass's own near-opaque tint; that tint made opaque when the compositor
// can't blur (readable either way); and nothing at all for a transparent
// surface without a backdrop — the view draws its own shapes there and
// consults ui.surface.glass.
surface_clear :: proc(th: ^Theme, desc: Surface_Desc($Msg), glass: bool) -> Color {
	if desc.kind == .Applet do return {} // on its bar's glass
	if c, set := desc.clear.?; set do return c // its own: a scrim over a blurred desktop
	if desc.backdrop_region == .Marked && desc.backdrop == .Blur do return {} // glass behind its marked nodes only, which draw their own
	if !desc.transparent do return th.color.bg
	// Nothing is drawn behind it unless it asked for a blur: a .Measure
	// surface is text on the desktop, and a tint behind it would hide the
	// desktop and be what got measured next.
	if desc.backdrop != .Blur do return {}
	if surface_shape(th, desc, glass) != {} do return {} // rounded: clear outside, its tint drawn as its shape
	ms := th.material[th.glass]
	m := ms.panel if desc.kind == .Layer else ms.window
	if glass || th.glass == .Solid do return m.tint
	return {m.tint.r, m.tint.g, m.tint.b, 1}
}

// surface_shape is the tint a rounded glass layer surface, or one that hides
// at its edge, draws as its shape (Surface_Desc.radius and square) so that it
// can slide, leaving the rest of it clear: the panel
// material's tint, raised as surface_clear raises it, opaque where the
// compositor can't blur. Zero for any other surface (its clear is its tint).
surface_shape :: proc(th: ^Theme, desc: Surface_Desc($Msg), glass: bool) -> Color {
	if desc.kind != .Layer || (desc.radius <= 0 && desc.hide.mode == .Never) || !desc.transparent || desc.backdrop != .Blur do return {}
	if _, set := desc.clear.?; set do return {} // cleared to its own colour: no tint to shape
	if desc.backdrop_region == .Marked do return {}
	m := th.material[th.glass].panel
	if glass || th.glass == .Solid do return m.tint
	return {m.tint.r, m.tint.g, m.tint.b, 1}
}

// surface_highlight is the bright line along a glass layer surface's top
// edge: none on a window, nor where that edge is the screen's (a bar
// attached to the top).
surface_highlight :: proc(th: ^Theme, desc: Surface_Desc($Msg), glass: bool) -> Color {
	if !glass || desc.kind != .Layer || desc.backdrop_region == .Marked do return {}
	if .Top in desc.layer.anchor && desc.layer.margin[0] <= 0 do return {}
	return th.material[th.glass].panel.highlight
}

// surface_output_present: a .Layer surface that names a screen, and a .Lock
// surface, open only while their screen exists; anything else can always
// open.
surface_output_present :: proc(desc: Surface_Desc($Msg), outs: []Output) -> bool {
	name := desc.layer.output
	switch desc.kind {
	case .Lock:            name = desc.output
	case .Layer:           if name == "" do return true
	case .Window, .Applet: return true
	}
	for o in outs do if o.name == name do return true
	return false
}

// surface_diff compares the tags of the open surfaces with the wanted ones:
// `to_open` indexes `wanted` (in declaration order), `to_close` indexes
// `open` (ascending; close in reverse to keep indices valid). Both slices
// are in temp memory by default.
surface_diff :: proc(open: []u64, wanted: []u64, allocator := context.temp_allocator) -> (to_open, to_close: []int) {
	o := make([dynamic]int, allocator)
	c := make([dynamic]int, allocator)
	for w, i in wanted {
		found := false
		for tag in open do if tag == w { found = true; break }
		if !found do append(&o, i)
	}
	for tag, i in open {
		found := false
		for w in wanted do if w == tag { found = true; break }
		if !found do append(&c, i)
	}
	return o[:], c[:]
}

// window_state_sync tells the app what the desktop has done with a surface,
// once it is configured and then only when something changes. It compares
// once a frame rather than pushing from each event because the state comes
// from several (configure, focus, scale, position), and one comparison
// cannot be half-wired.
@(private)
window_state_sync :: proc(c: ^Surface_Ctx($Msg), out: ^[dynamic]Msg) {
	if !handler_live(c.desc.on_state) do return
	now := Window_State {
		tag        = c.desc.tag,
		size       = c.ui.tree.viewport,
		keyboard   = c.ui.surface.keyboard,
		maximized  = c.ui.surface.maximized,
		fullscreen = c.ui.surface.fullscreen,
		tiled      = c.ui.surface.tiled,
		scale      = c.ui.surface.scale,
	}
	// Polled like the rest: a window moved by its title bar is not an event
	// on every platform.
	if b := c.fc.backend; b != nil && b.surface_position != nil && c.kind == .Window {
		if p, ok := b.surface_position(b, c.fc.surface); ok do now.position = p
	}
	// Nothing is reported before the first configure: until then the state
	// is what was asked for, not what the desktop did.
	if now.size == {} do return
	if c.state_told && now == c.state_sent do return
	c.state_sent, c.state_told = now, true
	handler_deliver(c.desc.on_state, now, c.desc.tag, out)
}
