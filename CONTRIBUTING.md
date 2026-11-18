# Contributing to Baldr

Read [`docs/guide.md`](docs/guide.md) first if you have not used Baldr, and
[`docs/widgets.md`](docs/widgets.md) for how an existing widget behaves.
This file is the part that is about *changing* the toolkit: the rules a patch
is judged against, and the traps this codebase has already paid for.

The short version: **consistency beats cleverness.** A widget that invents
its own vocabulary, its own key bindings or its own accessibility story
costs every app that uses the toolkit more than it saves you.

## Commands

```bash
./build.sh test                     # headless tests (odin test on package baldr and friends)
./build.sh check                    # odin check every package, every target
./build.sh example <name> [run]     # examples/<name>
./build.sh gallery                  # the gallery alone — the routine check after an API change
./build.sh examples                 # every example — the full sweep, before a commit batch
./build.sh spike <name> [run]       # spikes/<name>
./build.sh api                      # regenerate docs/API.md from the doc comments
BALDR_FAST=1 ./build.sh example <name> run   # -o:speed: judge speed with this, not the debug default
BALDR_DEBUG_FRAMES=1 build/<name>            # per-frame phase times, icons rasterised, atlas uploads
BALDR_DEBUG_BOUNDS=1 build/<name>            # name any node that draws outside its paint bounds (the tests always check)
BALDR_SIMULATE_GPU_RESET=2000 build/<name>   # pretend the card was reset after 2 s
```

**Toolchain: Odin `dev-2026-11a` or newer.** That is a floor rather than a
preference — it is where the `when`-shadowing vet check and the Windows
cross-check shape below come from. Odin has no incremental compile, so every
build type-checks the whole toolkit afresh; that is seconds, not minutes,
because the test files sit behind `when ODIN_TEST ||
#config(BALDR_TESTS, false)`. Keep that `when` in mind when you add a test
file: `./build.sh test` sets `ODIN_TEST` and `./build.sh check` passes
`-define:BALDR_TESTS=true`, so the gate reads them either way, but an *app*
that imports Baldr must not have to type-check its test suite. Before that
`when` existed, `odin check` of a program that called nothing peaked at
9.2 GB and 93 s; it is 0.18 GB and 0.2 s now.

`./build.sh check` cross-checks Windows and macOS from any host. The Windows
pass goes through `odin build -build-mode:obj` rather than `odin check`,
because `-target:windows_amd64` demands `-windows-sdk-root` and `check`
refuses that flag; an obj build never links, so the path is never read. It
earns its place — it is what catches a test file that needed `#+build linux`.
The macOS pass is a plain `check`, and it is the only thing that reads
`platform/cocoa` on a non-Mac host: every file in there is darwin-only, so a
Linux-only gate checks an empty package and says nothing at all. That gap
once broke the Mac build for a day, when `gpu` turned out to have two
`Page_State` structs — Vulkan's and Metal's — and a field added to one was
read through code they share.

**The gates are not light.** Measured on Linux with Odin `dev-2026-11a`,
as the peak resident size of the largest single compile —
which is the number that matters, since both gates run the compiler one
package at a time:

| gate | wall | peak RSS |
|---|---|---|
| `./build.sh check` | 25 s | 5.2 GB |
| `./build.sh test` | 51 s | 8.6 GB |

`check` reads the portable packages natively, then cross-checks the Windows
and macOS targets, and then the **five spikes that drive `platform.Backend`
itself** — `cocoa_check`, `baldr_metal`, `win32_check`, `wayland_check`,
`x11_check` — each for its own target. Not the other ninety spikes. Those
five are in because four of them had **stopped compiling** and no gate read
them: three are buildable only for a target this box is not, and a spike is
run by hand when somebody is already asking it a question. They cost about
1.8 s, which does not move the figure above.

So **do not start a second compile beside either**: 8.6 and 5.2 together do
not fit in 16 GB, and the pair swapping looks exactly like a hang. A gate
that takes *minutes* is contention, not slowness.

