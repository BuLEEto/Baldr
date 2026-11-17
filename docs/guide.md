# The Baldr guide

A tour of the toolkit, in the order you need it. For the per-widget detail —
every signature, what each one does with the keyboard, what it reports to a
screen reader — see [`widgets.md`](widgets.md). For the generated reference
of every public declaration, [`API.md`](API.md).

1. [Install](#install)
2. [The shape of an app](#the-shape-of-an-app)
3. [Views and scopes](#views-and-scopes)
4. [Layout](#layout)
5. [Text](#text)
6. [The widgets, by job](#the-widgets-by-job)
7. [Events and handlers](#events-and-handlers)
8. [Commands: effects from `update`](#commands-effects-from-update)
9. [Subscriptions](#subscriptions)
10. [Theming](#theming)
11. [Accessibility](#accessibility)
12. [Keyboard conventions](#keyboard-conventions)
13. [Windows, surfaces and shells](#windows-surfaces-and-shells)
14. [Your own widget](#your-own-widget)
15. [Drawing your own: canvases](#drawing-your-own-canvases)
16. [Memory and lifetimes](#memory-and-lifetimes)
17. [Untrusted input](#untrusted-input)
18. [Shipping your app](#shipping-your-app)
19. [Testing without a window](#testing-without-a-window)
20. [Debugging](#debugging)

## Install

You need Odin `dev-2026-11a` or newer. On Linux and Windows you also need a
Vulkan driver; on macOS, Baldr draws with Metal and needs only the Xcode
Command Line Tools that Odin links with. The README's
[Getting started](../README.md#getting-started) has the table for each
platform. Baldr is an Odin collection, not a package manager entry:

```bash
git clone https://github.com/BuLEEto/Baldr /opt/baldr
odin build myapp -collection:baldr=/opt/baldr
```

**On Windows, ask for a GUI program**, or double-clicking your app opens a
terminal behind it — a program is a console program there unless it says
otherwise:

```bash
odin build myapp -collection:baldr=/opt/baldr -subsystem:windows
```

Leave it off for a tool that wants a console to print to. (Older advice
passed `/SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup` to the linker; Odin's own
flag says the same thing, and the default linker on `dev-2026-11a` warns
that it cannot redefine the entry point when given `/ENTRY`.)

```odin
import "baldr:baldr"   // the toolkit
import "baldr:gpu"     // only if you draw on a canvas yourself
```

There is nothing else to install, link or configure. On Linux, `lavapipe` is
a fine Vulkan driver for running and testing.

## The shape of an app

An app is four things: a `State` struct, a `Msg` type, an `update` that
changes the state, and a `view` that describes what the state looks like.

```odin
State :: struct { count: int }
Msg   :: enum { Inc, Dec }

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch m {
	case .Inc: s.count += 1
	case .Dec: s.count -= 1
	}
	return {}            // no effect
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.row(ui, gap = .md, padding = .lg); defer baldr.end(ui)
	baldr.button(ui, "−", Msg.Dec)
	baldr.text(ui, fmt.tprintf("%d", s.count), role = .Title)
	baldr.button(ui, "+", Msg.Inc)
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){title = "Counter", update = update, view = view})
}
```

The loop is: platform event → a `Msg` dispatched to `update` → `view` run
again → reconcile against the previous node tree → layout → paint → render.
**It only runs when something happens.** An idle window does no work, because
there is no frame; the view proc is not a render callback.

`Msg` is usually an enum, but it can be any type — a union of structs is the
idiomatic choice once messages carry payloads:

```odin
Msg :: union {
	Clicked,
	Renamed,          // Renamed :: struct { id: int, name: string }
	Loaded,           // Loaded  :: struct { ok: bool, bytes: []u8 }
}
```

`App` has more fields than the four, all optional. The ones worth knowing
early:

| Field | What |
|---|---|
| `init: proc() -> State` | build the first state (see [Memory and lifetimes](#memory-and-lifetimes) — it has a trap) |
| `start: proc(s: ^State) -> Cmd(Msg)` | the one command the app begins with: read its file, start a job |
| `size`, `maximized` | the window to ask for; `on_state` tells you what you actually got |
| `on_close: Maybe(Msg)` | set it and the window **does not close** — the message reaches `update` and the app decides. Without it, a window shut with unsaved work in it takes the work with it |
| `on_state: Handler(Msg, Window_State)` | size, keyboard focus, maximized, fullscreen, tiled, scale — once configured, then only on a change |
| `accent: Color` | the app's own brand colour; the theme is generated from it and still follows the desktop's light/dark and contrast |
| `theme: Theme` | names a theme outright, and then follows nothing |
| `adjust_theme: proc(th: ^Theme)` | your last word on *every* theme the app runs with. The right door for a style knob — it survives a light/dark switch and an in-app theme picker |
| `subscriptions` | timers and file watches, declared per state |
| `surfaces` | more than one window, or a bar, dock or launcher |
| `tray` | a status item, with an icon and a menu |
| `single_instance` | a second launch hands its arguments to the first through `on_relaunch` |

## Views and scopes

A container opens a scope and `end` closes it. **Its children go in a block,
with the `defer` as the first line inside:**

```odin
baldr.column(ui, gap = .md, padding = .lg); defer baldr.end(ui)
baldr.text(ui, "Title", role = .Title)

baldr.row(ui, gap = .sm); {
	defer baldr.end(ui)
	baldr.button(ui, "OK", Msg.Ok)
	baldr.button(ui, "Cancel", Msg.Cancel, variant = .Outline)
}
```

**Every container needs its own `end`**, so a view has one `defer` per
container and they close in reverse order — that is what `defer` is for. The
brace is what makes the nesting visible: the row's children are the lines
inside its braces, and `defer baldr.end(ui)` is always the first of them, in
the same place every time, so there is nowhere for it to hide.

The first container in a proc is the exception, and the `column` above is one:
the proc's own braces are already its block, so it is written flat as the
proc's first statement and closes when the proc returns. Every container
inside it takes the block form. The other exception is a builder that answers
whether it opened at all — there the `if` carries the block, which the next
section covers.

Leaves (`text`, `button`, `image`, `spacer`) take no `end`. A missing `end`
is a runtime error that names the line where the scope was opened, and an
extra one names the scope that was already closed, so neither is a hunt.

### Which builders need an `end`

**Every one that opens a scope takes exactly one `end`** — never two, even
where it opened several scopes internally (a `dialog` opens three and closes
them together). Everything else is a leaf and takes none.

| | |
|---|---|
| **Always one `end`** | `column` `row` `stack` `wrap` `card` `scroll` `split` `pane` `pages` `list` `table` `table_row` `cell` `icon_view` `tree_view` `menu_bar` `window_chrome` |
| **One `end`, but only when it returns `true`** | `component` `dialog` `popover` `menu` `context_menu` `submenu` `expander` `tab_panel` `menu_bar_menu` |
| **No `end`** | every other builder — `text` `button` `checkbox` `toggle` `slider` `progress` `select` `segmented` `text_input` `image` `icon` `chip` `badge` `box` `spacer` `separator` `terminal` `code_editor` `markdown_view` `tab_bar` `menu_item` `list_row` `tree_item` `icon_item` `breadcrumbs` `graph` — and every modifier (`tooltip`, `draggable`, `pointer_area`, `theme_area`, …), which take a node rather than opening a scope |

The shape of the signature is the tell. A builder that returns a `Node` or a
range has opened a scope; one that returns `bool` has opened a scope *if* it
returned true, which is why those read `if … { defer baldr.end(ui); … }`; and
a leaf returns a `Node` you only need if you are going to modify it.

### What happens if you forget one

Nothing silent, and nothing fatal. At the end of the build `end_view` closes
whatever is still open, so the frame still renders, and it reports the
mistake with **the line where the unclosed scope was opened**:

```
baldr: ui/files.odin:84: scope opened here was never closed; add baldr.end(ui)
       before the view returns (view ended at ui/files.odin:131)
```

`end_view` also returns `.Unbalanced_Scope`, which a headless test can
assert on. The visible symptom is usually what points you there first:
everything built after the unclosed container ends up *inside* it, so a row
of siblings suddenly nests.

The other way round is caught too — an `end` too many names the scope that
was already closed, and misuse of a scope that belongs to a particular
parent says so in those words: `pane outside a split`,
`tree_item outside a tree_view`.

### Why `end` at all

Because the alternative is worse in Odin, and it was measured rather than
assumed. The other option was a view that *returns* a tree of values
(`column(ui, text(…), button(…))`, as Elm and iced do). Odin has no closures
and no comprehensions, so the moment a view has a loop in it that style needs
a temporary array and a `x if c else none()` for anything conditional:

```odin
// The rejected style, for contrast — this is NOT Baldr's API and there is no
// `baldr.View` type. Returning values means collecting children first:
rows := make([dynamic]View, context.temp_allocator)
for t in s.todos { append(&rows, row(ui, …)) }
return column(ui, ..rows[:], gap = .sm)

// What Baldr does instead: the loop is just a loop.
baldr.column(ui, gap = .sm); defer baldr.end(ui)
for t in s.todos {
	baldr.row(ui, key = t.id); {
		defer baldr.end(ui)
		baldr.checkbox(ui, t.done, "", Msg.Toggle, tag = t.id)
		baldr.text(ui, t.title)
	}
}
```

Scoped builders also mean **no intermediate tree**: each call reconciles
straight against the current parent's child cursor, so there is no
description tree allocated and thrown away on every update, and skipping an
unchanged subtree (`component`) or parking an inactive tab (`tab_panel`) is
one `if` rather than a cached value with its own lifetime.

**You are right that it is forgettable** — that is the acknowledged cost of
this choice, not a defence of it. Odin gives a library three hooks on "this
region ended" — `defer`, a `for` loop's post-statement, and an explicit call
— and all three are per container, so no API shape here can cost less than
one line each. What makes this one cheap enough: the house style above puts
the children in a block, so the shape is in the indentation and
`defer baldr.end(ui)` is always the first line inside rather than something
to notice at the end of a long call; the diagnostic names the exact line; and
it fires the first time you run the view, not as a subtle wrong-looking
layout weeks later.

Some scoped builders return a `bool` so you only build what shows:

```odin
if baldr.tab_panel(ui, s.page == 0, key = 1) { defer baldr.end(ui); files_page(ui, s) }
```

**Skip an unchanged subtree** with `component`, which keeps the nodes from
last time rather than rebuilding them:

```odin
if !baldr.component(ui, "sidebar", s.sidebar_rev) do return
defer baldr.end(ui)
```

Bump the revision when the data behind it changes. This is an optimisation,
not a correctness tool — a view is cheap, and most apps never need it.

**Identity across rebuilds** is `key`. The reconciler matches nodes by
position and builder by default, which is right until a list is reordered or
prepended to; then a stable `key` is what keeps a widget's state — a caret
position, an expanded row, a running animation — attached to the right thing.

## Layout

Flex-ish, in logical pixels, with named spacing from the theme.

```odin
baldr.column(ui, gap = .md, padding = .lg, align = .Stretch, justify = .Start, flex = 1)
baldr.row(ui, gap = .sm, align = .Center)
baldr.box(ui, width = 200, height = 48, bg = th.color.surface, radius = th.radius.md)
baldr.spacer(ui, 24)                       // a fixed gap
baldr.box(ui, flex = 1)                    // …a flexible one: pushes what follows to the end
baldr.wrap(ui, gap = .sm)                  // flows onto the next line
baldr.stack(ui)                            // children overlap
baldr.scroll(ui, flex = 1, gutter = true)  // a scrolling viewport
baldr.split(ui, 280)                       // a draggable split; two `pane` scopes follow
```

Spacing, radii and sizes take a `Space`, which is either a theme token or a
raw number:

```odin
Space_Token :: enum u8 { none, xxs, xs, sm, md, lg, xl, xxl, xxxl }
Space       :: union { Space_Token, f32 }
```

So `gap = .md` follows the theme's density and `gap = f32(7)` does not. Prefer
the token.

Sizing: `width` / `height` fix a size, `min_*` / `max_*` bound it, `flex`
shares what is left over along the main axis. `align` is the cross axis
(`.Start`, `.Center`, `.End`, `.Stretch`), `justify` the main one (`.Start`,
`.Center`, `.End`, `.Between`, `.Around`).

**Adaptive layout is the app's to ask for and the framework's to make easy.**
Ask for the window's size class in the view and branch:

```odin
if baldr.size_class(ui) == .Compact {
	phone_layout(ui, s)
} else {
	desktop_layout(ui, s)
}
```

`Compact` is under 600 px wide (a phone, a narrow pane), `Medium` up to 840,
`Expanded` beyond. The view is built again when the class changes, so that
is all there is to it; an ordinary resize only lays it out again. A view
that needs the exact size calls `baldr.viewport(ui)` instead, and is built
again whenever that changes. Check anything responsive at phone width
before calling it done.

## Text

```odin
baldr.text(ui, "Hello", role = .Title)
baldr.text(ui, "quiet", muted = true)
baldr.text(ui, path, ellipsis = .Middle, max_lines = 1)
baldr.text(ui, "12:04:33", tabular = true)        // figures all one width: a clock stops jittering
baldr.text(ui, code, mono = true)
baldr.text(ui, "ACME", family = s.brand, size = 20)
```

`Text_Role` is `Body`, `Display`, `Headline`, `Title`, `Label`, `Caption` —
the theme's type scale, which follows the desktop's text size and font size. Prefer
a role to a `size`.

Under the hood is [`runa`](../third_party/runa/), a pure-Odin text engine:
shaping, bidi, line breaking, OpenType features, variable fonts, font
fallback, emoji with skin tones. You do not call into it; `text`, the editors
and the rich-text widgets do.

A family the machine does not have falls back silently to the face embedded
in the binary. To carry your own:

```odin
WORDMARK :: #load("fonts/Acme-Bold.ttf")
s.brand = baldr.text_family_bytes(ui.tree.text, "acme wordmark", WORDMARK)
```

The bytes are copied, so a `#load`ed slice or a buffer you free afterwards
both work. SFNT only — `.ttf`, `.otf` or a collection; a `.woff2` is not
read, because unpacking one wants a Brotli decompressor and that is C.

For runs of mixed styling, inline links and inline objects, use
`styled_text` / `rich_text`; for a document, `markdown_view`,
`markdown_editor` or `code_editor`.

A `text` is a label: it cannot be selected. Text a person should be able to
select and copy is a `styled_text`, a `markdown_view`, or a `text_area` with
`readonly`.

## The widgets, by job

Around 80 widgets, and the modifiers that add to any node. The map:

| Job | Builders |
|---|---|
| Containers | `column`, `row`, `box`, `card`, `stack`, `wrap`, `scroll`, `split`, `pane`, `spacer`, `separator`, `component` |
| Buttons and toggles | `button`, `icon_toggle`, `checkbox`, `radio`, `toggle`, `segmented`, `chip`, `menu_chip` |
| Values | `text_input`, `search_field`, `number_input`, `slider`, `select`, `date_field`, `date_picker`, `time_field`, `time_picker`, `color_field`, `color_picker` |
| Collections | `list`, `list_row`, `table`, `table_row`, `cell`, `tree_view`, `tree_item`, `icon_view`, `icon_item`, `breadcrumbs` |
| Navigation | `tab_bar`, `tab_panel`, `pages`, `menu_bar`, `menu`, `menu_item`, `submenu` |
| Overlays | `dialog`, `popover`, `context_menu`, `tooltip`, `toast` |
| Editors | `text_area`, `code_editor`, `markdown_editor`, `markdown_view`, `rich_text`, `styled_text`, `editor_*` modifiers |
| Media and data | `image`, `icon`, `theme_icon`, `terminal`, `lines`, `chart` family, node graphs, `emoji_picker` |
| Feedback | `progress`, `spinner`, `badge`, `live` |
| Interaction modifiers | `clickable`, `hoverable`, `pointer_area`, `pointer_track`, `pointer_samples`, `draggable`, `drop_target`, `zoomable`, `key_hold`, `focus_track`, `tooltip` |
| Styling | `theme_area` (a part of the window in a theme of its own) |
| Your own | `custom`, painted with `draw_rect`, `draw_line`, `draw_icon`, `draw_text`; `canvas` for a GPU texture |
| Shell surfaces | `applet_slot`, `input_area`, `backdrop_area`, `toplevel_spot` |

Each one is purpose-built rather than composed, which is why there are so
many: a date picker is a date picker, not three number fields in a row.

## Events and handlers

The simplest handler is the message itself:

```odin
baldr.button(ui, "Save", Msg.Save)
```

For an event that carries a value, a handler is a union of "just send this
message" or "build one from the event":

```odin
Handler(Msg, T) :: union { Msg, proc(Ev(T)) -> Msg }
```

```odin
// just a message, the value ignored
baldr.text_input(ui, &s.name, on_submit = Msg.Submit)

// or build one from the value
on_renamed :: proc(e: baldr.Ev(string)) -> Msg {
	return Renamed{id = int(e.tag), name = e.value}   // clone `name` if you keep it
}
baldr.text_input(ui, &s.name, on_change = on_renamed, tag = u64(row.id))
```

`tag` is how a handler knows *which* widget fired: set it on the builder and
read `e.tag` back. (A ternary into a handler does not do what it looks like:
`h if c else nil` stores a *nil proc inside the union*, which is not an empty
union. Use `handler_live` to ask whether a handler is really there.)

The vocabulary is fixed, so the same name means the same thing everywhere:
`on_click`, `on_change`, `on_submit`, `on_cancel`, `on_hover`, `on_key`,
`on_context`, `on_middle_click`, `on_scroll`, `on_double_click`, `on_commit`
(a value let go of or stepped to by a key), `on_samples` (every pointer and
pen sample), `on_text` (text an input method committed), `on_paste_other` (a
paste that brought a picture or files instead of text), `on_resize`,
`on_event` (a node that reports several kinds of thing), `on_state` (what the
*desktop* did to the surface).

Window-level keys are not a widget's business:

```odin
baldr.shortcut(ui, "Ctrl+N", Msg.New)
baldr.shortcut(ui, "Ctrl+Shift+S", Msg.SaveAs)
```

## Commands: effects from `update`

`update` returns a `Cmd(Msg)` — an effect for the runtime to perform, which
later sends a message back. That is the whole async story: no futures, no
callbacks into your state, nothing shared across threads.

```odin
update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case Open:   return baldr.open_files(Msg, on_opened, title = "Open", multiple = true)
	case Save:   return baldr.write_file(Msg, s.path, s.bytes, on_written)
	case Crunch: return baldr.job(Msg, crunch, &s.input, on_done)
	case Tick:   return baldr.delay(Msg, 250, Msg(Tick{}))          // milliseconds
	case Copy:   return baldr.copy_text(Msg, baldr.str(s.sel))
	case Both:   return baldr.batch(Msg, cmd_a, cmd_b)
	case Done:   return baldr.quit(Msg)
	}
	return {}
}
```

What is available: `quit`, `batch`, `delay`, `job` / `cancel`, `read_file` /
`write_file`, `open_files` / `save_file` (the desktop's own dialog),
`copy_text` / `copy_files` / `copy_html` / `copy_image` / `paste` /
`paste_image`,
`open_url` (http, https, mailto only), `open_path` / `reveal_path`,
`secret_get` / `secret_set` / `secret_delete` (the OS keychain), `notify` /
`notify_close`, `focus` (give the keyboard to the widget with that key),
`gpu_open` / `canvas_read`, the desktop verbs (`toplevel_*`, `workspace_*`,
`activate`, `poster`, `lock_session` / `unlock_session`), and
`forget_image`.

A `job` runs on a thread. Inside it you get `post` to send progress and
`cancelled` to ask whether to stop. It never touches your `State`: it
returns, and the runtime delivers a message.

## Subscriptions

What the app *listens to*, declared per state the same way surfaces are. A
line that stays keeps running; one that is gone stops.

```odin
subs :: proc(s: ^State, out: ^[dynamic]baldr.Sub(Msg)) {
	if s.playing do append(out, baldr.every(Msg, 1000, Msg(Tick{})))          // milliseconds
	if s.path != "" do append(out, baldr.watch(Msg, s.path, on_file_changed))
}
```

`every` keeps phase across syncs rather than drifting. `watch` is a real file
watch where the platform has one.

## Theming

A `Theme` is colour roles, state layers, a radius ladder, spacing per token,
a type scale, motion, elevation and glass materials. An app usually sets
none of it — the default follows the desktop's light/dark, accent and
contrast — and reads it when it draws something itself:

```odin
th := &ui.tree.theme
baldr.box(ui, bg = th.color.surface_variant, radius = th.radius.md)
```

Three doors, in increasing order of "and then it follows nothing":

```odin
// 1. your brand colour, still following the desktop's light/dark and contrast
baldr.App(State, Msg){ accent = {0.26, 0.55, 0.96, 1}, … }

// 2. your last word on every theme the app runs with — the door for a style knob
corners :: proc(th: ^baldr.Theme) {
	r := &th.radius
	r.sm, r.md, r.lg, r.xl, r.full = 2, 2, 3, 4, 3
}
baldr.App(State, Msg){ adjust_theme = corners, … }

// 3. a theme named outright, following nothing
baldr.App(State, Msg){ theme = my_theme, … }
```

`adjust_theme` is the one to reach for: it runs on *every* theme the runtime
hands the app — the generated accent theme, the high-contrast one, one set
with `set_theme` — so it survives the desktop switching to dark and someone
picking Light in your own settings.

**Following the OS is the default.** An app that sets none of the three
follows the desktop's light or dark, its accent, its contrast setting, its UI
and monospace fonts, its text size, reduce motion and reduce transparency,
live as they change. Where the desktop has a whole colour scheme, the theme
is built from it. A KDE colour scheme becomes the app's grounds, text and
accent. A Windows contrast theme is drawn in exactly the colours the person
chose.

**Three layers, each falling back to the one below**, as Flutter, Compose
and WinUI do it:

1. **Global tokens**: `th.color`, `th.type`, `th.radius`, `th.space`,
   `th.motion`, `th.elev`, the fonts, `th.density` and `th.min_target`.
2. **Component styles**: one per widget kind, `th.button`, `th.field`,
   `th.check`, `th.toggle`, `th.slider`, `th.segmented`, `th.list_row`,
   `th.tree_row`, `th.table`, `th.icon_view`, `th.tab`, `th.menu`,
   `th.menu_bar`, `th.chip`, `th.menu_chip`, `th.separator`, `th.card`,
   `th.dialog`, `th.popover`, `th.tooltip`, `th.toast`, `th.scrollbar`,
   `th.split`, `th.focus_ring` and `th.icon_toggle`. Every field is a
   `Maybe`: left alone it follows the global tokens, so changing
   `th.radius.md` still rounds every button, and setting one overrides only
   that. 0 and a transparent colour are values of their own.
3. **One control**: its own parameters (`variant`, `bg`, `border`), or a
   subtree with a theme of its own.

```odin
look :: proc(th: ^baldr.Theme) {
	th.density = -1                          // compact: every control 4 px shorter
	th.button.radius = 0                     // square buttons, nothing else
	th.button.primary.fill = brand_red       // and their main colour
	th.list_row.plain.title.size = 15        // a row's title
	th.menu.item_min_height = 32             // menu rows
}

// one control styled apart: the subtree takes its own theme
danger := ui.tree.theme
danger.button.primary.fill = alarm_red
area := baldr.row(ui); defer baldr.end(ui)
baldr.theme_area(ui, area, danger)
baldr.button(ui, "Delete everything", Msg.Wipe)
```

`th.density` moves every control's height by 4 px a step: −1 is compact,
+1 spacious, and fractions work too. That covers buttons, fields, selects,
chips, tabs, menu items and list, tree and table rows. It never goes below a
control's content or `min_target`. `BALDR_DENSITY=-1` previews it without
touching the app. A text size a style sets is logical px at text scale 1,
and follows the desktop's and the app's text size as the type scale does.
The fields of each style are in `docs/API.md`.

The radius ladder is `none, xs, sm, md, lg, xl, full`. `full` means "as round
as the shape allows", and every theme in the toolkit sets it to 9999 — but a
shape drawn as a pill takes `min(full, h/2)`, so a theme with square corners
squares its pills too. What is round *on purpose* — a switch's knob, a
slider's thumb, a radio, a dot, a swatch, an avatar — does not read `full` at
all.

**A display face for headings and labels, and bigger targets.** Two knobs a
design often asks for, both set in `adjust_theme`:

```odin
SPACE_GROTESK :: #load("fonts/SpaceGrotesk-SemiBold.ttf")

look :: proc(th: ^baldr.Theme) {
	th.type.display.family  = "Space Grotesk" // headings…
	th.type.headline.family = "Space Grotesk"
	th.type.title.family    = "Space Grotesk"
	th.type.label.family    = "Space Grotesk" // …and every control's label
	th.min_target = 44                        // nothing smaller than 44 × 44 to hit
}

// once, where the view first has the text engine
if s.grotesk == 0 do s.grotesk = baldr.text_family_bytes(ui.tree.text, "Space Grotesk", SPACE_GROTESK)
```

A step's `family` takes whatever names a family — one installed, or bytes
the app registered under that name, before or after the theme names it —
and one that cannot be found draws as the rest of the theme's text, so
nothing breaks on a machine without it. Body text, fields and editors stay
in `font_family`. A variable file registered from bytes is set to each
weight the type scale asks for, as an installed one is: a `Semibold` step
draws its bold, 700, so for exactly 600 register a static SemiBold cut.

`min_target` grows every control that takes a click or the keyboard to that
size across and down, with its content centred: buttons, icon buttons,
checkboxes, sliders, fields, selects, tabs, menu items, rows. A size you
fixed with `width` or `height` stands, and text that takes no click keeps
its own. 44 is what the accessibility guidelines ask for; a touchscreen
gives controls that height by itself.

**The accent has two colours, because it does two jobs.** `primary` is the
accent as a **fill** — a selection, a switched-on toggle, a Primary button, a
progress bar, a focus ring. `accent_text` is the accent as **ink** — a ghost
button's label and icon, a breadcrumb's current place, a link, an unread
count. They are the same colour in every generated theme and you can ignore
the distinction entirely; it exists for a style whose accent reads well as a
fill and badly as text, which a mid grey does:

```odin
// a desktop's own greys, reproduced exactly
th := baldr.theme_from_palette(baldr.Theme_Palette{
	bg = …, surface = …, on_surface = …,
	primary     = grey,          // the fill, taken as asked
	accent_text = near_black,    // the ink, because the grey is 2:1 as text
}, .Light)
```

Leave `accent_text` unset and it is the fill, lifted until it clears 4.5:1 on
the view — so ink is always readable without you doing anything, and the fill
is always the colour you named.

Glass: `material[glass]` gives frosted-glass presets per surface class, and
where the compositor reports how bright the desktop is behind a blurred
surface, the tint and text colours follow so text keeps 4.5:1. Reduce
transparency and high contrast make it solid and opaque.

Icons: `icon` takes a Lucide icon compiled in; `theme_icon` takes a name from
the desktop's own icon theme, loads it off the UI thread, and never blinks
one out while a size loads or the theme changes.

## Accessibility

Not a later phase, and not something you add. Every interactive builder
already sets a role, a name and its states, is operable from the keyboard,
and draws a focus ring. What you owe it is a **name** where the widget cannot
know one:

```odin
baldr.icon_toggle(ui, .Mic, s.muted, "Microphone", Msg.ToggleMic)   // the label is required
baldr.image(ui, &s.photo, label = "Harbour at dusk")                // decorative without a label

n := baldr.box(ui, width = 120, height = 32)
baldr.set_describe(&ui.tree, n, "3 of 12 selected")     // detail beyond the name

status := baldr.text(ui, "Saved")
baldr.live(ui, status, .Polite)                         // announced without moving focus
```

A field that fails validation says so to the eye and to a screen reader
alike: `set_invalid` and `set_required` mark any form control (a field
draws its frame in the danger colour, and readers are told), and
`set_describe` carries the message.

```odin
name := baldr.text_input(ui, &s.name, label = "Name", on_change = on_name)
baldr.set_invalid(&ui.tree, name, s.name_missing) // a danger frame, and the reader's state
baldr.set_required(&ui.tree, name, true)
if s.name_missing {
	baldr.set_describe(&ui.tree, name, "A name is needed")                  // heard with the field
	baldr.text(ui, "A name is needed", role = .Caption, color = ui.tree.theme.color.danger)
}
```

The bridges are AT-SPI2 on Linux, NSAccessibility on macOS and UI
Automation on Windows, all fed from one mapping. `access_dump(t)` prints the tree a screen
reader sees, which is what the headless tests assert, and the debug lint
reports an interactive node with no name — it must stay silent on the
gallery.

The toolkit follows the desktop's text scale, reduce motion and reduce
transparency. On Linux the text scale includes the desktop's UI font size:
Baldr's type is drawn for an 11 pt desktop font, GNOME's default, so a
desktop set to 13 pt draws it 13/11 larger, on top of any Large Text, as GTK
does. Windows' font size is its Text size setting, which is the text scale
already, and macOS has no font size to set. `set_text_scale` **multiplies** the desktop's rather than
replacing it, so an app with its own text-size setting still respects a
person who made everything bigger; `set_a11y_prefs` takes all three over,
for a desktop that owns them.

Reduce motion is honoured in the widgets: a transition becomes a cut, an
animated image shows frame 0, an indeterminate progress bar becomes a static
band.

## Keyboard conventions

These are the same in every widget, and a new widget adopts them before
inventing its own:

- **Enter** commits a typed value and selects it; focus stays.
- **Escape** reverts — and *only then* goes on to close a popover.
- **Leaving a field** commits.
- **Up / Down** step; with Shift, by ten.
- **Home / End** go to the ends.
- A menu or list opened with the **pointer** highlights nothing until a key:
  Down goes to its first item, Up to its last, and Enter acts only on what
  shows.
- A click on a two-state part flips it.
- In a dialog, an Enter the focused control does not use activates the
  dialog's `default` button.
- An arrow, Home, End or Page key held with **Alt or Super** is the window's
  — Back, Forward, Up — never a view's cursor.
- A key a view declines goes on to the window's shortcuts.
- **A dismissal is never the destructive choice.** Escape and a scrim press
  mean "not now". Anything destructive belongs on a button inside the dialog.

## Windows, surfaces and shells

An app with no `surfaces` proc gets one window from `title` and `size`, which
is most apps. Declare them when you want more, or something that is not a
window:

```odin
surfaces :: proc(s: ^State, out: ^[dynamic]baldr.Surface_Desc(Msg)) {
	append(out, baldr.Surface_Desc(Msg){tag = 1, title = "Main", size = {900, 600}})
	if s.prefs_open {
		append(out, baldr.Surface_Desc(Msg){tag = 2, title = "Preferences", size = {480, 420}, parent = 1})
	}
}

// One view proc serves them all, switching on the surface it is building:
view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	switch ui.surface.tag {
	case 1: main_view(ui, s)
	case 2: prefs_view(ui, s)
	}
}
```

A surface is declared, not opened: appending one opens it, dropping one
closes it, and changing a field reconfigures it. Declaring none ends the app
unless `keep_running` holds it — which, with a `tray`, is how an app lives
with no window at all. `parent` names the window a second one belongs to:
the desktop keeps it above that window and minimises it with it (macOS
keeps windows independent, as Mac apps do). `examples/38_windows` is the
whole pattern.

`App.icon` is the windows' icon on Windows and X11. Wayland takes it from
the `.desktop` file named like `app_id`, and macOS from the app bundle; on
Windows an icon compiled into the program (`odin build -resource:app.rc`,
resource id 1) is used when `icon` is nil.

Beyond ordinary windows, `Surface_Desc` describes the shell tier: a `.Layer`
surface for a bar, dock, launcher or wallpaper; `.Applet` to be embedded in
another shell's bar; `backdrop = .Blur` for real behind-window blur, or
`backdrop = .Measure` to be told how bright what is behind it is without
blurring anything — text drawn straight on the wallpaper, which reads the
numbers with `backdrop_range` and picks its colour with `legible_ink`. Where
the compositor reports the backdrop cell by cell, `legible_over(ui, n,
preferred, contrast)` goes further and lets *each* text or icon node take the
ink and halo that read over its own rect — so a readout over a wallpaper that
runs light to dark is dark at the top and light at the bottom instead of
sharing the one ink that reads over the whole span. It re-picks whenever
layout moves the node or the wallpaper changes, with no view rebuilt, and
falls back to the surface-wide range where there is no map.
`backdrop_range_in(ui, rect)` hands the same range to an app drawing a fill
itself, and `backdrop_mapped(ui)` says whether the finer measurement is
coming at all. Those
need a compositor that offers them — Wayland today — and **degrade rather
than fail**: a layer surface becomes an undecorated window, a lock or applet
call answers that it cannot, a missing blur becomes an opaque tint that keeps
its contrast. Read `Backend.caps` if you want to know before asking.

`window_chrome` draws a title bar yourself, following the desktop's button
layout and double-click action unless `App.titlebar` says otherwise.

## Your own widget

`custom` is a node that sizes and paints itself. It takes the pointer
through the same modifiers as any node, and while it has focus, the keys it
names. It paints with the theme in force, so it follows light, dark,
contrast and the app's styles like the toolkit's own widgets.
`examples/37_custom` is a whole star rating built this way.

```odin
stars :: proc(p: ^baldr.Painter) {
	s := (^State)(p.user)
	for i in 0 ..< 5 {
		ink := p.theme.color.primary if i < s.rating else p.theme.color.outline
		baldr.draw_icon(p, .Star, {p.rect.x + f32(i) * 32, p.rect.y}, 28, ink)
	}
	if p.focused do baldr.draw_line(p, {p.rect.x, p.rect.y + p.rect.h - 1}, {p.rect.x + p.rect.w, p.rect.y + p.rect.h - 1}, 2, p.theme.color.focus_ring)
}

n := baldr.custom(ui, stars, s, width = 160, height = 30, label = "Rating", role = .Slider,
	focusable = true, keys = {.Left, .Right}, on_key = on_key)
baldr.clickable(ui, n, Msg(Rate{}))      // a click, Enter and Space
baldr.pointer_track(ui, n, on_hover)     // where the pointer is, for a preview
```

- **Painting:** `draw_rect`, `draw_circle`, `draw_line`, `draw_polyline`,
  `draw_arc`, `draw_bezier`, `draw_icon`, `draw_text` (it copies the string,
  so a `tprintf` is fine), `draw_text_size`, and `draw_clip` /
  `draw_unclip`. There is no filled polygon yet. The painter gives `rect`, `theme` and `user`,
  and whether the widget is `hovered`, `pressed`, `focused` or `disabled`.
  What is drawn dims with a disabled or fading container by itself.
- **Size:** `width` / `height` / `flex`, or a `measure` proc that answers
  for the room offered.
- **Redrawing:** the view is built again after a message, and a custom
  widget repaints whenever it is built, so drawing straight from the app's
  state needs nothing more.
- **Accessibility:** give it a `role` and a `label`; `set_describe` adds
  its value as a reader should say it.

## Drawing your own: canvases

A canvas is a GPU texture the app draws into and shows — an image editor's
layers, a viewer's filters, a sketch pad.

```odin
// in update, once: ask for the device
return baldr.gpu_open(Msg, on_gpu)

// then, with the Gpu handle
c, ok := baldr.canvas_create(s.gpu, {1024, 1024}, .RGBA8, .sRGB)
baldr.canvas_fill(s.gpu, c, 0, 0, 1024, 1024, {1, 1, 1, 1})
baldr.canvas_write(s.gpu, c, x, y, w, h, pixels)
baldr.canvas_strokes(s.gpu, c, strokes, transform)

// and in the view — `canvas` is the builder that shows one
baldr.canvas(ui, s.gpu, c, width = 512, height = 512)
```

RGBA8, RGBA16 and RGBA32F, plus single-channel R8 and R16 for masks; a
colour space on every canvas (sRGB, Display P3, Adobe RGB, linear); blend
modes, filters, colour matrices and curves, LUTs, blur and sharpen, brush
dabs and variable-width strokes — each with a CPU reference implementation
the GPU path is checked against. You can supply your own shader through
`canvas_shader`, and import another process's buffer with
`canvas_import_dmabuf`.

**Video** is shown this way too. Baldr decodes no video, as it decodes no
audio: a player's own decoder (libmpv, GStreamer, FFmpeg, or the system's)
hands over each frame, as pixels written to a canvas (`canvas_write`, or
`canvas_write_begin` / `canvas_write_end` to decode straight into it) or,
on Linux, as a GPU buffer imported with `canvas_import_dmabuf`, which keeps
the frames off the CPU altogether.

Canvases live in VRAM and have no CPU copy, so a GPU reset loses them. Set
`App.gpu_reset` and rebuild from whatever you do keep;
`BALDR_SIMULATE_GPU_RESET=2000` rehearses one. Everything *the toolkit*
uploaded — glyphs, icons, images — comes back on its own.

## Memory and lifetimes

Three rules, and one trap that has bitten twice.

**The trap: `App.init` runs inside a frame whose temp allocator is freed
under it.** A string borrowed from `os.get_env(…, context.temp_allocator)`,
or a slice of something built on the stack, is a dangling pointer by the
first `update`. Clone what you keep. Both times this happened it looked
exactly like the toolkit misbehaving: a value that was right at startup and
wrong a frame later.

**A value in a message lives until that update returns.** A `Files`
dialog outcome, a `Relaunch`'s arguments, an `Ev(string)`'s text — clone
anything you store.

**Per-wake-up scratch goes in `ui.frame_arena`**, and anything a public proc
returns says in its doc comment whose memory it is: yours to free, the
frame's temp memory, or an alias into a document, a node or the tree. If a
doc comment does not say, that is a bug worth reporting.

## Untrusted input

Much of what an app shows comes from somewhere else: a picture in a
message, a file someone dropped, a link, the clipboard, another program on
the bus. Baldr's half of handling it is bounded, and this is what it
promises.

- **Pictures.** `image_load` reads PNG, JPEG, GIF, WebP, BMP, ICO, QOI,
  TGA, netpbm and SVG (and `image_load_xpm` the XPM icons older programs
  install), all in Odin. An animated GIF or WebP comes back as an animation
  the toolkit plays, composed frame by frame as browsers show it, and a
  JPEG is turned upright by its EXIF orientation. The size a file's header
  claims is checked before anything is allocated: past
  `IMAGE_LOAD_MAX_PIXELS` (128 million pixels, 512 MB decoded) or 1,048,576
  on a side it is refused, and `max_pixels` sets a tighter budget where
  pictures come from strangers. An SVG draws at most 100,000 elements, and
  an animation's frames together at most a set number of pixels, so a file
  built to repeat itself a million times ends at once (a hostile GIF in
  about half a second) instead of holding the app. A truncated or
  malformed file is refused.
- **Opening things.** `open_url` hands over http, https and mailto only,
  and refuses a mailto that names a file to attach. `open_path` opens
  documents: it refuses anything executable, and any file a desktop would
  run rather than open — programs, scripts, installers, shortcuts, `.desktop`
  launchers, macOS application bundles — whatever its permissions say, so
  an attachment saved as `invoice.pdf.exe` is refused, not started. Neither
  goes through a shell.
- **Pastes and drops.** On Linux, where another program streams the data
  itself, a read stops at 256 MB, and a paste at ten seconds however slowly
  it trickles in. A dropped or pasted file list gives local paths only: a
  URI naming another machine, a relative path or a hidden NUL is left out.
- **Notifications.** Wherever the desktop reads markup in a notification,
  the body is escaped, so a link or a picture in a message's text is shown
  as text.
- **Other programs.** A D-Bus message past Baldr's limits costs only that
  message, never the connection. A screen reader, or anything posing as
  one, acts only on what a reader is shown: nothing hidden, and nothing
  behind an open dialog. A password field shows readers only bullets, and
  `sensitive` text shows no tooltip.
- **One instance.** The relaunch socket lives where only the same user can
  reach it (a private folder on Linux and macOS; on Windows a pipe named
  for the user that only they may open), so another user cannot claim an
  app's name and be handed the files it was asked to open.
- **Secrets.** `secret_set` scrubs its copies, and a `Secret` a lookup hands
  you is yours to `secret_scrub`. The debug logs leave out what passes
  through: `BALDR_DEBUG_EVENTS` does not print what is typed into a
  password field, and `BALDR_DBUS_DEBUG` prints message headers, not
  bodies.

Odin keeps bounds checking on in optimised builds. Baldr turns it off in
two loops only, both in the WebP decoders (lossy colour conversion and the
lossless predictor, where the checks cost three times the loop), and each
first checks the lengths that cover every index it reads. Everywhere else
it stays on, so unless an app builds with `-no-bounds-check` a mistake in
any of this is a crash rather than memory written where it should not be.

What Baldr does not decode — AVIF, HEIC, JPEG XL and TIFF pictures, video,
compressed audio — is the app's to decode, with a library it trusts. Hand
over the result: RGBA pixels through `image_from_rgba` (or
`image_from_rgba_frames` for an animation), video frames to a canvas (see
[Drawing your own](#drawing-your-own-canvases)), and PCM samples to
`baldr:audio`.

## Shipping your app

Build it optimised: `odin build myapp -collection:baldr=/path/to/baldr
-o:speed` (`-o:size` is a little smaller). The program carries its own fonts,
icons and Unicode data, so it runs on a machine with nothing installed beyond
what the operating system ships. What each system wants around it:

- **Linux.** On Wayland the desktop names and draws a window from the
  `.desktop` file called like the app's `app_id`, so install one, with its
  icon in the icon theme:

  ```ini
  # ~/.local/share/applications/dev.example.notes.desktop
  [Desktop Entry]
  Type=Application
  Name=Notes
  Exec=notes
  Icon=dev.example.notes
  StartupWMClass=dev.example.notes
  ```

  with the picture at `~/.local/share/icons/hicolor/256x256/apps/dev.example.notes.png`
  (or under `/usr/share` for every user). On X11 the same file serves, and
  `App.icon` also puts the icon on the window itself.
- **Windows.** Build with `-subsystem:windows`, or a terminal opens behind
  the app. For its icon in Explorer and on the taskbar, compile one in: an
  `app.rc` holding `1 ICON "app.ico"`, built with `-resource:app.rc`. Baldr
  uses that resource for every window when `App.icon` is nil.
- **macOS.** Ship an app bundle, not the bare binary: `Notes.app/Contents/
  MacOS/notes` beside a `Contents/Info.plist` naming `CFBundleExecutable`,
  `CFBundleIdentifier` (the `app_id`), `CFBundleName`, `CFBundlePackageType`
  `APPL` and `NSHighResolutionCapable` true, without which it draws blurred
  on a Retina screen. An `.icns` in `Contents/Resources`, named by
  `CFBundleIconFile`, is its Dock icon. `build.sh` makes the minimal bundle
  for every example; its `mac_bundle` is a starting point.

The fonts and data Baldr carries come with licences that ask for a notice
in an app that ships them: [`THIRD_PARTY.md`](../THIRD_PARTY.md) lists them.

## Testing without a window

Layout, reconcile, paint and accessibility all run headless. No GPU, no
compositor, no window — which is why the suite is 1,594 tests and runs in
under a second.

```odin
ui: baldr.Ui(Msg)
baldr.ui_init(&ui)
defer baldr.ui_destroy(&ui)

baldr.set_viewport(&ui.tree, {400, 300})
baldr.begin_view(&ui)
    baldr.column(&ui, padding = .lg)
    n := baldr.button(&ui, "Save", Msg.Save)
    baldr.end(&ui)
baldr.end_view(&ui)
baldr.frame(&ui.tree, {400, 300})

// drive it exactly where the backend does
baldr.pointer_move(&ui, {40, 30})
baldr.pointer_button(&ui, .Left, true, {40, 30})
baldr.pointer_button(&ui, .Left, false, {40, 30})
baldr.key_event(&ui, .Tab, true, {})

testing.expect_value(t, len(ui.msgs), 1)       // the messages it emitted
for c in baldr.draw_list(&ui.tree) { … }       // the shapes it drew
baldr.access_dump(&ui.tree)                    // the tree a screen reader sees
```

Assert the emitted messages and the `Draw_Rect`s, not a screenshot. Synthetic
drags are the one thing to be careful with: a compositor's injected drag can
deliver a press and a release with no motion in between, so anything that
needs the pointer to *travel* — a text selection, a slider scrub, a reorder —
is driven through `pointer_move` / `pointer_button` in a headless test
instead.

What a headless test cannot tell you is what the desktop will do with a
surface. A size, a state, a configure, an ack — those are a conversation with
the compositor, and a passing test can pin exactly the wrong contract. Run it
for real.

## Debugging

```bash
BALDR_DEBUG_FRAMES=1 build/app    # per-frame phase times, icons rasterised, atlas uploads, asked→drawn delay
BALDR_DEBUG_EVENTS=1 build/app    # pointer enter, hover changes, what each click hit
BALDR_DEBUG_MEMORY=1 build/app    # the heap every 10 s (=N for N s), and the lines of code whose live memory grew
BALDR_DEBUG_BOUNDS=1 build/app    # name any node that draws outside the area a repaint of it clears (your `custom` widgets too)
BALDR_WAYLAND_DEBUG=1 build/app   # protocol: globals bound, configures, which output a surface entered
BALDR_X11_DEBUG=1 build/app       # the same for X11, including which input path is live
BALDR_A11Y_DEBUG=1 build/app      # the accessibility bridge
BALDR_DBUS_DEBUG=1 build/app      # every D-Bus message's header (=body adds the body, where secrets travel)
BALDR_VALIDATE=1 build/app        # Vulkan validation (on by default in debug builds)
BALDR_FAST=1 ./build.sh example <name> run   # -o:speed — judge speed with this, never the debug build
```

A laggy feel with sub-millisecond phase times points at input delivery, not
rendering.

**Leaks are growth.** An app's state lives until it exits, so what is left at
exit is mostly the app's own model. `BALDR_DEBUG_MEMORY` reports instead what
grew while the app ran: the heap and the process's size, then each line of
code that holds more than at the last report, net — a page laid out again in
place of another nets to nothing. Do the same thing round and round (every
page, a menu opened and closed, a field typed into and cleared): caches fill
on the first lap and stop, and a leak is a line that is up in every report.

```
baldr/memory: 9.7 MB live in 5,118 allocations (peak 9.8 MB); process 160.5 MB; since the last: +30 allocations, +5.5 KB
       +12     +5.2 KB  runa/cache.odin:179 shape_text_cached
        +5       +48 B  baldr/widget_text_input.odin:1158 input_undo_record
```

That is the gallery on its seventh lap of every page. Both lines are up on
every lap, and neither is a leak: the shaping cache keeps the strings each
lap shows for the first time ("Message 7 sent"), up to 4,096 of them, and a
field's undo history keeps the edits typed into it, up to 64. A line that
grows every lap is where to look. Whether it has a cap is the question.

Everything allocates more slowly while it watches. A worker thread's own
allocations are not counted, and nor is what the GPU driver or the
platform's libraries hold, which is what the process figure is for. A run with the validation layer says so once on stderr; if that
line is missing, the run proves nothing about Vulkan correctness, and there
is no known-noise list — every validation message is a fault.

---

Next: [`widgets.md`](widgets.md) for the per-widget detail,
[`API.md`](API.md) for every declaration, and
[`CONTRIBUTING.md`](../CONTRIBUTING.md) if you are changing the toolkit
rather than using it.