Re-measure these rather than copy them forward: that is the rule this file
sets for everything else.

`./build.sh check` runs the compiler single-threaded on purpose: the nightly's
parallel parser has raced when `-vet-packages` is given. It may be fixed, but
the flag buys the vet passes and dropping it would save a fraction of 25 s,
so it stays.

## The dependency rule

**Allowed:** `core:*`; `vendor:vulkan`; `vendor:darwin/*`; `core:sys/*`; OS
libraries loaded at runtime via `core:dynlib`; `third_party/runa`.

**Forbidden:** SDL, GLFW, stb, fontstash, FreeType, HarfBuzz, Skia, libdecor,
libdbus, GTK/Qt, `vendor:x11/xlib`, **any C compiled into the tree**.

If a task seems to need one, stop and write down why instead. This is what
makes `odin build` the whole build, and lets every platform's build be
type-checked from one machine; it is not negotiable per-patch. (`libwayland-client`, `libxkbcommon` and `libxcb` are
loaded at runtime because Vulkan's presentation layer takes a real connection
handle and the driver uses it — a hand-rolled protocol implementation can
open a window and then never show a Vulkan image in it. They are tolerated
while required, and `platform/xkb` is marked as such.)

## API vocabulary — never invent a synonym

| Concern | Names |
|---|---|
| events | `on_click`, `on_change`, `on_submit`, `on_cancel`, `on_hover`, `on_focus` (via `focus_track`), `on_key`, `on_context`, `on_middle_click`, `on_scroll`, `on_double_click`, `on_commit` (a value let go of or stepped to by a key), `on_samples` (every pointer and pen sample), `on_text` (text an input method committed), `on_paste_other` (a paste that brought a picture or files, not text), `on_resize`, `on_word_click` (Ctrl+click on a word in a code editor), `on_ask` (a completion source that answers later); `on_event` for a node that reports several kinds of thing; `on_state` for what the **desktop** did to a surface; `shortcut(ui, "Ctrl+N", msg)` for a window-level key |
| identity | `key` (reconciliation), `tag` (echoed back in `Ev.tag`) |
| look | `variant`, `tone`, `size`, `role`, `weight`, `tabular` (figures all one width), `quiet` (draws no hover or press wash), `icon` (a Lucide icon), `theme_icon` (one from the desktop's icon theme, by name) |
| box | `width`, `height`, `min_width`, `min_height`, `max_width`, `max_height`, `flex`, `padding`, `margin`, `gap`, `align`, `justify`; `gutter` (keep content clear of the overlay scrollbar — always reserved, because on demand it oscillates) |
| your own widget | `custom` (a node that sizes and paints itself) with a `Painter` and `draw_rect`, `draw_circle`, `draw_line`, `draw_polyline`, `draw_arc`, `draw_bezier`, `draw_icon`, `draw_text`, `draw_text_size`, `draw_clip` / `draw_unclip`; its keys while focused are `keys` with `on_key` |
| a11y | `label`, `describe`, `live` |
| state | `disabled`, `hidden`, `selected`, `checked`, `expanded`, `pressed`, `inert` (draws, takes no pointer, keyboard or place in the a11y tree), `set_invalid` / `set_required` (any form control: a danger frame on a field, and the states readers are told), `set_tab_stop` (`false`: a press focuses it and a reader reaches it, but Tab passes it by), `set_hit_children` (the container's own space lets the pointer through, children stay hittable), `focus` |
| async | commands from `update` or `App.start`: `job`, `cancel`, `batch`, `delay`, `read_file`, `write_file`, `copy_text`, `copy_files`, `paste`, `open_url`, `secret_get` / `secret_set` / `secret_delete`, each with `on_done`; `notify` / `notify_close` with `on_event`; in a worker: `post`, `cancelled`; `focus(Msg, key)`; subscriptions from `App.subscriptions`: `every`, `watch` with `on_change` |
| desktop | what it lists: `outputs()`, `toplevels()`, `workspaces()`, kept current by `outputs_changed`, `toplevels_changed`, `workspaces_changed`; commands: `toplevel_activate`, `toplevel_set_minimized`, `toplevel_set_maximized`, `toplevel_set_fullscreen`, `toplevel_close`, `workspace_activate`, `workspace_assign`; `toplevel_spot(ui, n, id)`; `applet_slot`; `lock_session` / `unlock_session` |
| preferences | the desktop's, followed unless the app owns them and says: `App.a11y` / `set_a11y_prefs`, `App.titlebar` / `set_titlebar_prefs`, `App.accent` (an app's own colour that still follows light/dark and contrast) vs `App.theme` (names a theme and follows nothing), `set_text_scale` (**multiplies** the desktop's), read back with `a11y_prefs(t)` / `text_scale(t)`; `App.size` / `App.maximized`, answered by `on_state` |
| virtual views | `on_range` on `list` / `table` / `icon_view`; rows of different heights: `estimated_height` with `key_of` (a **stable** key, because the default `u64(i + 1)` is renumbered by a prepend) or `height_of`; where it rests: `follow_end`, `on_at`; **moving it is a command, never a parameter** (a view is rebuilt constantly, so an ask held in it would happen again on every build): from `update`, `reveal_key` / `reveal_index` bring a row into view, `hold` keeps a named point still and `hold_at` keeps whatever is at a spot of the viewport — the one to reach for, since an app's own note of where it was looking goes stale between builds. Both take `axes` to leave an axis alone and `surface` to name a window. A row only the build knows — a chapter the view has just typeset — is asked for from inside the view with `reveal_now`, `reveal_now_index`, `hold_now`, `hold_now_at` |
| edit in place | views ask with `on_edit` (F2 / slow click); the app answers with `cell_edit` or `on_submit` / `on_cancel` on `icon_item` / `tree_item` |
| a field's caret | read `text_input_selection(t, n)`; set `text_input_set_selection`, `text_input_select_all`; insert as typing would with `text_input_insert(ui, n, text)` — **not** `text_insert` on the `Text`, which the undo journal never sees |

**Behaviour is a vocabulary too** — the same key does the same thing in every
widget. Enter commits a typed value and selects it, focus stays. Escape
reverts, and only then goes on to close a popover. Leaving a field commits.
Up / Down step, Shift ten. Home / End go to the ends. A menu or list opened
with the pointer highlights nothing until a key: Down goes to its first item,
Up to its last, and Enter acts only on what shows. A click on a two-state
part flips it. In a dialog, an Enter the focused control does not use
activates the dialog's `default` button. An arrow, Home, End or Page key held
with Alt or Super is the window's — Back, Forward, Up — never a view's
cursor. A key a view declines goes on to the window's shortcuts. A disabled
control dims its text, icons and pictures by `state.disabled_alpha` and shows
no hover or press.

**A dismissal is never the destructive choice.** A scrim press or Escape
means "not now". Someone who clicks beside a dialog has chosen nothing, so
anything destructive belongs on a button inside it. Three separate apps built
on Baldr shipped a dismissal that threw away the crash-recovered work the
dialog was offering to restore; when one mistake appears in several apps it
is the toolkit's problem, not theirs.

## Builder shape

Every builder: `proc(ui: ^Ui($Msg), <required>, <named defaults>…, loc := #caller_location)`.

One builder per widget. No `_simple` / `_payload` / `_impl` variants. A
builder carries what every use needs — the value, the handlers, `label`,
size, `disabled`, `tag`, `key`. Rarer settings go on a **modifier** called
with the node the builder returned:

```odin
editor_options(ui, ed, wrap = true)
draggable(ui, n, "file")
tooltip(ui, n, "…")
```

…so the common call reads as a sentence and the power is one line away. A
modifier's settings stay until changed; per-build inputs (marks) are passed
every build. Payload handlers are
`Handler(Msg, T) = union { Msg, proc(Ev(T)) -> Msg }`.

## Scoped builders — the one view style

A container's children go in a block, and `defer baldr.end(ui)` is the first
line inside it. One shape, every time, so the `end` is never the thing a
reader has to go looking for:

```odin
baldr.column(ui, flex = 1, gap = .md); defer baldr.end(ui)  // the proc's own: see below
baldr.text(ui, "hi")                                        // leaf, no end
baldr.tab_bar(ui, s.page, PAGES, on_page)                   // a leaf: no end

baldr.row(ui, gap = .sm); {                                 // every container inside
	defer baldr.end(ui)
	baldr.button(ui, "OK", Msg.Ok)
}
```

Two exceptions, both because the braces are already there:

1. **The proc's outermost container** is written flat, as the proc's first
   statement — the proc's own braces are its block. (`01_hello` is the whole
   pattern in eight lines.)
2. **A builder that answers whether it opened** carries the block on its
   `if`: `if baldr.tab_panel(ui, s.page == 0, 1) { defer baldr.end(ui); files(ui, s) }`,
   or, where the scope is the rest of the proc,
   `if !baldr.component(ui, "files", s.files_rev) do return` with the defer on
   the next line.

And one place the rule cannot reach, written down rather than left looking
like a slip: a container opened in one branch of an `if`/`else`, closed by a
single flat defer after it (`examples/14_bar_applets`). It carries a comment
saying so, and so should any other.

A modifier takes the container's node rather than opening a scope, so it goes
*inside* the block with the children: `pointer_track`, `transition`,
`theme_area`, `clickable`, `draggable`, `tooltip` and the rest. Capture the
node on the opening line when one needs it
(`n := baldr.row(ui, …); {`).

Defers are LIFO, which is the correct nesting, and a view that returns early
still closes its tree — which is why this and not a bare `end` call. A
missing `end` is a runtime error naming the opener's location.

## No lazy widgets

A widget asked for is a real widget: designed for the job, not a quick
composition of other widgets. The first time picker was three number fields
and a segmented control — it looked like it, and it was replaced. Sketch how
the best desktop toolkits do it, then build that: its own pointer, keyboard,
wheel and touch paths, its own accessibility mapping, its own look. If the
honest version is too big for the session, say so instead of shipping a
stand-in.

## Two doors, one rule

**Builders for everything.** The second door is the node a builder returns:
`set_*` procs and modifiers applied to it (`set_inert`, `set_hit_children`,
`editor_options`, `draggable`, `tooltip`), for custom widgets, editors,
canvases and shells. A fuller imperative handle API (`mount` / `update`) is
designed but **not built** — do not write docs or comments that imply it
exists.

## Accessibility is part of "done"

A widget is incomplete without an `Access` role / name / state mapping,
keyboard operability, a focus ring, and a headless test asserting its
accessibility tree. The debug lint must stay silent on the gallery.

## Adding a widget

1. `baldr/widget_<name>.odin` — builder, node kind data, a11y mapping, keyboard handling.
2. A doc comment on every public proc and type: what it does, when to use it, what fails.
3. `examples/NN_<name>/` — under ~150 lines.
4. Headless tests in `baldr/<name>_test.odin`: layout, events → messages, a11y dump.
5. A `docs/widgets.md` entry — one row: signature, behaviour, accessibility.
6. A `CHANGELOG.md` entry under Unreleased.
7. `./build.sh test`, `./build.sh check` and `./build.sh gallery` clean; the
   full `./build.sh examples` before the commit batch lands; `./build.sh api`
   regenerated.

Doc comments **are** the API reference: one short paragraph per public proc
or type, and nothing that reads like a lecture.

## Code conventions

- Odin style: `snake_case` procs, `Ada_Case` types, `SCREAMING` constants, tabs.
- No global mutable state; everything hangs off `^Ui` / `^Platform` / `^Renderer`.
- Explicit allocators on anything that allocates for the caller; per-wake-up scratch goes in `ui.frame_arena`.
- **A public proc that returns memory says whose it is**, in its doc comment:
  the caller's to free, the frame's temp memory (copy what you keep), or an
  alias into a document, a node or the tree — and what invalidates it. A
  default of `context.temp_allocator` is not obvious from the signature to
  someone reading the generated docs, and freeing it is a crash that looks
  like something else. It cost the first app built on Baldr three of them in
  a day.
- Errors are values (`(T, Error)`); never panic on user input or malformed external data.
- Coordinates are logical pixels everywhere except inside `gpu/`.
- Headless first: layout, reconcile, paint and a11y must run and be tested without a window.

## Comments

A comment says what the code cannot: **why** it is this way — an invariant,
a unit, whose memory something is, a consequence that is not obvious, the
trap the obvious version falls into. Not what the next line does, and not how
the code came to be.

- **Short.** An inline comment is a line or two. A doc comment is one short
  paragraph — what it does, when to use it, what fails, whose memory it
  returns — with an example when one helps.
- **No history.** No dates, no request or issue numbers, no "found when…",
  "reported by…", "used to…", no story of what an app or a person saw. The
  history belongs in the commit message and the `CHANGELOG`; the code says
  only what is true of it now.
- **No names** of people, apps, machines or other projects (Skald and runa
  excepted, where they are the subject). Platforms and standards the code
  talks to — Windows, macOS, GNOME, KDE, Wayland, the desktop portals — are
  named wherever the code needs them.
- **A number stays when it explains a value** ("4,096 entries: a long
  chat's paragraphs fit"), stated as a fact, without the run it came from.
- **Tests too.** A test's name says the behaviour it pins, not the request
  it came from; its comments follow the same rules.

## Odin traps this codebase has paid for

**Give a nested compound literal a type before passing it.** A slice of
structs written inline in a call, with its element type, its struct type and
its nested fields all inferred through the parameter, can cost the compiler
*minutes*:

```odin
editor_marks(ui, n, {{from = {0, 0}, to = {0, 9}, kind = .Dim}})  // 13+ minutes
marks := []Mark{{from = {0, 0}, to = {0, 9}, kind = .Dim}}        // 4 seconds
editor_marks(ui, n, marks)
```

One test file with five such calls took `odin test` from 1m52 to over fifteen
minutes and 9.2 GB, where it was killed having never finished; naming the
slices with their type put it back. One or two levels of inference are fine —
this is about a literal whose every layer is inferred at once. If a build
suddenly costs minutes, look for one of these before anything else.

**A test file's helper needs a name no other file in the package uses.** The
vet pass rejects a declaration inside a global `when` that shares a name with
anything else at package scope — including another test file's helper, and
including a builtin, and it does so even when both are `@(private = "file")`
and therefore cannot collide in fact. Prefix a helper and its message type
with the file's own subject (`settle_grid`, `Spark_Msg`), and never take a
bare verb a builder already owns.

**A vet error in a file you did not touch is probably real.** The vet flags
are kept per AST file and assigned as the package is read, so adding a file
can start reporting a latent fault elsewhere. Read it and fix it rather than
hunting for what you broke — both times this happened it was a one-line
rename of a genuinely shadowed variable.

**Read the test runner's leak report.** `odin test` prints `+++ leak …
[file.odin:NN:proc()]` under any test that ends holding memory — as a WARN,
so the run still says "All tests were successful" and the lines scroll past.
Two real leaks sat there for a day that way. Keep the report *silent*,
including for leaks that are the test's own tidying-up, because a report with
known noise in it is one nobody reads. After a run: `grep leak` the log.

**A ternary into a union is not nil.** `h if c else nil` gives a *nil proc
inside the union*, which is not the same as an empty union — use
`handler_live` to ask whether a handler is really there.

**A node's rect is relative to its parent.** Comparing a grandchild's rect to
an ancestor's reads the wrong number, and a test that does it can pass
vacuously.

## Seeing what you rendered

**Never call rendering done from the code alone.** Run the example or the
gallery, capture the window, look at the PNG — corners, borders, clip edges,
text — and compare it against what the code intended. Verify at 1:1 zoom, and
at phone width for anything responsive. The validation layer is on by default
in a debug build (`BALDR_VALIDATE=0` turns it off, `BALDR_FAST=1` builds
without it) and a run that has it says so once on stderr; if that line is
absent, the run proves nothing about Vulkan correctness. There is no
known-noise list: every validation message is a fault.

**A 16 px icon is 16 px to look at**, so a window capture is the wrong
instrument for one. `./build.sh spike icon_sheet run sparkles palette`
rasterises it the way `icon_slot` does and prints its coverage as characters
at the size it is drawn at, beside whatever else you name for comparison.
That is how to tell a ring from a blob and a four-pointed star from a five,
which a test asserting "the bitmaps differ" cannot.

**Never call a window-management change done from its tests alone.** Anything
that touches what the desktop does with a surface — a size, a state, a
configure, an ack — is a conversation with the compositor, and a headless test
can only pin what we *believe* the other side will do. One such change
shipped with four passing tests that pinned exactly the wrong contract: the
request went through the mechanism a rolled-up title bar uses, which holds
its size against every configure on purpose, so the window could not be
resized by hand at all. `spikes/window_size` is the instrument for that, and
`spikes/keep_awake` and `spikes/dmabuf_import` are the same idea for their
protocols. A spike whose output is a *sequence* beats a screenshot here:
what went wrong is usually an event that did not arrive.

**Measure before diagnosing.** Reading the code and reasoning about a flicker,
a timing or a contrast produced four wrong causes in one day. Run the
reporter's repro unmodified before concluding it is not a bug, and time your
own instrument before trusting what it tells you.

**Mutation-test a subtle test that passed first time.** Break the thing it
covers and watch it fail, then put it back. A test that cannot fail is worse
than no test.

## Commits

Conventional short subjects: `layout: relayout boundaries`,
`theme: pills follow its full radius`.

**Nothing about a downstream app goes in the repo.** Apps built on Baldr are
other people's products: their bug reports quote screenshots, data shapes,
and what the app does and why. What may be committed is the *toolkit's* side
— a test, a comment explaining why a widget behaves as it does (see
*Comments*: the reason, not the story). Commit messages and the
`CHANGELOG` describe the change itself, as an addition or a fix to the
toolkit: never which app asked for it, and no request or issue numbers from
outside this repository. Where an app has to be mentioned, describe it only
by what it is: "a chat app", "a file manager". The same goes for machines
and people: no host names, no real paths, no names.

**Skald and runa may be named.** They are the author's own projects, public
and linked from the README — Skald is the sibling Odin GUI framework, runa
the text engine vendored in `third_party/runa/`. There is no need to write
around them, and prose that does ("the earlier toolkit") should say which
toolkit.

## AI-assisted contributions

Most of this toolkit was written with an AI assistant (the README says so
under *How this was built*), so a patch written the same way is welcome
here and needs no apology. It is judged by exactly the rules above, and
those rules are what the assistant is held to as well:

- **Run the gates and paste what they said.** `./build.sh test` and
  `./build.sh check`, plus `./build.sh gallery` after an API change and the
  full `examples` sweep before a batch. "It should pass" is not a result,
  and `grep leak` the test log — the runner reports a leak as a WARN under
  a test that still says it succeeded.
- **Break it on purpose once.** If a new test passed the first time, mutate
  the code it guards and watch it fail. A test that passes against a broken
  build tells nobody anything.
- **Run it, if it draws.** A rendering or window-management change is run,
  captured and looked at; see *Seeing what you rendered*. Tests alone
  cannot pin what a compositor does.
- **Don't let it invent vocabulary.** The API vocabulary table above is the
  whole list of names; a new synonym is a defect however well it reads.
- **Say what is unverified, in the patch.** A path that type-checks and has
  never run is a normal thing to contribute — labelled. Quietly implied
  verification is the one thing that is not welcome, whoever or whatever
  typed it.

A generated patch is yours when you send it: you are the one saying it
works.
