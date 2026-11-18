# Widgets and builders

Every builder takes `ui: ^Ui($Msg)` first and `loc := #caller_location` last;
everything else is named with a default. Containers open a scope you close
with `end(ui)`. Colours come from the theme; sizes are logical pixels or
`Space` tokens (`.xs .sm .md .lg .xl …`). Handlers are `Handler(Msg, T)`: a
plain message, or `proc(Ev(T)) -> Msg` receiving the value and the node's
`tag`. Screenshots: `examples/` (one per feature) and `02_theme_lab`.

## Layout

| Builder | Notes |
|---|---|
| `column(ui, gap, padding, align, justify, width, height, flex, bg, radius, material, offset, tag, key)` | vertical stack; children stretch to its width by default (`align = .Stretch`); `flex = 1` fills the parent's main axis; `tag` is echoed back in `Ev.tag` to handlers on this node, which is how a `pointer_track`'s plain proc learns which row it is on — 0 leaves a tag a `draggable` or `clickable` put there alone |
| `row(ui, …, vertical, tag)` | horizontal stack, same parameters; `align` defaults to `.Start` (use `.Center` to line controls up, `.Stretch` for equal-height cards); `vertical = true` stacks the children top to bottom, stretched across (`vertical = size_class(ui) == .Compact` for phone width); when the row does not fit, the children that can give shrink first (see Responsive) |
| `wrap(ui, gap, padding, align, justify, width, height, flex, vertical, bg, radius, key)` | a row that breaks into lines when children do not fit; `flex` children grow to fill their line (reflowing card grids, chips, toolbars); `vertical` runs it down, starting a new column when the next child would not fit the height, as wide as its columns (a top bar's rows of applets) |
| `pages(ui, page, depth, label, key)` | one page of a set in the same place (a popover's tiles, then a tile's page): build only the current page inside and close with `end`; when `page` changes the new page slides in from the end and the old out to the start, whole and edge to edge (the other way when `depth` goes down) while the container eases its height to the new page's, keeping its width (at once under reduce motion); a page that leaves keeps its nodes and state; going deeper focuses the new page's first control, coming back the control that opened the page | Group, name = label |
| `column` / `row` / `stack` / `wrap` / `box` `border`, `border_width` | outlines it: a line of `border`'s colour, `border_width` px wide (1 unless said), drawn just inside its edge and round its `radius`, so it takes no room and moves nothing when it comes and goes — a card whose outline says it is the selected one. Set every build, as `bg` is, so leaving it out takes it away; a zero colour is no border. Children draw over it where they reach the edge, so a container whose children are flush with it wants `padding` as wide as the line. `scroll` has none: its content scrolls over its edge, so put the scroll inside a bordered `column` with that padding |
| `column` / `row` / `stack` / `wrap` / `card` / `scroll` `max_width`, `max_height` | caps a container whatever its content or its parent asks for: a message card, a conversation column. With the parent's `align = .Center`, a child of `width = W, max_width = W` is W wide and centred while there is room, and gives way below that — the readable column every chat app sets its text in |
| `scroll(…, follow_end = true)` | the scroll stays at its end while its content grows, and opens there: a chat following a streaming reply. Scrolling away from the end stops it following and leaves the offset alone; scrolling back within 2 px of the end starts it again |
| `editor_options(ui, ed, submit = .Enter)` | Enter sends `on_submit` and Shift+Enter breaks the line (a chat composer). The default `.Ctrl_Enter` is the other way round. An input method's Enter commits its composition either way, and the field describes itself "Enter to send, Shift+Enter for a new line" |
| `selection_scope(ui, n)` · `selection_scope_text(t, scope)` | makes `n` the owner of one selection across the text views inside it — a conversation's column, so a drag that starts in one message and ends in another selects everything between, each view drawing its own part. The views it gathers are the markdown views and text areas (read-only included) in it, in build order, which is the order they copy in. A selection inside one message stays that widget's own (double-click a word, triple-click a block) and becomes the scope's when the drag leaves it; a message in the middle shows its part although focus is elsewhere. Ctrl+C copies the messages in order, a blank line between them; Escape lets go; Ctrl+A escalates — the message first, the conversation on the second press. The ends are a view and an offset into it, so a streaming reply cannot move a selection made earlier. `selection_scope_text` is what is selected, in the frame's temp memory | the scope adds no node and no role of its own; the views keep theirs |
| `input_area(ui, n, on)` | marks `n` as part of where its surface takes the pointer when the surface declares `input = .Marked` (`Surface_Desc.input`: `All`, `Marked`, `None`); the region is the union of the marked nodes' rects and any popover open on the surface, follows layout and updates live (a floating bar's shape, a hidden dock's reveal strip, a magnified shelf); `None` takes no pointer at all |
| `backdrop_area(ui, n, on)` | marks `n` as part of where its surface is blurred behind when the surface declares `backdrop_region = .Marked` (`Surface_Desc.backdrop_region`: `All`, `Marked`): the region is the union of the marked nodes' rounded rects where they are drawn (following layout, slides and glides), the surface is clear elsewhere, and each marked node gives itself its glass (`card(glass = true)`): separate toast cards on one surface; a node on its way out leaves the region as its fade starts. **A marked node is also where the theme is adapted for glass**: what is built and painted inside it is solved for the wallpaper behind it (text, tint and washes), while the rest of the window keeps the colours the app set — a sidebar can be frosted without the chat column beside it having its accent re-tuned for a backdrop it never sits on. A window that declares `backdrop_region = All` is glass all over, and its whole theme is adapted, as before. **A pane painting its own ground must read `ui.theme` from inside the scope** — after this call, not before: the tree's theme is deliberately unadapted on a `.Marked` surface, so a tint or surface colour taken before it is the unsolved one under solved text, which is a contrast bug that looks like a rendering bug. `card(glass = true)` does it correctly by itself |
| `theme_area(ui, n, theme)` · `theme_on_ground(base, bg, ink, accent, name)` | builds **and paints** `n` and everything inside it in a theme of the app's own: a reader's Paper, Sepia, Dusk or Night page with its bar and buttons, a photo editor's dark canvas with its tools. Call it on the container whose scope is open, as `backdrop_area` is called; the tree's theme comes back when the scope closes. It is a theme and not a tint — a ghost button inside hovers in a darker sepia, its focus ring is the page's accent, and the state washes are solved for the page's ink, because the subtree is painted with it as well as built with it. **A popup opened from inside keeps the window's theme** (a `select`'s list, a `popover`, a menu, a tooltip): a popup is its own surface over the whole window rather than part of the page, and a Night-coloured menu over a Light window reads as another app's — put the popup's content in a `theme_area` of its own if it should match. `theme_on_ground` derives the whole theme from a ground, an ink and an accent: the surfaces step away from the ground toward whichever side has room (darker over cream paper, which has no white left above it), every pair that carries text or an edge goes through `ensure_contrast`, and the type, radii, spacing, motion and the desktop's accessibility preferences are the base theme's — so a page in the app's colours still obeys reduce motion, reduce transparency, high contrast and the desktop's text size. `examples/33_reading` |
| `text(ui, s, role, size, color, muted, nowrap, ellipsis, max_lines, align, weight, mono, family, tabular, italic, sensitive, width, min_width, max_width, flex, key)` … `weight` (`Regular`, `Medium`, `Semibold`) overrides the role's; `italic = true` sets it in the face's italic (a title, a term, a tab that is only a preview), a look only: readers are not told; `align` places each line within the node (Start / Center / End); sized as any leaf is: a fixed `width`, `min_width` / `max_width`, or `flex` for a share of a row's free space, wrapping at the width it ends up with (a label column beside the values it names is two texts in a row, no box around either); `nowrap = true` keeps one line; `ellipsis = .End` / `.Middle` trims with "…" when the text does not fit (one line, or up to `max_lines` wrapped lines); the accessible name stays whole; `\n` breaks the line, a tab reaches the next stop, and other control characters take no room and draw nothing; `mono = true` sets it in the code face — a tool step under a reply, a hash, a path, so the prose around it leads — and `family` in a family of its own, either one this machine has (`text_family`) or one the app carries (`text_family_bytes`). **`tabular = true`** asks the face for figures of one width (OpenType `tnum`, which Inter has), so a number that changes does not change width with it: a stopwatch, a countdown, a column of figures, a right-aligned answer being typed. Measurement asks for it too — the node's own width is what moves a centred number about — and a face without the feature ignores it, so asking is never an error.  **`sensitive = true`** marks the string a secret shown on purpose — a revealed key, a recovery phrase. The tree's copy is **overwritten before it is freed**, on replace and on destroy, and the node reaches the accessibility bridge **without its characters**: `text` otherwise makes the string the node's accessible name, and anything on the session accessibility bus can read a name, which is how a revealed key leaks with no file ever written. It hides nothing on screen — the person asked to see it. The cost is worth naming: a screen reader user who asked to see their key cannot hear it either, so put a Copy button beside it, which is what every password manager does and is the accessible path for a 63-character key anyway.|
| `spacer(ui, size)` | takes `size` px along the parent's main axis, or all the remaining space when 0: pushes siblings apart, right-aligns a row's tail |
| `applet_slot(ui, on_event: Handler(Msg, Slot_Event), min, preferred, label, key)` | a bar's place for another program's applet (the compositor's `rikkiti-applet-v1`): `preferred` long along the bar (down to `min` in a tight row), as thick as its row, drawing nothing; the runtime keeps the compositor's slot on the bar's surface in step with it (made, moved with the bar's commit, removed with the node or while hidden) and `key` keeps one slot per applet across rebuilds; `on_event` hears `Slot_Token{key, token}` (start the applet with `RIKKITI_APPLET_TOKEN`; clone the string to keep it), `Slot_Attached{key, pid}`, `Slot_Detached{key}` (a new token follows) and `Slot_Size_Hint{key, min, preferred}`; without `Applet_Slots` in `Backend.caps` it is an empty place that reports nothing; Group, name = label (none without one: the applet's controls are its own program's) |
| `stack(ui, padding, align, width, height, flex, bg, radius, tag, key)` | children overlap at the padding origin plus each child's `offset` (which does nothing in a row, column or card); the base for overlays and glass over content |
| `scroll(ui, axis, gap, padding, align, width, height, flex, bg, max_width, max_height, follow_end, gutter, content_width, key)` `gutter = true` keeps the content clear of the overlay scrollbar, which is otherwise drawn over the end of it — a row with a [Remove] button at its right sits underneath. The room is **always** reserved, not only while the content overflows: reserving it on demand narrows the content, which wraps the text, which makes it taller, which can make it overflow when it did not, and the layout then flickers between two answers. | children overflow along `axis`; without a `height` (`width` along a row) it takes its content's size up to `max_height` (`max_width`) and scrolls past it, for a popover's list; wheel/trackpad, Page Up/Down, Home/End and the overlay scrollbar move them (the bar shows dimmed while the pointer is inside, full and wide near the right edge); keyboard focus scrolls into view; give it a size. **`content_width` makes a column scroll sideways as well**: its children are laid out that wide rather than squeezed into its own width, it pans across them with the wheel's x, Shift+wheel, a touchpad, Shift+Page / Shift+Home / Shift+End and `scroll_by` / `scroll_to`'s x, and it draws a bar along its bottom with the vertical one still at its right edge (each track stopping short of the other's end). Give the width the app knows — a document viewer's widest page at this zoom — because in a virtualised view only the built children are measured and the widest of those would move the extent as it scrolled; a child naturally wider keeps its width and the others are widened to match. Zero scrolls only down, as before, and it is read every build, so a zoom changing it is one number |
| `list(ui, count, row_height, estimated_height, height_of: Row_Height, key_of: Row_Key, key_user, follow_end, on_at: Handler(Msg, List_At), gap, padding, flex, height, label, tail_pad, gutter, content_width, on_range: Handler(Msg, [2]int)) -> (first, last)` | virtualised: build rows `first ..< last` yourself, keyed by index (`key = u64(i + 1)`); the list makes every row exactly `row_height` tall and clips it (content that would not fit — a caption wrapping at phone width — is cut, never painted into the next row; give such text `nowrap` + `ellipsis`); the rest is two spacers; scrolling re-runs the view when the range moves, and `on_range` hears `{first, last}` each time it changes (the overscan included), so `update` can load what is on screen and cancel what scrolled away. **`estimated_height` + `key_of`** gives rows their own heights, measured once and kept by key. `key_of` is asked **only while the view is being built**, and always for an index of that build's own `count`, so `key_user` may point at the frame's temp memory; the list keeps the keys it built and uses those for the bookkeeping that runs after an event. It must be a pure function of the app's rows — the same index, over two builds passed the same rows, gives the same key. **`follow_end`** rides the newest row: the view is on it at the start and stays on it as messages arrive, lets go the moment the reader scrolls up — a wheel notch is enough — and takes it up again when they come back to the bottom, which `on_at` reports as `at_end` so an app can show a "↓ Newest" and take it away again. Revealing the **last** row (the `reveal_key` command) is "to the end, and follow", and stays that even if a message arrives before it lands. **Keeping the reader's place** covers both ways content moves under them: rows arriving above (a page of older messages) and a row **growing after it was measured** — a picture decoding out of its placeholder, a link preview's image landing, a reaction appearing under a bubble — are both put back by the anchor, so what they are reading stays under the same pixel. **`gutter`** keeps every row clear of the overlay scrollbar. **`list_node(ui)`**, asked between `list` and its `end`, is the list's own node — what `scroll_by`, `scroll_to` and `scroll_offset` take, for a view that scrolls its own list a screenful on Space or a few lines on an arrow; NODE_NONE outside a list, so read it in the build that uses it. **`content_width`** makes it scroll sideways as well: the rows are laid out that wide rather than squeezed into the list's width — a document viewer zoomed past "fit width" draws each page as a row — and the list pans across them, the vertical bar staying at the viewport's right edge and a bar appearing along the bottom. Pass the width the app knows, not the widest row: in a virtualised list only the built rows are measured. A row naturally wider keeps its width and the others are widened to match. **`height_of`** is for a list that *knows* its rows' heights — a document's pages at the current zoom, a table of rows of two kinds: nothing is estimated and nothing is measured, each row is **made** exactly that tall, and the offsets are exact on the first build, so a reveal or a hold lands at once instead of sliding about as the rows are measured. It is asked like `key_of` — only during the build, for an index of that build's `count`, with the same `key_user`. A zoom needs nothing said: the rows on screen answering different heights is how the list notices, as new `key_of` answers or a new `estimated_height` are on the measured path, and either way the offsets are worked out again in that same build rather than left describing the old scale. **The `hold` command** is what a zoom actually wants to say: keep *this* point of that row (px into it) at *this* spot in the viewport (px into it). It is returned from `update` in the same breath as the zoom, and nothing happens until it is — an app names the row it is tracking on every build, so naming cannot be the ask. `reveal_key` and `reveal_index` are the same shape for "bring this row into view". **`hold_at`** is the same ask with no row named — "keep whatever is at *this* spot of the viewport where it is" — and it is the one to reach for whenever the app would otherwise describe a position it only knows from its last build: a list does not rebuild for a scroll that keeps the same rows on screen, so dragging the bar within one tall page moves the view without the app hearing, and a zoom straight after holds from an offset that is behind. The list reads its own offset, which never is; what it keeps is a *fraction* of the row, so there is no scale for the app to apply. Either form takes **`axes`** (`{.X, .Y}` by default): a document zoomed by page height passes `{.Y}` and the sideways scroll the reader chose is left exactly where it was. **Several asks at once are several asks** — a reveal for the page list and another for the thumbnails in one `update` both land — and each may name the window it is for (`surface`, a surface tag; the default is whichever window has the view, which is what a one-window app wants). Keys are the app's own: the lists the toolkit builds inside `table`, `icon_view` and the emoji picker cannot take an app's ask whatever number either of them chose. **And a row only the view knows can be asked for from inside the view** — `reveal_now(ui, view, row, at)`, `reveal_now_index`, `hold_now`, `hold_now_at`, the same arguments as the commands without the `$Msg`, for a book whose chapter is a row that typesetting names rather than `update`: before the list it lands in that build's layout, after the list in the next one, and the view is asked to run again so "after" is not "whenever something else happens". `hold`'s `point.x` is px into the **row**, and with `content_width` a row is that whole width, so something centred in it is at `(content_width - its own width) / 2` from the content's left edge, not from inside the list's padding — which is arithmetic `hold_at` and `axes` spare an app that only means to hold the vertical. The page under the pointer, or the middle of the view, then comes out of a zoom where it went in — which a reveal's "a third of the way down" cannot express — and it is applied in the build that changed the scale, before the range is chosen, so no frame is ever built from the old offsets | List, name = label |
| `box(ui, width, height, flex, bg, radius, tag, key)` | leaf rectangle: divider, swatch, placeholder; `tag` as on `column` |
| `lines(ui, runs: []Polyline, thickness, color, dashes: []f32, dash_offset, outline, crisp, width, height, offset, label, key)` | polylines drawn over whatever is behind them, in a `stack` with an `offset` — the overlays an image editor needs and no box can be: marching ants round a selection, a free transform box rotated with its layer, a crop frame and its thirds, guides, the pixel grid, a lasso as it is drawn. Each `Polyline` is `{points, closed}`, and several share the node's style and dash phase, so a selection with holes marches round every loop together. `thickness` is logical px, so a 1 px line stays 1 px at any zoom; `dashes` alternates on and off lengths, repeating (an odd count repeats with them swapped, as SVG's does), and `dash_offset` slides the pattern forward along the path — raise it over time and the ants march. `outline` is the second colour: with dashes it fills the gaps, so black and white alternate rather than compositing one over the other; without them it is a halo two pixels wider, underneath. `crisp` (the default) lands horizontal and vertical lines on whole device pixels, so a guide or a grid is one hard line; lines at an angle have no grid and are never moved. Points are in the node's own coordinates, and it is as big as them unless given `width` and `height` | none: no role, focus, pointer or hover — it is decoration, and an editor hit-tests the geometry it already has. With `label` it is an Image named that |
| `square_corners(ui, n, corners)` | keeps `corners` (`Corners{.Top_Left, .Top_Right, .Bottom_Right, .Bottom_Left}`) of `n`'s `radius` square and rounds the rest. Its fill, border, shadow, glass, picture and focus ring take the shape: a bar's content following a bar at an edge, or a tab joined to its panel. Kept until changed; `{}` rounds all four again. A bar's own surface is shaped by `Surface_Desc.radius` and `square`: a transparent glass `.Layer` whose tint and highlight take the shape and which is clear outside (the blur follows it), taking no pointer at its clear corners with `input = .All`; both are live |
| `card(ui, gap, padding, align, width, height, flex, elevation, glass, offset, key)` | raised surface: bg, radius lg, hairline border, drop shadow; `glass = true` uses the theme's popover material |
| `clickable(ui, node, on_click: Maybe(Msg), label, on_context: Maybe(Msg), on_scroll: Handler(Msg, Scroll), focus_on_click, tag)` | makes a container (a card, a column) one control that takes a click as a whole: a click on it, or Enter / Space while it has focus, sends `on_click`, a right-click or the Menu key `on_context` (a pinned tile's Unpin), while the controls inside keep their own clicks (a notification card's default action beside its buttons); one Tab stop, the hover and press a list row shows; nil makes it plain again; `focus_on_click = false` lets a click act without taking the keyboard (Tab still reaches it, Enter or Space still press it once it has focus) — a tools column, a toolbar's zoom buttons, a player's transport, so that picking a tool and then holding Space pans at once and a field being typed in keeps the keys; `on_scroll` takes the wheel as a button's does, the part of a step left over kept between scrolls — for a control too small to be a button that still steps with the wheel (a workspace switcher's 18 px cells) | Button, name = label |
| `context_area(ui, node, on_context: Maybe(Msg))` | gives a container (a bar, a panel's background) a menu of its own without making it a control: a right-click on it, or on anything inside it without a menu of its own, sends `on_context`, as does the Menu key on a focused control inside it without one; open the menu with `context_menu`; nil removes it | none of its own: no focus, role, hover or press; from the keyboard its menu is the Menu key on a control inside it |
| `set_inert(&ui.tree, node, inert)` | its subtree draws as usual but takes no part in interaction, as HTML's `inert`: the pointer passes through to the nearest ancestor that isn't inert (hover, press, click, right-click, the wheel, tooltips), Tab skips its controls, focus inside moves to the nearest focusable ancestor; stays until changed, so pass it every build (a shell's edit mode picking applets up whole); another program's applet in an `applet_slot` inside still takes the pointer (the applet protocol can't pass it on) | its subtree leaves the accessibility tree (the ancestor that takes the pointer carries the name) |
| `pointer_track(ui, node, on_hover: Handler(Msg,Pointer_At), buttons)` | reports where the pointer is over a node, `pos` from its top-left with its `size`: at most once a frame while the pointer moves over it or anything in it, then once with `inside` false on leaving it or the surface or the node going away; a button pressed over it holds it, reporting outside it and through a drag until the release (`held`); it hears where the pointer is however it got there — a move, or the pointer arriving on the surface without one (given back when a modal overview closes, or a surface appearing under it), so a dock that fell flat when the pointer was taken grows back under it and the next click lands where it did — unlike `hoverable`, which waits for a move; a report it already made isn't repeated (a dock magnifying its icons); while held, `press` is where the press was over it — reports come once a frame, so the press and the first moves can arrive as one report already moved, and a drag going by `pos - press` loses none of its start | none: it adds no role or focus **`Pointer_At.buttons` says which buttons are holding it** (empty when none; `held` is `buttons != {}`), so a node that both tracks the pointer and carries a `context_area` can tell a right-click from the start of a drag — a reader's page was clearing its selection and following links on a right-click whose menu never came, because a popover had swallowed the press before the context handler saw it. `buttons` on the call is which buttons may hold it at all: `{}` (the default) is any, `{.Left}` makes a right or middle press neither hold it nor report, so the page needs no flag of its own. Several buttons may hold it at once, and the first one down is the `press` a drag measures from |
| `key_hold(ui, node, keys: []Key, on_change: Handler(Msg,Key_Hold))` | a node hears chosen keys going down and coming up — an editor's temporary tools, Space held for the hand, Alt to sample, Shift for a straight line: down once however long it is held, up when let go (wherever the focus went meanwhile, and when the window loses the keyboard); only while the focus is inside the node (or nowhere) and only a key the focused control did not use (a text field keeps its Space); either side of a modifier matches the other | none: the keys stay the focused control's first |
| `pointer_samples(ui, node, on_samples: Handler(Msg,Pointer_Samples), hover)` | a canvas hears every pointer and pen sample, not one a frame: all of them while a press that began on it is held (outside it too, through to the release), and with `hover` while over it with nothing held; one message a frame carries them oldest first, each a `Pointer_Sample` — `kind` (Move, Press, Release, Enter / Leave for a pen coming near and going away), `pos` sub-pixel from the node's corner, `time_ms` the event's own time, the `button` and `buttons` held, `mods`, and for a pen `tool` (Pen, Eraser, Brush…), `pressure` 0..1, `tilt` in degrees, `rotation`, `distance`, `contact`, and `clicks` on a press (1, 2 for a double click, 3 for a triple: the same button soon after the last and near it); the slice is valid while the message is handled; a pen's tip also presses and drags as the left button everywhere else, its barrel buttons as right and middle | none: it adds no role or focus |
| `focus_track(ui, node, on_focus: Handler(Msg,Focus_At))` | reports when the keyboard arrives on a node or leaves it, as `pointer_track` does for the pointer: a `Focus_At{has, by_key}`, once per move, from `ui_after_events` — the node losing it hears first, then the node taking it, both with the same `by_key`. `by_key` is true when the move showed a focus ring (Tab, Shift+Tab, an arrow walking a group) and false for a click, which is how a form tells "the keyboard reached this field, open its editor" from "the person clicked it", which says so by being a click. **Tab moves the ring before any widget sees the key**, so a field holding a draft the app must do something with — a `text_input` laid over a PDF form field, whose words have to reach the document — had no way to hear it had lost the keyboard; it hears `has = false` now. Nothing is reported when the *window* loses the keyboard (focus stays and comes back; that is `App.on_state`'s to tell), nor for a node destroyed while it had it. A modifier rather than a parameter on every builder, because hearing this is rare and it then works on anything: a field, an editor, a `clickable` row, a button. **Give each tracked node its own tag**, or read `Ev.node`: since a move between two tracked nodes is reported as the first losing it and then the second taking it, two sharing a tag read as one node losing the keyboard and getting it back — a form whose field row and the editor over it shared a tag closed the editor as it opened | none: it adds no role, focus or ring of its own |
| `pointer_area(ui, node, on_scroll: Handler(Msg,Scroll), on_double_click: Maybe(Msg), cursor: Cursor, cursor_image: ^Image, hotspot: [2]int)` | a plain node (a viewer's picture) takes the pointer as a picture is handled without becoming a control: `on_scroll` is the wheel or touchpad over it with `Scroll.pos` where the pointer is over it (a zoom about the pointer; a scroll view around it no longer takes the wheel there), `on_double_click` two presses close in time and place (or a double-tap: fit ↔ 100 %), `cursor` the pointer's shape over it — and, while a press that began on it is held, anywhere (`.Grab` over a picture that pans, `.Grabbing` while it does, `.Hidden` in a slideshow once the pointer is still), or `cursor_image`, a picture the app drew (a brush's outline) in the screen's pixels with `hotspot` its point, sent again when the picture changes and taken by a pen too (Wayland; elsewhere a crosshair); a control inside it keeps its own presses, wheel and shape; call it every build, all nil and `.Default` removes it; with `pointer_track` it is a draggable picture | none: no role, focus, hover or press — what it does needs a key or a button as well |
| `hoverable(ui, node, on_hover: Handler(Msg,bool))` | the node reports the pointer resting on it: true once when it comes over it or anything inside, false once when it leaves it or the surface, or the node goes away (a toast that waits while it is looked at, a launcher row made current); only the pointer moving counts, so content moving under a still pointer sends nothing; nil stops it | none of its own |
| `zoomable(ui, node, on_zoom: Handler(Msg,f32))` | the node reports Ctrl + wheel over it, the value the wheel's travel in logical px, positive to zoom in (one notch is 48); tables and icon views take `on_zoom` in their own builders, and Ctrl++ / Ctrl+- are the app's `shortcut`s | none of its own |
| `set_active_item(&ui.tree, node, item)` | names `item` as the one a field's keys act on while focus stays in the field (a launcher's search field walking its results); `NODE_NONE` clears it | the field's active descendant in the accessibility tree |
| `component(ui, "key", rev) -> bool` | skips rebuilding its subtree while `rev` is unchanged; close with `end` only when it returns true |
| `breadcrumbs(ui, parts, on_change: Handler(Msg,int), label, flex, key)` | a trail — Home › Pictures › Wallpaper: every part but the last is a link sending its index; when the trail does not fit its width the leading parts fold into a "…" link to the nearest folded one, keeping as many nearest parts readable as fit (the parent and the current place always); at phone width a trail of more than three parts keeps only those two; in a row give it `flex` so it knows its room | Group named `label` (default "Location") of Buttons; the current part is Text with Selected |
| `tab_panel(ui, active, key, flex, gap, padding, scroll) -> bool` | opens only when active; otherwise its node is parked hidden so its state survives; `scroll = true` makes the panel a vertical scroll region for pages taller than the window (offset kept across switches) |

**Locale.** The desktop's locale is read once at start — libc on Linux,
the regional settings on Windows (`GetLocaleInfoEx`), and the system
locale on a backend that has yet to land — into
`ui.locale`: month and weekday names, the first day of the week, the
short date order (`%d/%m/%Y`, `%m/%d/%Y`, `%Y-%m-%d`…), the clock style
and the decimal mark. Every widget that writes a date, a time or a number
consults it — the calendar's names, week start and day labels, the date
field's text, the time picker's 12 / 24-hour form, the number field's
decimal mark (which also reads a point or a comma) — and `date_text` /
`date_short` format for the app. Windows writes its short date as
"dd/MM/yyyy" and Linux as strftime, so the backend translates: `date_format`
is always strftime, and always one of the tokens this toolkit renders.
`set_locale(ui, l)` overrides it for an
app that carries its own, and `LOCALE_EN` is the fallback. Locale is part
of "done" for a widget the way accessibility is.

**Text in every script.** Baldr's own fonts are Inter and an emoji font.
Any character they have no glyph for is drawn from a font installed on the
machine, with nothing for the app to do: a Japanese file name, a Hebrew
song title, an Arabic notification. The faces are found from what the font
scan reads (each face's OS/2 Unicode ranges): a script's own sans face
first (Noto's where there is one), the desktop language's Han shapes for
CJK, regular weight and width. They are loaded once, the first time
they're needed. Only the text that needs one is shaped with it, and its
line keeps the height and baseline of the fonts asked for, so a row with a
Japanese name lines up with its neighbours. Fonts are read from the XDG
data directories, Windows' and macOS's font folders. Known gap: CID-keyed
CFF faces (Noto Sans CJK, Source Han) are passed over, as the shaper
cannot yet draw most of their glyphs, so Korean has no face on a machine
whose only Hangul font is one of those.

**Responsive.** Most of it is automatic, so an ordinary view already
works at phone width: a row that does not fit takes the deficit from what
can give (a text with an `ellipsis` trims, a wrapping text keeps its
longest word, a button keeps its label and padding, a `min_width` holds;
a plain `width` or an empty box squeezes) and, when even those floors overflow, lets the row overflow into
its clipping ancestor rather than break a word or a label; button labels
never wrap; a text cut with "…" shows the whole of it as a tooltip when
the pointer rests on it; a wrapped text taller than its box keeps the
lines that fit and ends with "…"; list rows are clipped to their pitch; tab
bars scroll and keep the current tab in view; `tab_panel(scroll = true)`
pages scroll. Then three switches cover the rest: `size_class(ui)` is
`.Compact` (< 600 px), `.Medium` (< 840) or `.Expanded` — branch on it for
navigation shape; `split(collapse = .Compact)` shows one pane at a time
with a Back button, as the gallery's Explorer page does;
`row(vertical = size_class(ui) == .Compact)`
stacks a header, a form row or an action row; `wrap` flows chips, tags and
toolbars onto new lines. The view is re-run when the window crosses a class
boundary. `viewport(ui)` gives the logical size, and a view that asks for it
is re-run on every resize, so what it worked out from it stays true;
`device_scale(ui)` gives the screen's pixels per logical pixel (2 on a 2×
screen), and a move to a screen of another scale re-runs the view.

**A picture that changes in part.** `image_touch(img, x, y, w, h)` says
those pixels changed: only they are uploaded again, and only the mip levels
over them rebuilt — a brush dab on a 4K canvas costs its few thousand pixels.
Touches add up until the picture is next drawn; a touched picture has a
texture of its own. Bumping `version` still says all of it changed.

**Shown on hover.** `reveal_within(ui, n, owner, shown)` shows node `n`
only while the pointer is over `owner` (or `n`) or focus is inside `owner`
— or while `shown` says so, for the item the keyboard is on. It fades in
over the theme's fast duration, and while it is not shown it is neither
drawn nor hit, so a click on its place lands on what it belongs to. Hover
does not rebuild the view: this is decided as the tree paints. A picture
tile's action uses it; so can a tab's close or a row's actions. What it
holds must be reachable from the keyboard too, which focus reveals.

**Touch.** Nothing to write: a tap is a click, a pan scrolls the nearest
container along its direction and flings on release, a sideways drag on a
slider drags it. With a touchscreen present every interactive node is at
least 44 px tall. Keep hover-only affordances paired with a focus or
description equivalent (tooltips already are).

**Overflow.** A row that runs out of width shrinks its children in
proportion to their natural width; `flex` children keep their `min_width`.
A column that runs out of height overflows: put the content in a `scroll`
or a `list`.

**Identity.** An unkeyed node is reused across builds only by the same
builder call site; a view that switches shape (a breakpoint branch) gets
fresh nodes for the new branch, and the calls after the branch find their
own nodes again (up to 32 siblings ahead), so a spinner turning into a
picture keeps the focus and state of what follows. Use `key` when the same
item must keep its state across branches.

**Stretch, one rule.** `align = .Stretch` makes children as large as the
container on the cross axis. The container is as large as its parent dictates
when its constraint is tight (the root, anything with a `width`/`height`, a
`flex` child, a child of a Stretch parent); when the constraint is loose it is
as large as its largest child and the others are stretched to match (a row of
cards ends up as tall as the tallest; a popover as wide as its widest row).
Children with an explicit `width`/`height` on that axis keep it. To make a
loose column fill a row, give it `flex = 1`.

```odin
first, last := baldr.list(ui, len(s.rows), row_height = 56, gap = .sm, label = "Inbox"); {
	defer baldr.end(ui)
	for i in first ..< last {
		baldr.card(ui, height = 56, key = u64(i + 1)); { defer baldr.end(ui); baldr.text(ui, s.rows[i].title) }
	}
}
```

## Images

| Builder | Notes | A11y |
|---|---|---|
| `image(ui, img: ^Image, width, height, radius, label, fit, source, pixelated, pixel_grid, key)` | an app-owned `Image` (RGBA8) drawn into the box (give one dimension to keep the aspect; with both, `fit` `.Cover` crops centrally, `.Contain` letterboxes, `.Stretch` distorts), rounded by `radius`; `source` is the part of the picture shown, in its own pixels (`{}`: all), clamped to it — `fit` and a missing side follow its aspect, and changing it every frame (a viewer's pan, a zoom animation) is a repaint, never an upload, so a zoomed photo is one window-sized node; always drawn from its own pixels: uploaded once per `version`, into the picture atlas, or — bigger than a page (1022 px an edge) or drawn at under half its size — into a texture of its own up to the device's limit (16384 on most), whose mip levels keep it smooth drawn smaller (a pixel's footprint averaged: less shimmer than a CPU area average, nearly its detail); at 100 % (a `source` the box's size × `device_scale`, from whole pixels) the screen shows exactly the file's pixels; pictures may come and go freely (named by an identity, not an address; the ones not drawn lately make way, textures of their own past 192 MB, oldest first); once its node leaves (a dialog fading out) it never reads the Image again, so the app may free it as soon as the view stops showing it; the fade draws the copy already uploaded; **"the view stops showing it" is the test** — a picture still reachable from wherever the view reads its pictures is handed straight back on the next build, and an Image whose fields no longer add up is then drawn as nothing and reported against the line that handed it over; where the view is not built at all — a skipped `component` — call `image_forget(ui, img)` before freeing, which lets every node showing it go at once; **magnified it goes crisp on its own** — smooth up to 2 device pixels a picture pixel, hard-edged squares from 4, crossfaded between, so a viewer's zoom sharpens rather than popping at a threshold each app picks for itself (`pixelated = true` / `false` forces either, however far in); `pixel_grid` draws a 1-pixel line between the pixels, fading in from 8 device pixels each and fully there from 24, for a viewer or an editor that far in. **Animations**: `image_from_rgba_frames(w, h, frames, delays_ms, max_side)` makes one from N RGBA frames the app decoded itself (a format Baldr does not read, or frames generated in memory); `image_load` already returns GIF and WebP animations this way. The toolkit runs it while it is on screen and stops the moment it is not — no message to the app and no view rebuilt per frame. The frames are stacked into one picture, so a frame is a different source rectangle of a texture uploaded once, which is why an off-screen one costs nothing. Its natural size is one frame; a rebuild does not restart it; under reduce-motion frame 0 stands. The frames go into **one texture as a square-ish grid**, not one tall column, because a column overflows the GPU: 480×270 × 70 frames stacked is 18,900 px tall, past the 16,384 most cards allow and far past the 4,096 Vulkan promises, and a texture past the limit falls back to the atlas, which downscales anything over a page to a smudge. `max_side` caps each side and defaults to `IMAGE_GRID_MAX_SIDE` (4,096, the figure every conformant device allows): that holds 120 frames of 480×270. If they will not all fit, **every k-th frame is kept and the dropped delays are added to the one before**, so the animation still runs to time — smoothness lost rather than sharpness — and `img.frames` against `len(frames)` says whether that happened. An app that knows its device can pass `gpu_limits(g).max_side` and keep the lot. **Size a bubble with `image_frame_size(img)`**, not from `width`/`height`, which are the whole grid — `height / frames` was right for the old single column and now gives 35 px for 100 frames of 480×270 instead of 270. `image_frame_rows(img)` and `image_frame_rect(img, i)` go with it; passing a frame's rect as `source` draws that one frame and stops the toolkit animating it, which is how to show a still poster for a GIF that only plays on hover. | decorative unless `label` (then Image, named) |

`image_load(bytes)` decodes a PNG, JPEG, GIF, WebP, BMP, ICO, QOI, TGA,
netpbm or SVG file, telling which from the bytes, in Odin (any channels,
8- or 16-bit → RGBA8; an animated GIF or WebP as an animation that plays
by itself; a JPEG turned upright by its EXIF orientation; an icon file's
largest picture; an SVG at its own size; malformed or truncated bytes give
false); `image_from_rgba(w, h, pixels)` wraps
generated pixels; `image_destroy`. `button(…, image = &img)` puts a 20 px
picture before the label (`icon_only = true` for a square avatar button).
`image_load_xpm(bytes)` decodes XPM 3, and `image_from_argb32_be(w, h,
bytes)` converts a StatusNotifierItem's ARGB32 pixmap.

`svg_render(svg_bytes, w, h, colors)` draws an SVG document into an `Image`
at a pixel size, on any thread: shapes and paths, `use` and `symbol`,
transforms, fills and strokes (joins, caps, dashes), gradients, patterns,
clip paths, masks, group opacity, embedded PNG and JPEG, text in Baldr's
typefaces and the filter primitives icons use, styled by attributes,
`style` and `<style>` sheets. With `Svg_Colors` an icon takes given colours:
`currentColor`, KDE's `ColorScheme-*` classes, and GTK's rule for symbolic
icons. `svg_size(svg_bytes)` is a document's own size. Over the installed
Adwaita, hicolor, HighContrast and a sample of Papirus icons, 98% match
librsvg within half a level per channel, at a third of a millisecond for a
48 px icon.

**Paths into pixels.** A `Path` is moves, lines and curves in pixels
(`path_move`, `path_line`, `path_quad`, `path_cubic`, `path_arc`,
`path_close`, `path_rect`, `path_ellipse`, `path_svg`). `path_fill` and
`path_stroke` turn it into coverage in a `Mask`, an 8-bit buffer
(`mask_make(origin, size)`) placed anywhere in the path's space, so a
lasso on a 12000 px document fills a mask of just the part it covers.
Fills take a `Fill_Rule` and an `antialias` flag (off: a pixel is in by its
centre); strokes take a width, `Line_Join`, `Line_Cap`, a miter limit and
dashes. A `Mask_Op` says how the shape goes into what the mask holds:
Add, Subtract, Intersect or Replace, an editor's selection modes.
`image_paint(img, &mask, color)` lays a colour into a picture through a
mask and touches what it changed. It is the rasteriser `svg_render` uses,
safe on any thread.

**Text into a picture.** `typeset(tree, text, Typeset_Style{family, size,
weight, italic, align, justify, tracking, line_height, wrap_width})` sets
text at a picture's size in any installed family (`installed_fonts`, and
`font_faces` for a family's weights). The result gives the box, the ink and
the lines. It also gives what an in-place editor needs: `typeset_caret`,
`typeset_hit`, `typeset_rects` for a selection (or one character's place)
and `typeset_line_of`. `typeset_draw` fills the glyphs into an `Image` with
exact coverage (colour emoji in their colours) and touches what it drew;
`typeset_mask` puts the coverage into a `Mask`. Lines wrap at UAX #14
opportunities, and tracking counts in the wrap. Spaces hang at a wrap.
Justified lines reach both edges (a paragraph's last line keeps `align`),
and right-to-left text reads from the right. Call `typeset` on the tree's
thread.

**A picture inside a line.** `Typeset_Style.objects` is a list of
`Typeset_Object{at, size, baseline, label}` — a box at a U+FFFC in the
text. Typesetting only keeps the room: the box takes its width on the
line, the line grows if the box is taller than the words, it wraps with
the words around it, and where each one landed comes back in
`Typeset.objects` (`index`, `at`, `line`, `rect`, `label`) for the **app**
to draw its own picture there. A U+FFFC with no object of its own takes no
room and draws nothing. `label` is what a screen reader hears in its
place, through `typeset_view`'s accessible text — without it a name set as
a picture would go missing from the sentence. `examples/33_reading` sets
one in its page.

**Canvases.** Textures the app draws into on the GPU. Get the app's `Gpu`
with the `gpu_open` command. `canvas_create(g, size, format, space)` makes
an `.RGBA8`, `.RGBA16` or `.RGBA32F` canvas in `.sRGB`, `.Display_P3`,
`.Adobe_RGB` or `.Linear`. `canvas_write`, `canvas_fill` and `canvas_copy`
queue work that runs before any frame shows it, and `canvas_read` is a
command whose texels come back as a `Canvas_Read` message. Where the pixels
are made or fetched a frame at a time — video, a camera — `canvas_write_begin
(g, c, x, y, w, h)` hands back the bytes the write will be made from and
`canvas_write_end(g, c)` finishes it, so the frame is copied once instead of
twice; the slice is the toolkit's and is good only until the end.
`canvas_blend(g, src, x, y, w, h, dst, to, mode, opacity, mask, linear)`
composites one canvas onto another in any of Photoshop's 27 blend modes
(`Blend_Mode`), through an optional mask, on stored values or in linear
light. Filters and adjustments read a rectangle and write it into a canvas,
which may be the same one: `canvas_matrix`, `canvas_curves`,
`canvas_convert` (between colour spaces), `canvas_lut` (an app's 3D LUT),
`canvas_blur` and `canvas_sharpen`. Painting: `brush_stroke` spaces a `Brush`'s dabs along the pointer's
path, `canvas_dabs` lays their coverage into a stroke canvas, and
`canvas_paint` lays the colour through it onto a layer (or erases).

**A GPU buffer another process made.** On Linux a canvas can be a buffer
somebody else allocated — a video helper decoding in hardware and drawing
each frame into a ring it shares as dmabufs — so a frame costs a fence and a
draw instead of two copies of the whole picture. In order: `gpu_card(g)` says
which card Baldr draws on (`/dev/dri/renderD128`), so the producer uses the
same one; `canvas_import_modifiers(g, fourcc, out)` says what layouts can be
imported, which the producer must know *before* it allocates;
`canvas_import_dmabuf(g, buf)` imports each buffer of the ring once; then per
frame `canvas_acquire_fence(g, c, fd)` with the sync_file the producer's
drawing signals, and `canvas_import_idle(g, c)` before telling it a buffer is
free again. The four single-plane 8-bit formats are taken
(`DRM_FORMAT_XBGR8888` and its three relatives). An imported canvas is
**drawn and never written**: `canvas_write`, the fills, blends, filters and
brushes all refuse it, since the memory is the producer's. A GPU reset takes
it as it takes every canvas, and the app imports again. Off Linux, and on a
device without the extensions, every call refuses and says why once — the
app's answer is `canvas_write_begin`. `spikes/dmabuf_import` is a producer
and a consumer in one program.

**An app's own shaders.** For an effect Baldr has no operation for:
`shader_create(g, stage, Shader_Code{spirv = #load("x.spv", []u32)},
inputs, backdrop)`, then `canvas_shader(g, s, dst, x, y, w, h, inputs,
uniforms)`, queued with the rest of the canvas work. The contract:

```glsl
// Fragment: drawn over the rectangle; gl_FragCoord.xy is the destination texel.
layout(set = 0, binding = 0) uniform sampler2D input0;   // inputs: sets 0..n-1
layout(set = 1, binding = 0) uniform sampler2D backdrop; // with backdrop = true: set n, at texel - area.xy
layout(push_constant) uniform P { ivec4 area; /* your uniforms, up to 112 bytes */ } pc;
layout(location = 0) out vec4 texel;                     // the stored values, straight alpha

// Compute: dispatched over the rectangle in its local size.
layout(local_size_x = 8, local_size_y = 8) in;
layout(set = 0, binding = 0, rgba8) uniform writeonly image2D dst; // rgba8 | rgba16 | rgba32f: the canvas's format
layout(set = 1, binding = 0) uniform sampler2D input0;             // inputs: sets 1..n
layout(push_constant) uniform P { ivec4 area; /* your uniforms */ } pc;
```
`canvas(ui, g, c, width, height, radius, label, fit, source, pixelated,
pixel_grid)` shows one as `image` shows a picture — including going crisp on
its own where magnified, and `pixel_grid` — decoded from its colour space for
the screen; `label` makes it an Image named for assistive technology. Without a
GPU the same calls run on the CPU reference (`gpu_reference`), whose
canvases are drawn as pictures.

## Icons

| Builder | Notes | A11y |
|---|---|---|
| `icon(ui, which: Icon, size, color, label, key)` | one of the vendored Lucide icons (`Icon` enum, `ICON_NAMES`), drawn from its SVG path at any size and cached in the atlas per device size; text colour by default | decorative unless `label` is given (then Image, named) |
| `theme_icon(ui, name, size, color, label, fallback, key)` | an icon from the desktop's icon theme by name (a .desktop Icon=, a tray IconName, an absolute path), loaded off the UI thread and drawn when ready (its space is kept, and until a size loads the nearest size of it already loaded draws there scaled — a larger one first — as does its picture from before the icon theme changed, so a dock growing its icons or a Light/Dark switch never blinks one out; only its first appearance draws nothing; a name nothing provides draws `fallback`, a Lucide icon, or with none the theme's application-x-executable, else Lucide's app window); a symbolic or recolourable icon takes `color` (the text colour by default) and follows it, a full-colour one keeps its colours and fades with `color`'s alpha; `theme_icon_dir(ui, n, dir)` adds a tray item's IconThemePath | decorative unless `label` is given (then Image, named) |

`button(…, icon = .Save)` puts an icon before the label; `icon_only = true`
makes a square icon button whose `label` is still its accessible name.
`menu_item(…, icon = .Pencil)` and `cell_text(…, icon = .Folder)` do the
same. Add icons by name to `tools/icon_gen/icons.txt` and run
`odin run tools/icon_gen -- third_party/lucide/sprite.svg tools/icon_gen/icons.txt baldr/icons_data.odin`.
The path engine (`svg_flatten`, `svg_raster`) handles M/L/H/V/C/S/Q/T/A/Z,
round-capped strokes and non-zero fills, so app-specific icons can use it too.

`icon_theme_lookup(&themes, name, size, scale, extra)` finds a freedesktop
icon's file: the theme `icon_themes_use` names (the desktop's is
`icon_theme_default()` when no portal says), what it inherits, hicolor,
then the pixmaps directories, falling back to dash-shortened names and the
-symbolic swap. GTK's icon-theme.cache answers when fresh; otherwise
directories are listed once. Changes show within `ICON_THEME_RECHECK_MS`.
An `Icon_Themes` (`icon_themes_init`, `icon_themes_destroy`) belongs to one
thread.

## Icon view

| Builder | Behaviour | A11y |
|---|---|---|
| `icon_view(ui, count, selection, on_select, on_click, on_activate, on_context, drag, on_drop, accepts, drag_files, drag_user, drag_files_out, on_drag_out, on_range, on_zoom, on_edit, label_of, label_user, animate, place_of, place_user, on_place, tile, gap, padding, flex, height, label) -> (first, last)` | a grid of tiles in as many columns as fit, virtualised by row; build `first ..< last` with `icon_item`; click / Ctrl / Shift select, a rubber band dragged over empty space selects what it touches (Ctrl adds), arrows move the cursor across the grid (Shift extends), Space, Ctrl+A, Home/End, Page Up/Down by a viewport of rows; `on_select` carries the cursor, Enter or double-click sends `on_activate`; a plain primary click on a row — no Ctrl or Shift, and not the second click of a double — also sends `on_click`, which is the one thing `on_select` cannot say: that fires for every change of selection, every arrow key included, so "one click opens this row" built on it opens one per key press; shares `Selection` with table; `on_range` hears the tile indices built when they change; `label_of` turns on type-ahead, and the `reveal_index` command scrolls a tile into view, as on `table`; `label_over = .Anything` says the labels are drawn over something the app does not control (a wallpaper, a photograph): every glyph and icon then wears a halo in the opposite tone, dense enough to outline it, because nothing else carries a label over sky and hedge alike; `animate` glides tiles to their new places when the columns change (a zoom, a pane or window resize; not the first show; a tile still gliding re-targets from where it is drawn; instant under reduce motion); **placed mode** — with `place_of` (item → `{column, row}`, `{-1, -1}`: the first free cell, flowing down the columns) each icon stays where it was put, a drag inside the view reports through `on_place` the items moved, a cell each (the selection's shape kept, a taken cell stepped round to the nearest free one) and the raw cell under the pointer; the view keeps no placement itself, the app writes it down and gives it back | List named by `label`; List_Item tiles (Selected) named by their label; in placed mode the arrows move by geometry (the nearest item that way, nothing that way leaves the cursor put), Home/End are the ends of the reading order and the band selects whoever is in the cells it covers |
| `icon_item(ui, index, icon, label, picture: ^Image, on_submit, on_cancel, subtitle, action: Maybe(Msg), action_icon, action_label)` | one tile: the icon — or `picture`, a thumbnail in a square with the Contain fit — over a wrapped label; with `on_submit` a wrapping editor two tiles wide opens over the tile, showing the whole name (see Editing in place); rows open and close by themselves; in an `icon_view(…, variant = .Pictures)` (albums, books) a tile is the picture filling a square with rounded corners, cropped rather than letterboxed (or `icon` on a quiet square when there is none), the label as a title in medium weight and `subtitle` muted under it, a line each ended with "…"; `action` is a round button over the picture's corner (`action_icon`, Play by default; `action_label` names it), shown while the pointer is over the tile or the keyboard is on it, and only the current tile's is a Tab stop, so a grid of hundreds is one Tab from the view to the current album's Play; the default tile is `PICTURE_TILE` (168 × 214) | List_Item |

## File-manager conventions (table and icon view)

Both grids keep the conventions of Finder, Explorer and Nautilus:

- **Background is always reachable.** Gaps between tiles and the space
  after the last row (both views keep a pad there) are background: a press
  starts a rubber band, a right-click asks for the folder menu. Table rows
  are full width (the highlight spans the row) and, as in Thunar, the blank
  part of a cell past its text is where a band can start: a click there
  selects the row, a drag from there rubber-bands rows; a drag from the text
  or icon is the item's (drag-and-drop later). The folder menu on a full
  list comes from the pad after the last row or the Menu key.
- **Rubber band** in both views: drag over empty space; the band selects by
  grid arithmetic (built or not); Ctrl keeps the existing selection.
- **Right-click on an item** selects it first unless it is already part of
  the selection, then `on_context` carries its index; on the background it
  carries -1. The Menu key and Shift+F10 do the same for the keyboard
  cursor. Build the menu with `context_menu`; it opens where the request
  happened and keyboard focus lands on its first item.
- **Type-ahead.** With the view focused, typing selects the first row whose
  label starts with what was typed (case-insensitive): letters within 700 ms
  build the prefix, the same letter again steps to the next row starting
  with it, wrapping, and the match scrolls into view. The labels come from
  `label_of`, since rows off screen have no nodes.
- **Labels** trim with an ellipsis instead of spilling: cells at the end,
  tile labels in the middle after two lines (extensions stay visible).

## Text area

| Builder | Behaviour | A11y |
|---|---|---|
| `styled_text(ui, text, runs: []Run, on_link: Handler(Msg,string), role, size, width, max_width, flex, label, key) -> Node` | one wrapped paragraph of runs the **app** built, for a chat body whose markdown is not CommonMark (`*bold*`, `_italic_`, `~strike~`, `` `code` ``, bare URLs). A `Run` is the editors' own: the byte it ends at, its `Attrs` (Bold, Italic, Underline, Strike, Code, Link, Highlight) and, for a link, its `href`. Text and runs are copied, so the app may rebuild them freely. Laid out by `rich_layout` and painted by `rich_draw_lines`, the same two an editor and a `markdown_view` use, so a link, inline code or a strike looks the same everywhere. Drag to select across the runs (double-click a word, triple-click the paragraph, Shift extends); Ctrl+A selects all and Ctrl+C copies as **plain text** — the styles are how it is drawn, not what it is. A plain click on a link run sends `on_link` its `href` and the app decides what that means; the cursor is a hand over a link and an I-beam over the words. Per-run colour is not supported — the attributes are **`ink` and `on`** colour it for text on a filled surface: an outgoing chat bubble is filled with the accent, so its text must be that fill's "on" colour. `ink` is the body colour and `on` is what it sits on; from the two, muted, the link, the inline-code chip and the selection are **computed to meet a contrast ratio**, not guessed. `on` is asked for because without it they cannot be guaranteed: deriving from the ink alone with fixed alphas reads as though it should work and does not — muted came out at 2.71:1 on Dim and Dark, and in Light the selection took the selected words down to 2.30:1. A link is the **ink**, not the accent, since a blue link on a blue bubble is the bug this fixed; the underline is what tells it apart. The selection shades **away** from the ink (black or white, whichever moves the fill away), so selected text reads better than unselected rather than worse. Neither given, nothing changes: the theme's own colours on a surface. `styled_text_options(ui, n, body, muted, link, code, selection)` overrides any one of them. **A press gives it the keyboard and Tab passes it by**: drag, double click (a word) or triple click (the paragraph), then Ctrl+C copies and Ctrl+A selects all of it, while a chat's dozens of messages put no stops between the list and the composer — a message's own Copy is the keyboard's way to its text. The selection is an opaque band of the accent with the words redrawn on it in `on_primary`, or reverse video on a bubble filled with the accent, so it stands at least 3:1 off the bubble and the words read at 4.5:1 | Text named by its text (a reader hears the sentence, not five runs) |
| `markdown_view(ui, md: ^Markdown_Doc, label, width, max_width, flex, tag, key)` · `md_set(md, text)` · `md_append(md, delta)` · `md_clear(md)` · `md_text(md)` · `md_markdown(md, from, to)` | a reply, rendered and read-only: headings, paragraphs, bullet / numbered / task lists, quotes, code blocks and rules, with `**bold**`, `*italic*`, `` `code` ``, `~~strike~~` and links styled inline. The app owns the `Markdown_Doc` and keeps it alive while the view is built: `md_set` for a stored message, `md_append` as a reply streams (costing the delta, not the reply — only the last block is laid out again, so nothing above the person's place moves), `md_clear` to replace one. A delta may split anywhere: an incomplete UTF-8 sequence is held back until its remaining bytes arrive, an open fence renders as code in progress, and a table becomes a table when its separator row lands. The node sizes itself to its content, for a list of messages. Selecting: drag across blocks, double-click a word, triple-click a block, Shift+click to extend, Ctrl+A for the whole reply, Ctrl+C to copy, Escape to let go. From the keyboard, once the reply has focus: Shift+arrows extend by character or line, Ctrl+Shift+Left/Right by word, Shift+Home/End along the line, Ctrl+Shift+Home/End to the reply's ends — no caret is drawn, and the moving end scrolls itself into view. An arrow with no Shift is not the reply's: it goes on to the window. `md_view_selection(t, n)` is the selected **source** byte range — anchored to the source, so it survives the reply growing under it and a re-layout at another width — `md_view_selected_text(t, n)` is it as clean text (the words as drawn, a list item's marker written out, no markup), and `md_markdown(md, from, to)` over the same range is the markdown behind it, widened to whole runes, for "copy as markdown". Blocks take the spacing their kind deserves (a heading breathes, list items sit close, a fenced run is one rounded block with its lines tight); headings are sized from the reply's own body — 1.5× / 1.3× / 1.15×, bold — rather than the app's chrome roles; numbered items keep their numbers and markers sit on their item's own text, right-aligned in a column their whole list shares (as wide as its widest ordinal, so "9." and "10." end together and neither touches the words). **Tables** are measured across their rows, every column as wide as its widest cell and brought inside the view when they do not fit — each column keeping at least its longest word, the rest shared out in proportion to what each asked for beyond that — with cell text wrapping inside its column and the row as tall as its tallest cell, so a wide table grows downwards instead of running off the side. A bold header row sits over a rule, with a hairline between the rows under it. `<br>`, `<br/>` and `<br />` inside a cell are a line break (the only one GFM gives a cell, and the one piece of HTML honoured — everywhere else in markdown it stays text); a copied cell carries the break as a newline. A hovered link shows its target in a tooltip under the line it is on (a design call: by the pointer, not a status strip at the window's corner), and the pointer says what is under it — the hand on a link, the I-beam over words that can be selected. Every fenced block has a band across its top holding its language ("sql", "odin") and a **Copy code** button of its own — a real button, clear of the code's first line: its own hit target and hover, a place in the focus order, the name "Copy code", and a tick for a moment after it copies (the code exactly as written, fences excluded). Bare addresses link themselves (`https://…`, `www.…`, `<https://…>`, an email to `mailto:`), and a footnote's markup does not leak — `[^1]` reads `[1]` | Text named by `label` (else "Message"), holding the rendered words as its accessible **text** (`org.a11y.atspi.Text`), so a reader reads the answer line by line and word by word, hears the numbers of a numbered list (they are content), never the markup, and follows a streaming reply by what was inserted rather than hearing it again |
| `text_area(ui, doc: ^Document, placeholder, on_change: Handler(Msg,int), on_submit, on_context: Handler(Msg,Editor_Context), label, width, height, flex, disabled, focus, tag, key)` | multiline editing of an app-owned `Document` in place: paragraphs wrap to the width; the box grows between `min_lines` and `max_lines` (0 = unbounded) or scrolls when given a `height`; typing, Enter, Backspace/Delete by grapheme or word across paragraphs, arrows with a goal x across wrapped lines, Home/End per line and Ctrl+Home/End, Page Up/Down, Shift selection, Ctrl+A/C/X/V, Ctrl+Z / Ctrl+Y / Ctrl+Shift+Z undo and redo (typing groups until a pause), click / drag / double-click word / triple-click paragraph, wheel scrolling; `on_change` carries the document version `focus = true` hands it the keyboard when it turns true — opening a chat, pressing Reply — with the **caret at the end and nothing selected**, unlike `text_input`, which selects its value so the first keystroke replaces it: an editor holds a draft you are continuing, and selecting it would mean opening a chat deleted the message you had started. From `update`, where that decision is usually made, `baldr.focus(Msg, key)` does the same by the widget's reconciliation key, waiting a few builds for a field the command itself is about to cause to be built. `code_editor`, `rich_text` and `markdown_editor` take the same `focus`. | Text_Input named by `label` (else the placeholder), the contents as the value, focus ring |
| `code_editor(ui, doc: ^Document, language: ^Language, on_change: Handler(Msg,int), on_context: Handler(Msg,Editor_Context), label, width, height, flex, disabled, focus, tag, key)` | the text area engine in the code face (JetBrains Mono) for source: a line-number gutter (a click on a number selects the line; it is a column of its own, so with wrapping off the text panned sideways is clipped at its edge rather than drawn under the numbers), tab stops (`tab_width` cells), syntax colour from a `Language` (`LANG_ODIN`, `LANG_C`, `LANG_JSON`, `LANG_SQL`, `LANG_PLAIN` ship; an app fills its own — keywords, types, constants, comment and string shapes, an attribute prefix, brackets, `case_insensitive` — or supplies a `tokenize` proc for a grammar the table cannot describe and keeps the rest), the caret line washed, the bracket pair at the caret boxed, `whitespace` shows spaces as dots and tabs as arrows, `wrap` soft-wraps (off by default: it scrolls sideways); Tab indents (the selected lines, else inserts one indent — a tab, or `tab_width` spaces with `spaces`), Shift+Tab outdents, Enter keeps the indentation and opens a bracket pair onto its own line, Home goes to the first non-blank column then the margin, Backspace inside space indentation steps back a stop, Ctrl+/ toggles the language's line comment, Alt+Up / Down move the lines, Ctrl+F opens a find bar (case-insensitive; the matches are highlighted, Enter / Shift+Enter, F3 / Shift+F3 and the arrows step through them, Escape closes and focus returns), Ctrl+H adds a replace row (Enter replaces the current match and moves on, "All" or Ctrl+Enter replaces every match as one undo step), Ctrl+G opens go-to-line, Ctrl+Page Up / Down go to the window's shortcuts (its tabs) and Ctrl+Tab / Ctrl+Shift+Tab to a shortcut bound to them, else they move focus out; typing two identifier characters (or Ctrl+Space) opens a completion list under the caret — the language's words and the identifiers nearby by default, or what the `complete: Completer` proc supplies — Up / Down pick, Enter / Tab accept, Escape closes; a `Mark` with a `message` shows it in a tooltip when the pointer rests on it (diagnostics); everything the text area does otherwise, `editor_options(max_lines = n)` included — with no `height` the editor takes `flex = 1` and fills its pane, and a `max_lines` cap beats that flex rather than being overridden by it; painting is virtual (only the lines in view are shaped and drawn) | Text_Input named `label`, the text as its value, "Line n, column m" as its description; the find bar is a Group "Find" described "n of m" with fields "Find" / "Replace with" and Buttons "Previous match" / "Next match" / "Replace" / "Replace all" / "Close find"; the completion list is a List "Completions" of List_Items, the picked one Selected; the ring is the standard one |
| `rich_text(ui, doc: ^Document, on_change: Handler(Msg,int), label, placeholder, width, height, flex, on_link: Handler(Msg,string), on_context: Handler(Msg,Editor_Context), disabled, focus, tag, key)` | the text area engine with the Document's kinds and runs: headings (three sizes), bullet / numbered / task lists nested by Tab and Shift+Tab, quotes, code blocks (mono, one washed box from their first line to their last), rules, images, tables (cells on shared columns, a tinted header row; Tab / Shift+Tab step between cells and add a row past the last, Enter adds a row, the Table button inserts one), and bold / italic / underline / strike / inline code / highlight (`==text==`, washed like a highlighter pen) / links inside, each run drawn in its face (Inter Italic and Bold Italic are vendored); a toolbar above reflects the selection and applies formatting (or Ctrl+B / I / U, Ctrl+E code, Ctrl+Shift+H highlight, Ctrl+K link — the link bar takes the address, Apply / Remove); typing `# `, `- `, `1. `, `[ ] `, `> ` or ```` ``` ```` at the start of a line converts it; Enter continues a list (an empty item leaves it), Backspace at the start of a styled block makes it a paragraph; a click on a task's box ticks it; Ctrl+click on a link sends `on_link`; a style toggled at a caret pends for the next typing; undo restores formatting and kinds. `document_markdown` / `document_set_markdown` print and parse markdown (headings, lists, tasks, quotes, fences, rules, inline marks, links); `LANG_MARKDOWN` colours markdown source in the code editor, so an app offers rich and source views of one document | Text_Input named `label` with the text as its value; Toolbar "Formatting" of named Buttons with Pressed states; the link bar a Group "Link" with a field "Link address" and Buttons "Apply" / "Remove" / "Close link"; the ring is the standard one |
| `markdown_editor(ui, doc: ^Document, on_change: Handler(Msg,int), label, placeholder, width, height, flex, on_link: Handler(Msg,string), on_context: Handler(Msg,Editor_Context), disabled, focus, tag, key)` | live preview (Typora / Obsidian style): the Document holds markdown source, one line per block; every block shows rendered — headings, lists, tasks, quotes, code, marks applied — except the ones the selection touches, which show their source with the marks dimmed; a click on a rendered word lands the caret at the matching source byte; Enter continues a list, quote or task prefix (an empty item ends it) and adds a table row at a row's end, Tab / Shift+Tab nest items and step between a table's cells, Ctrl+B / I / E wrap or unwrap the selection in `**`, `*`, `` ` ``, Ctrl+Shift+H in `==`, Ctrl+K makes a link with the address selected, a click on a rendered task's box ticks it, Ctrl+click on a link sends `on_link`; a fenced code block, fences included, is one washed box rounded at its outer corners (a closing fence ends it); save the source as it is — it is the markdown | Text_Input named `label` with the source as its value |
| `editor_options(ui, editor, wrap, readonly, min_lines, max_lines, max_length, line_numbers, tab_width, spaces, whitespace, toolbar, frame, ink, on_paste_other, follow_caret, line_limit)` | the settings of any of the three editors, on the node its builder returned; each stays until changed, so pass only what you mean (`wrap` / `readonly` / `invalid` / `required` for all; `min_lines` / `max_lines` bound the height when none is given, `max_length` caps the characters; `line_limit` is how much of one line an editor lays out and draws, 10,000 bytes unless set, 0 for no limit — past it a muted marker says how many more characters there are (a live-markdown editor shows such a line as its source, never rendered), and the document keeps them all: End reaches the real end, typing lands there, copying and find take the whole line (a line of millions of characters, a minified script or an inlined picture, otherwise takes gigabytes to lay out); `line_numbers`, `tab_width`, `spaces`, `whitespace`, `ligatures` for code editors — ligatures are off by default so `->` stays two glyphs; `toolbar` for rich editors); `on_paste_other` hears a paste that brought no text but a picture or files, so a composer can attach a pasted screenshot instead of doing nothing (Ctrl+V and the menu's Paste alike; a paste with text in it is untouched); `ink` is the colour it writes in — a page of the app's own colour (a sticky note's yellow paper) needs its own, or the theme's near-white text lands on it — and the caret, the placeholder and the selection wash follow it | states follow: Readonly, Invalid, Required |
| `editor_caret(t, editor) -> (caret, anchor: Pos, ok: bool)` · `editor_options(…, follow_caret = true)` | where the caret is and where its selection is anchored (equal when nothing is selected), *unswapped* — `editor_selection` is the other reader and gives the same range ordered, for acting on the text rather than drawing from the caret — and an opt-in that builds the app's view again whenever it moves. An app needs both to draw anything that follows the caret — sentence focus's fade, a status line's line and column. Off (the default) a caret move only repaints, which is what every editor that draws nothing from it wants | neither changes what a reader hears |
| `editor_marks(ui, editor, marks: []Mark)` | this build's decorations from a spell checker, a search or a linter. Four kinds draw *around* the words: Error / Warning squiggles, an Info underline, a Highlight wash. Three change how the words are drawn: **Dim** in the theme's muted colour (sentence and paragraph focus — the fade follows the caret), **Tint** in the mark's own `color` (parts of speech), and **Strike** a line through them ("consider cutting this"), where Dim and Tint take the last mark that covers a byte. A `message` shows in a tooltip when the pointer rests on the mark. Marks are **display only**: never in the document, never copied, never exported, and a fresh list every build is the cheap thing to do — a block no recolouring mark touches is drawn as one run, as it always was | the tooltip is a Tooltip named by the message; a mark changes no accessible text, so a reader hears the words whatever colour they are drawn in |
| `editor_select(ui, editor, anchor, caret: Pos)` · `editor_reveal(ui, editor, pos, at: Reveal_At)` · `editor_view(t, editor) -> (top: Pos, ok)` | an app moving any editor: `editor_select` sets the selection (anchor = caret: just the caret), clamped to the Document, the column Up and Down keep reset as a click resets it, and keeps the caret in view; `editor_reveal` scrolls so `pos` shows — `.Nearest` with as little movement as that takes, `.Center` in the middle (a heading from an outline, a match from find), `.Top` on the top line — waiting for the editor's layout, so it works straight after building it or editing its Document (the last call before that layout counts); `editor_view` is the first position on the line at the top of the view, for `editor_reveal(…, .Top)` to put a view back (a file reopened where it was left); `editor_selection` reads the selection | none of their own: the caret moves as the editor's own would, and is announced the same way |
| input methods (all fields and editors) | typing through fcitx5, IBus or another input method (zwp_text_input_v3): the focused field enables one as it takes focus, and tells it what the field is for, the text around the caret with the caret and the anchor in it, and the caret's rectangle, so the candidate window sits by the caret; the composition is drawn at the caret, underlined, with the method's cursor range underlined more strongly, and never reaches the Document or undo; a commit is inserted exactly as typing is; a password, readonly or disabled field takes none. Nothing to call: it follows focus | the composition is drawn, not announced; the accessible value stays the Document's text, so a screen reader hears what was committed |
| `editor_action(ui, editor, action: Editor_Action) -> bool` · `editor_actions(t, editor) -> Editor_Actions` · `on_context` on every editor | an app's menu for any editor: `on_context` is sent on a right-click or the Menu key (Shift+F10) with an `Editor_Context` — the Document position under the pointer (the caret, from the keyboard; in a markdown editor, in the source), `in_selection`, and `at`, where to open the menu (`Ui.context_pos` is set to it, so `context_menu` opens there); a right-click off the selection moves the caret there first, one on a selected character keeps the selection and the view; `editor_action` does `.Cut`, `.Copy`, `.Paste`, `.Select_All`, `.Undo`, `.Redo` exactly as Ctrl+X / C / V / A / Z / Shift+Z do (one path: the same clipboard and undo steps), false when there was nothing to do; `editor_actions` is what can be done now, to grey items: Cut and Copy need a selection, Paste text on the clipboard, Select All some text, Undo / Redo a step; a readonly editor only copies and selects all; a disabled one nothing; an editor without `on_context` leaves right-clicks to a `context_area` around it | the menu is the app's `context_menu` (a Menu of Menu_Items, greyed items Disabled); from the keyboard it opens under the caret's line and starts highlighted |
| `rich_apply(ui, editor, action: Rich_Action)` | one formatting action on a rich or markdown editor — what its toolbar and shortcuts do — for an app's own toolbar or menu: `.Bold`, `.Italic`, `.Underline`, `.Strike`, `.Code`, `.Highlight` and `.Link` act on the selection or the word at the caret; `.H1`–`.H3`, `.Paragraph`, `.Bullet`, `.Numbered`, `.Task`, `.Quote` and `.Code_Block` on the selected lines (asking again clears what is already set); `.Rule`, `.Table` and `.Image` insert; `.Undo` / `.Redo` step the history. Each is one undo step, the selection stays on its text, and focus returns to the text. A rich editor keeps it in the Document's runs and kinds; a markdown editor writes the marks into its source (`**`, `*`, `` ` ``, `~~`, `==`, `#`, `- `, `1. `, `- [ ] `, `> `, ```` ``` ````, `---`, `[text](url)`), leaving a code block's lines alone, so what is saved is the markdown. Its `.Link` / `.Image` write `[text](url)` / `![text](url)` with the address selected (it has no link bar, so `.Link_Apply`, `.Link_Remove`, `.Link_Close` and `.Image_Apply` do nothing there) | the editor keeps its own role and name; a toolbar of the app's own is its buttons' |
| `editor_control(ui, control, editor)` | counts a field or button of the app's own as part of an editor, as its built-in find bar is: while focus is in it the editor keeps painting its selection, so an app's own find bar can select each match and have it look selected. `NODE_NONE` undoes it; it goes with the node | focus and the accessibility tree are unchanged — the control keeps its own role and name |
| `editor_options(…, frame = false)` | an editor that fills a window: no border, no focus colour, square corners and no fill of its own, so the page is not a form field; the caret shows where focus is | the focus ring is the caret's; role, name and states are unchanged |
| `editor_options(…, font, size, line_spacing)` · `installed_fonts(t) -> ([]Installed_Font, ok)` · `editor_font(t, editor) -> (family, installed)` | how an editor *shows* its document, as Typora and Obsidian have it: `font` is a family this machine has (its regular, bold and italic faces used as the text asks, the toolkit's own fonts behind it for emoji and anything else the family lacks), `size` the body size the editor's other sizes scale from, `line_spacing` a multiplier on the line height. Each stays until changed; a change re-lays the document and the caret, selection and view stay where they are; `""` and `0` go back to the theme's. `installed_fonts` lists the families (sorted, `fixed` for fixed-width ones) by walking the font directories and reading each file's name table — concrete families, not fontconfig aliases — with `ok` false when there was no text engine to scan with, which is not a machine without fonts; `editor_font` is the family it actually draws in and whether the one asked for was found, so an app can say a document's font is not installed any more | the text's own role and name are unchanged; a family is a look, not content, so nothing new is announced |
| `editor_complete(ui, editor, complete: Completer, trigger: rune)` | an editor's completion source (see `Completer`); on a `code_editor` without one it offers the language's words and the identifiers nearby, opening on `COMPLETE_MIN` identifier characters or Ctrl+Space. **`trigger` opens the list on one character instead**, for an editor whose text is prose — `editor_complete(ui, ed, files, trigger = '@')` on a `text_area` opens it when `@` is typed at the start of a word, asks the completer again on every keystroke with what follows as the prefix, and closes on a space, Escape, the caret leaving the word or the keyboard leaving; accepting replaces the trigger *and* the query, so a candidate can insert `@"Stock check.xlsx" ` for a label of `Stock check.xlsx`. While the list is open Enter and Tab accept and do **not** reach the editor's `on_submit`, and Escape closes the list and nothing else, so a composer that sends on Enter and stops a reply on Escape keeps both one key later; a dismissed list stays dismissed until the trigger is typed again. A click on a candidate accepts it. Same list, same keys and same List "Completions" either way | List "Completions" of List_Items, the picked one Selected |
| `editor_images(ui, editor, images: Image_Source)` | the pictures behind a rich or live editor's image blocks (`![alt](src)` in markdown): a proc from `src` to an `^Image` the app keeps alive; nil shows a placeholder naming the source; the alt text is the caption | — |

`max_length` caps characters (typing and pasting stop at the limit);
`readonly` allows navigation, selection and copy but no edits (Readonly
state); a wrong or required value is marked with `set_invalid` /
`set_required`, as on any form control;
Ctrl+Enter sends `on_submit`; Shift-click extends the selection;
`wrap = false` keeps each paragraph on one line and scrolls sideways (wheel
with Shift, or the caret), with a scrollbar along its bottom as well as the
one at its right — it scrolls both ways, so it gets a bar each way rather
than the fades a sideways-only strip gets. `marks` decorate ranges: `Mark{from, to, kind, message}` (a `message` shows in a tooltip when the pointer rests on the mark)
with `.Error` / `.Warning` squiggles, an `.Info` underline and a
`.Highlight` behind the text — a spell checker, a search or a linter produce
them and the widget draws them; the dictionary itself is a separate package
on the roadmap.

`Document` (`document.odin`) is the model every editor shares — blocks with a kind (`Block_Meta`: paragraph, heading, bullet, numbered, task, quote, code, rule, image, table row; level / depth / checked / lang / src; `table_cells` splits a row) and attribute runs (`Run{end, attrs, href}`, `Attrs` of bold / italic / underline / strike / code / link); `document_set_attrs`, `document_set_meta`, `document_attrs`, `attrs_at`, `href_at` alongside the text edits, all in one undo journal — blocks of
UTF-8 text with `Pos{block, off}` positions, `document_make` /
`document_destroy` / `document_text` / `document_set_text` /
`document_replace` / `document_undo` / `document_redo`, and grapheme and
word movement across blocks. Keep it in your state and read it whenever you
like; the widget edits it in place and never copies it.

```odin
baldr.text_area(ui, &s.notes, placeholder = "Notes…", label = "Notes", min_lines = 3, max_lines = 8)
```

## Terminal

A terminal's screen: rows × columns of cells the app fills from its own
terminal state (libvterm, its scrollback), and every key given back to it.
Example: `examples/25_terminal`.

| Builder | Behaviour | Accessibility |
|---|---|---|
| `terminal(ui, screen: ^Term_Screen, on_key: Handler(Msg,Term_Key), on_text: Handler(Msg,string), on_resize: Handler(Msg,Term_Size), family, size, padding, width, height, flex, label, disabled, tag, key)` | draws `screen` in `family` ("JetBrains Mono"; the toolkit's monospace face without it) at `size` (scaled by the desktop's text size): every glyph on its cell's origin, the cell a whole number of device pixels (`cell_metrics(ui, family, size)` says how big), bold from the family's bold face, backgrounds as runs of one colour with no seams, box drawing, block elements, braille and powerline separators drawn to fill the cell exactly, anything the family lacks from the toolkit's faces and the system's (fitted to its cells), marks composed onto their letter, U+FE0F asking for the colour emoji; underlines single, double, curly, dotted and dashed in their own colour, strike, dim; the cursor as a block (its character inverted), bar or underline, hollow while it hasn't the keyboard, blinking with `blink` (never under reduced motion; still after ten idle seconds); a composition at the cursor. Only rows the app `term_touch`ed are made again, and only they are the compositor's damage. While it has the keyboard every key goes to `on_key` as a `Term_Key` (`key`, the xkb `keysym`, the `char` it makes, `mods`, `repeat`, and the `text` it typed) after the app's `shortcut`s — Tab, Escape, F10 and Alt+arrows included — and an input method's commits to `on_text`; Ctrl+Tab / Ctrl+Shift+Tab move focus out unless the app binds them. `on_resize` hears the `Term_Size{cols, rows, cell, px}` its node holds, at first and on every change; `padding` is a margin on every side in the screen's background (one fill with the grid's), the grid inside it and counted inside it — pointer samples, the wheel and drops still measure from the node's top left | Terminal, name = label; its text is the screen, a line a row with the trailing blanks gone, the caret at the cursor (built only while a reader listens), so a reader hears what a program prints; the cursor is its focus indicator (solid / hollow) |

The screen is app-owned and edited in place, like a `Document`:
`term_screen_resize(s, cols, rows)` (keeps what fits), `term_row(s, row)` (the
cells, an alias), `term_cell_set(cell, grapheme)`, `term_touch(s, row)` /
`term_touch_all(s)` (what changed), `term_screen_destroy(s)`. A `Term_Cell` is
`text` (one grapheme cluster, up to `TERM_CELL_RUNES` code points; empty for
the right half of a wide character), `fg`, `bg` (alpha 0: the screen's
`background`), `underline_color`, `style` (`Bold`, `Italic`, `Dim`, `Strike`),
`underline` and `width` (2 on a wide character's left half). A translucent
window: the surface `transparent` with a clear `clear`, and a translucent
`background`; the cells' own backgrounds stay opaque.

```odin
baldr.terminal(ui, &s.screen, on_key = to_pty, on_text = text_to_pty, on_resize = resize_pty,
	family = s.conf.font, size = s.conf.size, label = s.title)
```

## Table

| Builder | Behaviour | A11y |
|---|---|---|
| `table(ui, columns, count, selection, on_select, on_click, on_activate, on_context, sort, on_sort, drag, on_drop, accepts, drag_files, drag_user, drag_files_out, on_drag_out, on_range, on_zoom, on_edit, label_of, label_user, row_height, flex, height, label) -> (first, last)` | sticky header + virtual rows; build rows `first ..< last` with `table_row`; header dividers (hairlines, resize cursor, guide line) drag to resize and header cells drag sideways to reorder (Shift/Ctrl + Left/Right from the keyboard); sortable headers send `on_sort` with the column index; the app-owned `Selection` is edited in place (click, Ctrl-click, Shift-click, Up/Down, Shift+arrows, Space, Ctrl+A, Home/End, Page Up/Down) and `on_select` carries the cursor row; Enter or double-click sends `on_activate`; a plain primary click on a row — no Ctrl or Shift, and not the second click of a double — also sends `on_click`, which is the one thing `on_select` cannot say: that fires for every change of selection, every arrow key included, so "one click opens this row" built on it opens one per key press; `label_of` (a row's label, called with `label_user`) turns on type-ahead; the `reveal_index` command scrolls that row into view once, and asking again for the row already shown asks again | Table named by `label`; Column_Header (Selected = sorted); Row (Selected) named by its first cell; Cell |
| `table_row(ui, index)` | opens the row for data index `index` (keyed by it); one cell per column inside; close with `end` | Row |
| `cell(ui)` / `cell_text(ui, s, muted, icon, tabular)` | the next cell of the row, sized by its column; `cell_text` is one clipped line | Cell |
| `cell_edit(ui, value, on_submit: Handler(Msg, string), on_cancel: Maybe(Msg), select_stem)` | the cell as an editor for `value` (build it in place of `cell_text` for the cell the app is editing): focused with the name selected up to its extension (`select_stem = false`: all), Enter or leaving the field commits through `on_submit` (Ev.tag = the row), Escape sends `on_cancel`, Tab commits and asks `on_edit` for the next cell | Cell holding a Text_Input |

A cell holds any widget: `cell(ui)` then a `text_input`, `number_input`,
`select`, `checkbox`… then `end`, so an order form is a table of controls.
Row state stays in the app (rows are virtual). A control without a label
is named by its column header for assistive technology; Tab walks the
headers then each row's controls, and a control's own keys (arrows in a
number field, typing in a text field) never move the table's cursor. A
press on a control in a cell (a row's ▸, a toggle) is the control's: it
takes its click, while a press on the row's text picks the row and one on
its blank space starts a band.

`Column{title, width, flex, min_width, numeric, sortable}`: `width` fixes the
column, otherwise it takes `flex` (default 1) of the free width and never goes
under `min_width` (60). `Sort{column, descending}` is the app's state, shown in
the header; `column = -1` means unsorted. `Selection` lives in the app's state
(`selection_make(multi = true)`, `selection_destroy`), with `selection_count`,
`selection_contains`, `selection_clear`, `selection_set`, `selection_toggle`,
`selection_range`, `selection_all` for the app's own use. `selection_make()`
is single-select: Ctrl-click, Shift-click and Ctrl+A act as a plain click;
`multi = true` enables them. Pass no selection at all and rows cannot be
selected (Enter / double-click still activate).

```odin
first, last := baldr.table(ui, COLS, len(s.files), &s.sel,
	on_select = proc(e: baldr.Ev(int)) -> Msg { return Select_Row{e.value} },
	on_activate = proc(e: baldr.Ev(int)) -> Msg { return Open_Row{e.value} },
	sort = s.sort, on_sort = proc(e: baldr.Ev(int)) -> Msg { return Sort_By{e.value} }, label = "Files")
defer baldr.end(ui)
for i in first ..< last {
	baldr.table_row(ui, i); { defer baldr.end(ui)
		baldr.cell_text(ui, s.files[i].name)
		baldr.cell_text(ui, s.files[i].size)
	}
}
```

## Drag and drop

| Builder | Behaviour | A11y |
|---|---|---|
| `draggable(ui, node, kind, tag, count, files: Files_Of, user, on_drag_out: Handler(Msg, Drop), files_out: Files_Out)` | the node just built becomes a drag source: press and travel 6 px (or long-press then move on touch) lifts a ghost — the item itself, faded, with a count badge when `count` > 1 (a chip of its name where the item has no size of its own to copy) — that follows the pointer above everything without taking hits; Escape cancels; the pointer near a scroll region's edge scrolls it; a free-standing source becomes a Tab stop (named by its first text when it has none) so Ctrl+X can reach it, while rows of a tree / table / icon view stay under their view's one Tab stop | the ghost is a Status node, live = polite: "Dragging …" |
| `drop_target(ui, node, on_drop: Handler(Msg, Drop), accepts, positions, tag)` | the node takes drops of `accepts` kind ("" = any) at `positions` (`{.On}`, `{.Before, .After}`, or all three): the target under the pointer shows a ring (On) or an insertion line (Before / After, along its parent's axis) — except that a target the drag *started inside* is never ringed (a view cannot take what is already in it: moving an icon about a desktop would otherwise outline the screen), and a reorder among the item's own siblings previews live: the item is relinked into the slot as you drag, the siblings part (gliding where the container has `animate`), and it shows faded where it will land; Escape glides it home, a drop keeps the previewed order so the app's rebuild confirms it without a jump. The dragged item is always painted faded; release sends `on_drop` with `Drop{kind, tag, count, position, source}`; `Ev.tag` is the target's tag (`tag` sets it for nodes whose builder has none) | keyboard path: with a draggable item focused (or under a tree's, table's or icon view's cursor) **Ctrl+X** picks it up ("Picked up …" is announced), move focus to a target, **Ctrl+V** drops On it (After when On is not allowed), Escape puts it back; an app that binds Ctrl+X itself with `shortcut` keeps it (a file manager's Cut) and the view does not pick up |
| `on_rest: Handler(Msg, Drag_Rest)` on `icon_view` / `table` / `tree_item` / `breadcrumbs` | the same spring-loading for rows a **view** builds for itself, where an app has no node of its own to call `drag_rest` on: it fires with `Ev.tag` set to the row (or the part of the path), as `on_drop` does, so a file manager opens the folder a drag rests on and a path bar goes up to the part rested on. Heard for **any** kind, unlike the drop — resting asks a row to get out of the way, not to take what is carried — so the app decides per row (folders only, say). The view's own background is never a rest target: nothing opens there |
| `drag_rest(ui, node, on_rest: Handler(Msg, Drag_Rest), accepts, repeat)` | spring-loading: the node hears a drag that stands still on it for `DRAG_REST_MS` (700 ms, drifting no more than `DRAG_REST_SLOP`), so a folder opens, a sidebar place navigates to itself, a taskbar button raises its window — carrying a file somewhere three levels down without ever letting go. Unlike `drop_target` it says nothing about taking the drop: a node that accepts nothing still hears a rest, which is the point, since a taskbar button takes "pin" drops and not files. It fires **once** where the drag settles, and again only once the drag moves on or the handler puts something else under the pointer; where the handler changes what is under it, the drop target is worked out again from where the pointer is standing, so a drop lands in the folder that opened and a folder inside it can spring open in turn. Nothing is heard from a keyboard drag, after Escape, or while a cancelled drag springs back. `repeat = false` says acting once is enough and nothing else is heard until the drag moves: that is for a node whose handler takes the drag **somewhere else** rather than further in, and `breadcrumbs` uses it, since going up reflows the bar and an ancestor slides under a pointer that never moved | the handler's own doing: a view that navigates announces itself as it always does |

**Across apps.** A source given `files` (a proc returning the paths for
its `tag` and `count`, called with `user`) is handed to the compositor as
text/uri-list when the drag leaves the window, so it drops in a file
manager or a terminal; tables and icon views take `drag_files` /
`drag_user`. Another app's drag over the window is a drag of kind
`"files"`: a `drop_target(accepts = "files")` (or a view's `on_drop` with
`accepts = "files"`) receives the paths in `Drop.files`; they are read
while the app keeps running, and a source that stops writing for as long
as a source is allowed to take to make them (a minute, below) lands
nowhere. Between two windows of one app the drag stays the app's:
the window it comes over takes it as the same drag (its `kind`, `tag`,
`count` and `files`), so a drop there is an ordinary Drop with the
move-or-copy default and Alt's Copy here / Move here, and the source's
`on_drag_out` doesn't hear it. Linux (Wayland data device) today.

**Files made as the drag leaves.** A source whose files do
not exist yet — the entries of an archive being looked inside, a document
still being exported — gives `files_out` (`drag_files_out` on a table or
icon view) as well. That one answers the way *out* of the window, where
`files` keeps answering drops inside the app, and it may hand back a
`Files_Later` with its paths: text/uri-list and the GNOME and plain-text
forms are then written into the other program only once the source calls
`files_later_ready` (`files_later_failed`: they never will be, and the
forms go out empty), on the thread writing that program's pipe rather than
the one drawing the window. The promise is made with `files_later_new` and
given back with `files_later_release`, and it ends by itself a minute
(`FILES_LATER_TIMEOUT_MS`) after the drag left, so nothing waits for ever.
`on_drag_out` reports the paths that actually went, which is `files_out`'s
answer when there is one.

**What a drop says.** A table's or icon view's `on_drop` takes drops on its
rows or tiles and on its empty space — below the last row, between tiles,
an empty folder — with `Drop.background` true for the latter (Ev.tag is
then the view's, not a row's). `Drop.action` is what the user asked for:
Ctrl copies, Shift moves, Alt (or Ctrl+Shift) asks, `Default` leaves it to
the app, which a file manager reads as "move within a disk, copy across";
from another app it is the action negotiated with it. `Drop.mods` are the
modifiers held at release. A source's `on_drag_out` (`draggable`, or a
view's for its rows) hears a drag that left the window and was dropped in
another app, as a Drop carrying that app's action — a Move means the
files are gone from here.

`tree_item(drag = "entry", on_drop = …, accepts = "entry")` does both for a
tree: branches take drops On (into the folder), leaves Before / After.
`table(drag = "file", on_drop = …, accepts = "file")` and `icon_view(…)` do
it for every row / tile: a row that is part of the selection drags the
whole selection (`Drop.count` says how many, `Drop.tag` is the row pressed),
and rows take drops On (into that row). A cancelled pointer drag springs
the ghost back to where it was picked up (instant under reduce-motion).

```odin
chip := baldr.row(ui, …); …; baldr.end(ui)
baldr.draggable(ui, chip, "chip", tag = u64(i))
baldr.drop_target(ui, chip, proc(e: baldr.Ev(baldr.Drop)) -> Msg {
	return Reorder{from = int(e.value.tag), to = int(e.tag), before = e.value.position == .Before}
}, accepts = "chip", positions = {.Before, .After}, tag = u64(i))
```

## Tree view

| Builder | Behaviour | A11y |
|---|---|---|
| `tree_view(ui, label, flex, height, indent, padding, on_edit, key)` | opens a tree; one Tab stop for the whole tree, the cursor row shows the ring; Up/Down move the cursor and select, Right expands or steps into the first child, Left collapses or steps to the parent, Home/End, Page Up/Down by a viewport of rows, Enter activates, Space selects; not virtualised, so put a large tree in `scroll` | Tree named by `label` |
| `tree_item(ui, label, on_click, expanded, on_change: Handler(Msg,bool), selected, icon, on_activate: Handler(Msg,int), disabled, muted, drag, on_drop, accepts, on_submit, on_cancel, on_context: Handler(Msg,int), on_middle_click, drop_positions, tag, key) -> bool` | a branch when it has `on_change` (the chevron toggles it; `Ev.tag` is the item's `tag`), a leaf otherwise; returns whether the children scope is open — close it with `end` only then; click selects (`on_click`), a double-click activates; one indent guide per ancestor level; rows grow to 44 px on touch; items without `key` are identified by their label; `drag` makes the row a drag source of that kind, `on_drop` a target (On a branch, Before / After a leaf); `on_context` hears a right-click or the Menu key with the item's tag (the menu opens there, as on a table); `on_middle_click` a middle-click; `drop_positions` lets a leaf take drops On itself (a sidebar place) instead of Before / After; a disabled row's label, icon and chevron are dimmed and it shows no hover; `muted` draws a row's label and icon in the muted ink and changes nothing else (a file the project leaves out: there, but not part of it), except on a selected row, which keeps the selection's ink | Tree_Item, Expanded / Collapsed, Selected |

Expansion and selection are the app's state, echoed back through the
handlers, so a directory can be loaded the first time it is opened.

```odin
baldr.tree_view(ui, label = "Project"); {
	defer baldr.end(ui)
	if baldr.tree_item(ui, "src", Msg(Pick{1}), expanded = s.open[1], icon = .Folder, tag = 1, key = 1,
		on_change = proc(e: baldr.Ev(bool)) -> Msg { return Open{int(e.tag), e.value} }) {
		defer baldr.end(ui)
		baldr.tree_item(ui, "main.odin", Msg(Pick{2}), icon = .File_Code, on_activate = Msg(Edit{2}), key = 2)
	}
}
```

## Split pane

| Builder | Behaviour | A11y |
|---|---|---|
| `split(ui, size, on_change: Handler(Msg,f32), axis, min, max, sized, collapse, detail, on_close, back_label, gap, flex, width, height, tag, key)` | two `pane` scopes with a hairline divider between them; `size` is the sized pane's extent (`sized = .First` or `.Second`), the other pane flexes; `min` bounds both panes, `max` the sized one; dragging the divider (8 px grab zone, 24 on touch, resize cursor, accent bar on hover) or nudging it sends `on_change` with the new size, which the app stores; `collapse = .Compact` (or `.Medium`) shows one pane at a time at and below that size class — the first until `detail` is true, then the second fronted by a Back button (`back_label`) that sends `on_close`, as does Escape; the app keeps `detail` in its state so a resize keeps what was showing; `gap` is a gutter either side of the divider so the panes' content sits flush with the split's top and bottom; `tag` comes back as `on_change`'s `Ev.tag` (which window's divider moved) | Group; the divider is a Separator "Divider" with the size as its value; the Back button is a Button named `back_label` |
| `pane(ui, gap, padding, align, bg, glass, key)` | one side of the open split, a clipping column; close with `end`; `glass` makes it a sidebar in the theme's sidebar material where the surface's glass is live (thinner than the window's own tint, for a see-through window whose sidebar's glass is its only tint), and the sidebar's colour, opaque, anywhere else — Solid, a compositor that can't blur, an opaque window — unless `bg` gives one, so the desktop never shows straight through | — |

The divider is a Tab stop: Left/Right (Up/Down for `axis = .Column`) move it
8 px, 32 with Shift, Home/End to the limits. Below Compact width show one
pane at a time instead (branch on `size_class`).

```odin
baldr.split(ui, s.sidebar_w, on_change = proc(e: baldr.Ev(f32)) -> Msg { return Sidebar{e.value} }, min = 160, max = 480); {
	defer baldr.end(ui)
	baldr.pane(ui, bg = th.color.surface); { defer baldr.end(ui); sidebar(s, ui) }
	baldr.pane(ui, padding = .lg); { defer baldr.end(ui); content(s, ui) }
}
```

## Text

| Builder | Notes |
|---|---|
| `text(ui, s, role, size, color, muted, weight, mono, family, tabular, italic, sensitive, width, min_width, max_width, flex, key)` **`sensitive = true`** marks the string a secret shown on purpose — a revealed key, a recovery phrase. The tree's copy is **overwritten before it is freed**, on replace and on destroy, and the node reaches the accessibility bridge **without its characters**: `text` otherwise makes the string the node's accessible name, and anything on the session accessibility bus can read a name, which is how a revealed key leaks with no file ever written. It hides nothing on screen — the person asked to see it. The cost is worth naming: a screen reader user who asked to see their key cannot hear it either, so put a Copy button beside it, which is what every password manager does and is the accessible path for a 63-character key anyway. | roles: Display, Headline, Title, Body, Label, Caption (size and weight from the theme: body and caption regular, the others semibold); `weight` overrides it with `Regular` (400), `Medium` (500) or `Semibold` (600), the UI typeface's weight axis; `mono = true` draws it in the code face, `family` in a named one; accessible name = content |

## Controls

| Builder | Handler | A11y |
|---|---|---|
| `button(ui, label, on_click: Msg, variant, disabled, icon, icons, image, theme_icon, icon_only, size, default, pressed, on_middle_click, on_context, on_scroll, tag, key)` | message on click / Enter / Space; `size = .Small` is compact, 26 × 26 when `icon_only` (a tile's arrow) and a 12 px label otherwise; `icons` shows several icons side by side after `icon` (a bar button's Wi-Fi, sound and battery; decorative, so say what they show with `set_describe`); `theme_icon` is an icon theme name (an app's Icon=, an absolute path) drawn where `icon` goes, loaded as `theme_icon` loads it and in the label's colour, with `icon` drawn in its place when no theme provides the name; `default` makes it the button Enter means in its dialog: it takes the dialog's initial focus (a dialog that starts with a text field focuses the field) and Enter activates it unless the focused control uses Enter itself (a focused button, select, tab or menu item, a multi-line editor, a field with `on_submit`); `on_middle_click` is what a middle-click (press and release over it) sends; `on_context` is what a right-click or the Menu key (Shift+F10) while it is focused sends, with `Ui.context_pos` at the click or under the button so `context_menu` opens there; `on_scroll: Handler(Msg, Scroll)` gets a wheel or touchpad scroll over it before any scroll view around it, without taking focus: `Scroll{steps, delta, precise, mods, pos}`, whole wheel steps per axis (+y wheel down; a touchpad adds up to a step every 48 px), the event's px, touchpad or not, the modifiers, and where the pointer is over it; `pressed` makes it a toggle (show hidden files, a preview pane): off it takes the variant's quiet form, on its emphasis (the tonal fill for Ghost, Outline and Secondary); `button_options(ui, n, max_width, icon_size, icon_color, mark, badge, progress, quiet, focus_on_click, progress_style, indeterminate, italic)` sets rarer settings, kept until changed and applied in the build that sets them (one left out keeps what the button had, so a mark, a badge or a bar goes only when you pass its empty value: a mark with `length = 0`, `Button_Badge{}`, a negative `progress`): `max_width` caps it and ends its label in "…" where cut (a tight row shortens it further; the whole label stays its name and shows on hover), `icon_size` sizes its icon, theme icon or picture, `icon_color` colours its icon or theme icon (a full-colour one keeps its colours and fades with the alpha), `mark: Button_Mark{side, length, thickness, color, count}` is drawn inside the button's `side` edge, centred along it, taking no room (a taskbar's running dot or front bar; length 0 none, thickness 0 is 3 px, colour {} the content colour; changes ease, at once under reduce motion; `count` above 1 splits it into that many short marks in the same place — two windows of one app — none thinner than it is thick), `badge: Button_Badge{text, dot, color}` sits centred on its icon's top end corner, over it and taking no room: a count in a pill ("3", "99+") or, with no text and `dot`, a dot (a bell with notifications waiting), in the accent unless `color` says otherwise with its text in a colour that reads on it; it grows in and shrinks away (at once under reduce motion), `progress` (0…1) draws a thin bar across the bottom of its icon, taking no room and clear of the badge (a download on a taskbar entry): the value filled in the accent over a faint track, 0 an empty track, a negative value takes it away (busy or not), and the value eases as it changes; `progress_style = .Ring` draws it instead as a ring just outside the icon, in the room an icon-only button has round it, filling clockwise from twelve o'clock (a line glyph — a drive, a tray — whose bottom stroke a bar would land on); `indeterminate = true` shows progress with no known end, a band running along the bar or an arc going round the ring, still under reduce motion; on a button filled with the accent the progress takes the colour that reads on that fill, `quiet` takes the hover and press wash off for a control that answers the pointer another way (a dock's icons grow, so the wash would say it twice): it still hovers, presses, takes the keyboard and shows its focus ring, mark, badge and tooltip, and reads the same to a screen reader — only the wash goes, `italic = true` sets the label in italics (a preview tab the next file opened replaces; say so in its tooltip too), and `focus_on_click = false` (GTK's `focus-on-click`, macOS's toolbar buttons) lets a click act without taking the keyboard: Tab still reaches it and Enter or Space still press it once it has focus, so picking a tool with the pointer and then holding Space pans at once, and a field being typed in keeps the keys while a toolbar button is clicked | Button, name = label (a mark or badge is drawn, not announced: say what it means with `set_describe`); with `progress`, the value 0…1 as a progress bar carries it, or Busy when `indeterminate`; Default when `default`; Toggle_Button, Pressed while on, when `pressed` is set |
| `checkbox(ui, checked, label, on_change: Handler(Msg,bool), disabled, hide_label, tag, key)` | flipped value; `hide_label` keeps `label` as its name without drawing it | Checkbox, Checked state |
| `toggle(ui, on, label, on_change: Handler(Msg,bool), disabled, hide_label, tag, key)` | flipped value; knob glides; `hide_label` keeps `label` as its name without drawing it (a page header whose title already says it) | Switch, Checked state |
| `list_row(ui, label, on_click: Msg, icon, theme_icon, glyph, image: ^Image, image_round, detail, detail_mark, unread, value, end: Row_End, on, selected, hint, variant: Row_Variant, size: Row_Size, disabled, on_context, tag, key)` | a full-width row for a list or a popover's page (a power menu, sound outputs, networks, tunnels, a launcher's results): `icon` (or `theme_icon`, `icon` standing in when no theme provides it, or `glyph`, an emoji or a letter) and the label with a muted `detail` under it at the start, `value` and `end` at the end — `.Check` in the accent while `on`, `.Switch` showing `on`, `.Chevron` for a page; at least 38 px tall; `variant = .Tile` puts the icon in a 36 px tile (an app's own icon filling it, an icon or glyph on a quiet tile; `.Accent` tints the tile with the accent) over a 14 px medium label and a 12.5 px detail, and `size = .Large` makes the label 23 px semibold (a calculator's answer); `selected` makes it the list's current row, the accent at 16 % behind it and a 3 px bar inside its start, without moving focus, and shows `hint` at its end ("↵ open": its first word in a keycap); the whole row is the one control: click / Enter / Space queue `on_click`, a right-click or the Menu key `on_context`; Up / Down walk rows inside a popover **`image`** is a decoded picture in the leading slot: a contact's avatar, round unless `image_round = false`, cropped to fill rather than squashed, and taking precedence over `icon`, `theme_icon` and `glyph` — so passing the contact's initial as `glyph` beside it is the fallback for someone with no picture. It is drawn at the size of that variant's leading slot, so it lines up with the rows around it: an icon's 16 px in a plain row, the tile's 36 in a tiled one. A conversation list wants **`variant = .Avatar`**, which makes that slot one circle whatever it holds — picture, initial or icon — because a list mixing 36 px pictures with 16 px initials starts its labels at two different places and reads ragged. The picture is decoration: the row is still named by its label. **`unread`** is how many messages are waiting: a pill in the accent at the row's end — a circle at one digit, "99+" past ninety-nine — and the row is emphasised with it, its detail drawn in the ordinary text colour instead of the muted one, its `value` (the time) in the accent, and the start bar shown, the same bar the selected row gets, because both mean "look here". The count is also **said** in the row's description ("3 unread"), since an accent circle is no use to someone who cannot see it, and the description carries the real number even where the pill reads "99+". **`detail_mark`** is a byte range of `detail` drawn in the full colour and a heavier weight — the words a search matched, so the eye finds why the row is in the list. Trim the snippet around the match before passing it: the detail is one line and what does not fit is cut from the end. A range that is empty or outside the string is ignored. | Button, or Radio (`.Check`) / Switch (`.Switch`) with Checked while on; Selected while `selected`, and a field whose keys walk the rows names the current one with `set_active_item(tree, field, row)` (its active descendant); name = label, description = detail and value |
| `emoji_picker(ui, on_pick: Handler(Msg,string), recents: []string, skin: Skin_Tone, on_skin: Handler(Msg,Skin_Tone), width, height, label, key)` | every emoji the bundled face can draw, as a grid with a search field, the nine Unicode groups, skin tones and the app's own recents. `on_pick` is sent the sequence with the tone already applied, ready to insert; it is the picker's and is valid until the next pick, so copy what you keep. **`recents` and `skin` are the app's**, passed in and reported back (`on_skin`), because what counts as recent and which tone someone uses outlive the window and belong in the app's own file; the first 24 recents show in a section of their own at the top, and one the face no longer draws is dropped rather than shown as a box. Searching replaces the sections with one run of matches, best first: matching is by **word**, so "ca" finds cat and car but not scar. The search field takes the keyboard when the picker appears, Enter there picks the best match and Down steps into the grid; the grid is then **one Tab stop** whose arrows move a cursor, Home and End go to the ends of a row, Page Up and Down move a screen, and Enter or Space picks. A line under the grid names what the cursor or the pointer is on. The grid is virtualised, so two thousand emoji cost a screenful of nodes. The table behind it is also usable on its own: `emoji_table`, `emoji_search`, `emoji_group_range`, `emoji_with_tone` — for an app that turns `:joy:` into an emoji as you type. | List named by `label` whose active item is the cell under the cursor (`set_active_item`), each cell a List_Item named by its CLDR short name ("grinning face"), which is what search matches; the tone swatches are Radios in a group named "Skin tone" and the group strip is a Tab_List |
| `icon_toggle(ui, icon, on, label, on_change: Handler(Msg,bool), size, disabled, tag, key)` | a round on/off button showing `icon` (a Control Centre tile's Wi-Fi, Do Not Disturb): on the accent with the on-accent icon, off the strong fill (`theme.color.fill_strong`) with the content colour, easing between them; `size` is its diameter (34); click / Enter / Space flip it and send the new value; the words beside or under it are the app's | Toggle_Button, name = label, Pressed while on |
| `slider(ui, value, min, max, on_change: Handler(Msg,f32), step, width, flex, size, icon, label, disabled, on_icon: Maybe(Msg), icon_label, icon_pressed, on_commit: Handler(Msg,f32), tag, key)` · `slider_options(ui, n, marks: []f32, format: proc(f32) -> string)` | live while dragging, snapped to `step`; while the thumb is held the drag owns the value, so a player reporting its position doesn't pull it from under the pointer; `on_commit` is the value let go of, or stepped to by a key (a seek), and after one the slider keeps that value until the app's comes near it or a second passes, so the thumb doesn't flick back while the seek lands (a slider without `on_commit` takes the app's value at once, as before); `slider_options`, passed every build, ticks `marks` across the track (chapters, bookmarks: in the fill's ink where the value has passed them), which Ctrl+Left / Right step between, and `format` gives the value as a reader reads it ("3:25"), shown above the pointer resting on the track and above the thumb while it is dragged; `size = .Large` is a 30 px pill in the strong fill, the accent filling it up to and under a round knob, with `icon` inside the filled start (pass another with the value: muted at 0); `on_icon` makes that icon a toggle of its own (a mute): a click, Enter or Space on it sends `on_icon`, it is a Tab stop before the track, and a press on the track beside it still sets the value; Left / Down and Right / Up move by `step` (a hundredth of the range without one; Shift ×10), Page Up / Down by a tenth, Home / End to the ends | Slider with value/min/max; with `on_icon`, a sibling Toggle_Button named `icon_label`, Pressed while `icon_pressed` |
| `color_field(ui, color, on_change: Handler(Msg,Color), label, width, disabled, tag, key)` | the drop-down form: a swatch and the hex; click / Enter / Space open a `color_picker` in a popover, Escape or a press elsewhere closes it | Combo_Box named `label`, described by the hex, with a popup (Has_Popup), Expanded while open |
| `color_picker(ui, color, on_change: Handler(Msg,Color), label, width, key)` | a swatch, a hex field (Enter commits and selects it, Escape reverts, leaving commits) and Hue / Chroma / Lightness sliders in OKLCH whose tracks show the colours they select; `color_hex` and `color_parse_hex` help | Group named `label` of Sliders "Hue", "Chroma", "Lightness" and a field "Hex"; the swatch is an Image named by its hex |
| `radio(ui, selected, options, on_change: Handler(Msg,int), label, horizontal, disabled, tag, key)` | one Tab stop; a click picks, Up/Down/Left/Right move the pick and wrap, Home/End; the dot fills in; a click between the options focuses the group and picks nothing | Radio_Group named `label` of Radios, Checked; the ring sits on the pick |
| `segmented(ui, selected, labels, on_change: Handler(Msg,int), icons, label, width, flex, disabled, tag, key)` | the same choice as a pill row sized to its labels (`icons`, one per segment, go before the labels in their colour, decorative: a power mode's leaf, gauge and bolt) (`width` or `flex` spreads them across it: equal while each fits an equal share; else the ones that need more keep their width and the rest share what is left alike; then their padding tightens alike; only then are the widest labels cut to one width with "…", still named whole); the picked segment's pill glides; a click on the track beside the segments focuses the control and picks nothing; sized to its labels, the track stays under them when a parent stretches it | Radio_Group of Radios, Checked |
| `chip(ui, label, selected, on_change: Handler(Msg,bool), on_close: Maybe(Msg), icon, disabled, tag, key)` | a pill for a tag or a filter: click / Enter / Space flip it (a check shows when selected); `on_close` adds a × that sends it, as do Backspace / Delete on the focused chip | Toggle_Button, Pressed when selected; the × is a Button "Remove <label>" |
| `menu_chip(ui, label, open, on_click: Msg, disabled, tag, key)` | a pill that shows a choice and opens a menu of the others (a sound tile's "Speakers", a screen's name): a click, Enter or Space sends `on_click`; open a `menu` anchored to the node it returns, with `open` as that menu's state. It sits in `fill_strong` with a 12 px medium label and a 14 px chevron, padded 4 / 6 / 4 / 10; a label too long for its room ends in "…" and shows whole on hover | Button, name = label, Has_Popup; Expanded while its menu is open, else Collapsed |
| `text_input(ui, value: ^Text, placeholder, on_change: Handler(Msg,string), on_submit: Handler(Msg,string), label, width, flex, disabled, password, quiet, initial, compact, on_cancel: Maybe(Msg), on_key: Handler(Msg,Key_Press), on_paste_other, max_length, on_context: Handler(Msg,Editor_Context): Handler(Msg,Paste_Other), tabular, focus, tag, key)` | one line edited in place: typing sends `on_change`, Enter `on_submit` (without one Enter goes on to a dialog's default button); arrows by grapheme, Ctrl+arrows by word, Home / End, Shift extends, Ctrl+A / C / X / V, Backspace / Delete (Ctrl: by word); click places the caret, drag selects, double-click a word, triple-click all; what the person selects (never in a `password` field) becomes the primary selection, and a middle click puts the caret there and types it — as in a `text_area` and its editors; Escape sends `on_cancel`, else clears the selection; `on_key` hears the keys the field does not use, as a `Key_Press` with the modifiers (a list below the field, walked and acted on): Up, Down, Page Up and Page Down, Shift+Delete (without `on_key` it deletes), **Enter with Shift, Ctrl or Alt** (a find bar's "previous match", which `on_submit` cannot say because `Ev(string)` has no modifiers; a plain Enter is always `on_submit`'s, and without `on_key` a modified one submits as before), Ctrl or Alt with a character key other than Ctrl+A / C / X / V / Z / Y; a Ctrl or Alt chord the window binds stays the window's — a *modified* Enter included, with or without `on_key`, so a file manager's Alt+Enter is Properties from its path bar too — as do Alt and Super with an arrow or Page key; `on_paste_other` hears a Ctrl+V that found no text but a picture or files on the clipboard, for a field that takes more than text; `focus` takes the focus, caret at the end, when it turns true (a path bar opening); `password` shows bullets, never copies or cuts to the clipboard and makes the `Text` secret (it zeroes the blocks it outgrows and the bytes it drops; `text_reserve` sizes one up front, `text_scrub` zeroes and empties it once read), and says when Caps Lock is on, as GTK's and KDE's do: a sign at its end while it has the keyboard (in the warning colour, 3:1 against the field), the text stopping short of it; fields on two surfaces may share one `Text` (each keeps its own caret and selection, fitted to the buffer before a key uses them); a nil `value` keeps a buffer of its own seeded with `initial`; `compact` is the tight look of an editor standing in for a label; an input method's composition is shown at the caret, underlined, and is never in the buffer or in undo (a `password` field takes no input method); `focus` turning true hands the field over with its value selected, so a shortcut that opens a path bar or a filter replaces rather than appends (Escape still reaches the app) **Undo and redo**: Ctrl+Z goes back, Ctrl+Shift+Z and Ctrl+Y come forward, with a run of typed characters coalesced into one step so Ctrl+Z takes back a word rather than a letter — a pause of 700 ms, or anything that is not a plain typed character, starts a new one. **A `password` field keeps no journal at all**, because a history of a secret is a copy of a secret sitting in the tree for as long as the field lives. The journal is bounded at 64 steps. **The app can move the caret**: `text_input_set_selection(t, n, anchor, caret)` puts the selection where the app wants it (byte offsets, clamped and snapped to graphemes; the same offsets twice move the caret alone), and `text_input_insert(ui, n, text)` puts text in at the caret exactly as typing would — the selection replaced, the caret after it, `max_length` honoured, `on_change` fired and the edit in the field's own undo journal. A keypad beside a field, a palette, an "insert emoji" button all want the pair: `text_insert` on the `Text` behind the field's back leaves an edit the journal never saw, so the field's own Ctrl+Z restores a state that never existed. Focus does not move, and a disabled field takes the caret move (it draws no caret either way) but not the text. **Each app insert is one undo step**: a run of typed characters coalesces so Ctrl+Z takes back a word, but a press of a button is one deliberate act — it does not join the typing before it, and the typing after it starts its own step. An empty `text` takes out what is selected and nothing else, which is how a keypad's Backspace is written (select the grapheme before the caret, insert nothing over it) — an input method committing nothing means nothing and is dropped instead. Both are called from `view`, not `update`, which has no tree: a keypad records the key its button sent and the `view` of that same wake-up applies it, so nothing lags a frame. **`tabular = true`** gives the value figures of one width, so a sum or an amount does not shuffle sideways as it is typed — the same `tnum` `text` takes, and the caret is measured with it too. **`paste_prefer = .Picture`** takes a picture over the text offered beside it — copying an image in a browser puts the picture *and* its URL on the clipboard, so a plain Ctrl+V pasted the address and lost the image. The app hears `on_paste_other` and nothing is inserted; text alone still pastes as text. **Marked wrong or required** with `set_invalid` / `set_required`, as any form control is: a danger frame and the states a reader reads; `set_describe` carries the message. | Text_Input named `label` (else the placeholder), the contents as the value (bullets for `password`); a `password` field is described "Caps Lock is on" while it is |
| `search_field(ui, value: ^Text, placeholder, on_change: Handler(Msg,string), on_submit, on_cancel: Maybe(Msg), label, width, flex, disabled, focus, tag, key)` | a search box: a magnifier, a placeholder, and a cross once there is something to clear. It is a `text_input` inside its own frame rather than a field with decorations bolted on — selection, input methods, the clipboard, the context menu and the caret have to be the same machinery or they are that machinery written twice — and what is its own is the behaviour. **Escape clears it** and stops there, but only while it holds text: an empty one lets Escape go on to close the sidebar or dialog around it, because a dismissal is never the destructive choice. The cross clears, reports the change, and leaves the keyboard in the field so the next query can be typed straight away; it is a Tab stop after the field, so it can be reached without the pointer, and a disabled field has none. `on_change` fires on every keystroke — **debounce it in the app**, since only the app knows what its search costs — and `on_submit` on Enter, for the search that should run at once whatever the debounce was waiting for; `on_cancel` is what an **already empty** field sends on Escape. The frame shows the focus (it turns to the accent) and the field inside is `quiet`, drawing neither frame, ring nor hover wash, so the control reads as one thing and not a seam between three. `search_text(ui, n)` reads the contents back. | Search_Box named by `label` (else the placeholder), the magnifier decoration, the cross a Button named "Clear search" |
| `number_input(ui, value, on_change: Handler(Msg,f32), min, max, step, label, width, disabled, tag, key)` | a field with − / + buttons: Up / Down step (Shift: ten steps), Enter commits what was typed and selects it (typing again replaces it; focus stays), Escape reverts, leaving the field commits; clamped to `min` / `max`, shown with `step`'s decimals | the field is a Spin_Button named `label` with value / min / max; Buttons "Decrease <label>" / "Increase <label>" |
| `date_field(ui, date, on_change: Handler(Msg,Date), label, min, max, week_start, width, disabled, tag, key)` | the drop-down form: shows the date the locale's short way with a calendar icon; click / Enter / Space open a `date_picker` in a popover, a pick closes it and focus returns, Escape or a press elsewhere dismisses | Combo_Box named `label`, described by the full date, with a popup (Has_Popup), Expanded while open |
| `time_field(ui, time, on_change: Handler(Msg,Time_Of_Day), label, clock, seconds, width, disabled, tag, key)` | the drop-down form: shows the time the locale's way with a clock icon; click / Enter / Space open a `time_picker` in a popover, Enter in the picker or Escape closes it and focus returns | Combo_Box named `label` with the time as its value, with a popup (Has_Popup), Expanded while open |
| `time_picker(ui, time, on_change: Handler(Msg,Time_Of_Day), label, clock, seconds, disabled, tag, key)` | one field of hour, minute (and second with `seconds`) and AM / PM segments; `clock = .Locale` (default) follows the desktop's 12 / 24-hour choice, `.H24` / `.H12` force one. One Tab stop: click, Left / Right or the wheel pick a segment; type the digits (two per segment, moving on by itself), Up / Down step (Shift: ten minutes or seconds), Home / End go to the ends, A / P set the period and a click on it flips it, Backspace clears; drag a segment up or down to scrub it; ▲ ▼ appear on touch. Always sends a 24-hour `Time_Of_Day` (`core:time/datetime`'s `Time`) — a wall-clock value with no zone: `now_local()` / `now_utc()` and `time_of_day(instant, local)` read the clock, and `core:time` converts instants either way; `time_text(t, tm, seconds, clock)` writes one the locale's way | Group named `label` with the time as its value, of Spin_Buttons "Hour" / "Minute" / "Second" / "AM / PM" with their values; the ring sits on the picked segment; on touch Buttons "Up" / "Down" |
| `date_picker(ui, date, on_change: Handler(Msg,Date), label, min, max, week_start, key)` | an inline month grid in the locale's names, starting the week on the locale's day (`week_start` overrides); one Tab stop: arrows move the cursor by a day / week (turning the page at the edges), Page Up / Down turn the page, Home / End go to the week's ends, Enter / Space pick, ‹ › turn the page, a click picks; days outside `min` / `max` are disabled; `Date` is `core:time/datetime`'s (`today()`, `date_text(t, d)`, `date_short(t, d)`, `date_add_days()`, `date_add_months()` help) | Group named `label` of Buttons named in full ("Friday 11 September 2026", in the locale's order), the picked day Selected, today described "Today" |
| `expander(ui, title, expanded, on_change: Handler(Msg,bool), tag, key) -> bool` | a disclosure header with a chevron; returns whether the content scope is open — close it with `end` only then; the content fades up | Button named `title` with Expanded / Collapsed |
| `tab_bar(ui, selected, labels, on_change: Handler(Msg,int), tones: []Tone, key)` | index of the clicked tab; indicator glides; scrolls sideways when the tabs do not fit (wheel, Shift+wheel, touch pan), keeps the selected and focused tab in view, fades clipped ends **`tones`** is a tone per tab, for one that asks to be noticed — message requests waiting, a failed sync. A tab with a tone other than `.Neutral` is drawn in it **while it is not the selected tab**, and reads as an ordinary selected tab once it is: by then it has the person's attention and the colour is only noise. Shorter than `labels`, or nil, is `.Neutral` throughout. A tab asking for attention is also **described** as doing so, because a colour on its own is not something everyone can see. | Tab_List of Tabs, Selected state |

Button variants: `.Primary` (filled, gradient, low elevation), `.Secondary`
(tonal), `.Outline`, `.Ghost`, `.Danger`.

## Commands (effects from `update`)

| Command | Behaviour | Outcome |
|---|---|---|
| `quit(Msg)` | ends the app | — |
| `open_files(Msg, on_done: Handler(Msg, Files), title, multiple, directory, filters, folder, accept_label, tag)` | the desktop's own open dialog (the FileChooser portal on Linux — works in Flatpak; native dialogs on the other backends when they land) | `on_done` gets `Files{paths, ok}`: the chosen paths, or `ok = false` when cancelled or no dialog is available; the paths live only while the message is handled — clone what you keep; `tag` comes back as the `Ev`'s tag, so an app with several windows knows which one asked |
| `save_file(Msg, on_done, title, name, filters, folder, accept_label, tag)` | the desktop's save dialog | one path to write, or `ok = false`; `tag` as for `open_files` (which document is being saved as) |
| `job(Msg, work: proc(^Job(Msg)), data, on_done: Handler(Msg, Job_Done), tag)` | runs `work` on a thread of its own; `data` is handed to it untouched (something the worker owns, never a pointer into State) | the worker's `post(job, msg)` calls arrive at `update` in order, waking the loop; when it returns, `on_done` gets `Job_Done{cancelled}` with the job's `tag` |
| `cancel(Msg, tag)` | asks every running job with `tag` to stop | the worker sees `cancelled(job)` turn true and returns; its done message reports it |
| `batch(Msg, cmds…)` | runs several commands from one update, in order | each one's outcome as above |
| `delay(Msg, ms, msg)` | sends `msg` once, `ms` milliseconds from now | `msg` |
| `copy_text(Msg, text, primary)` / `copy_files(Msg, paths, cut)` | puts text, or local paths as files (text/uri-list, the form GNOME's file managers paste, and the paths as plain text), on the clipboard; `cut = true` marks them cut for GNOME's and KDE's file managers, which then move them on paste; `primary = true` makes the text the primary selection instead (what was last selected, which a middle click pastes) | — |
| `paste(Msg, on_done: Handler(Msg, Pasted), primary)` | reads the clipboard; `primary = true` reads the primary selection (its text only) | `Pasted{text, files, cut}`: the text form, the local paths when files were there, and whether they were cut (the paste should move them); the strings live only while the message is handled |
| `copy_image(Msg, img)` | puts a picture on the clipboard as image/png; the pixels are copied at once (the app may change or free `img` straight after) and the PNG is made on a thread, so neither the copy nor a paste in another program makes the UI wait | — |
| `copy_html(Msg, html, text)` | puts formatted text on the clipboard: `html` as text/html and `text` as the plain text, both at once, so a word processor, an email composer or a chat pastes headings, bold, lists and links while a terminal or a plain field pastes the text. The text goes on in every form `copy_text` offers; on Windows the HTML goes on as CF_HTML, which is what Word and Outlook paste. Both strings are copied, so the app may free them straight after; a platform whose clipboard Baldr can only put text on offers the text alone | — |
| `paste_image(Msg, on_done: Handler(Msg, Pasted_Image))` | reads the picture on the clipboard in its best form (PNG, then BMP, QOI, TGA and netpbm, then JPEG, then SVG drawn at its own size), read and decoded on a thread; use a handler proc, since a plain message would drop the picture | `Pasted_Image{image, mime, data, ok}`: the picture, yours to `image_destroy`; the form and its bytes as they came, which live only while the message is handled; `ok` is false for no picture or one that would not decode (`mime` and `data` still say what was there) |
| `read_file(Msg, path, on_done: Handler(Msg, File_Read), tag)` | reads the whole file on the IO thread (core:nbio; a plain thread where io_uring is locked down) | `File_Read{path, data, ok, error}`: `data` lives only while the message is handled — clone what you keep |
| `write_file(Msg, path, data, on_done: Handler(Msg, File_Written), tag)` | replaces (or creates) the file with `data`, copied, on the IO thread | `File_Written{path, ok, error}` |
| `activate(Msg, tag, token)` | asks the desktop to bring the app's own window (the surface whose `tag` it is; 0: its first window) to the front and give it the keyboard, through xdg-activation: for MPRIS's Raise, a second launch, a notification's click; `token` is one the app was handed (a D-Bus caller's), else the app asks the desktop for one itself, tied to its latest input; a window the app opens again in the same update is activated as it shows, and a process's first window takes the `XDG_ACTIVATION_TOKEN` its launcher gave it (not handed on to what it starts); the desktop decides what it does — raise the window, or mark it as wanting attention (the compositor does the latter) | nothing comes back |
| `open_path(Msg, path, on_done: Handler(Msg, Path_Opened))` · `reveal_path(Msg, path, on_done)` | opens a local file the app itself made with the desktop's handler for it — a spreadsheet in LibreOffice or Excel, a PDF in the reader — or shows it in the file manager, picked out where the file manager can (a folder is shown as itself). Not `open_url`: that takes URLs out of content and allows three schemes, while these take a path the app made, so what is checked is what the path *is* — it exists, it is a regular file (a folder too for reveal), it is not executable, it is not a `.desktop`, and it is no longer than `PATH_MAX_LEN`. Handing a handler an executable is how "open the spreadsheet I exported" becomes "run this"; an app that means to launch something does it itself. `path_openable(path, dir_ok)` asks the same question. Linux: the portal's `OpenFile` / `OpenDirectory`, which take an open descriptor rather than a path, so nothing is re-resolved between the check and the open; without a portal, `xdg-open`, and then reveal opens the folder with nothing picked out. Windows: `ShellExecuteW "open"` and Explorer's `/select` | `on_done` gets `Path_Opened{path, ok}`: `ok` false when the path was refused, nothing is registered for that kind of file, or the person dismissed the chooser — tell them where the file is then. The string lives only while the message is handled |
| `open_url(Msg, url, on_done: Handler(Msg, Url_Opened))` | hands `url` to the desktop's own handler — the person's browser for http and https, their mail app for mailto — and nothing else: `file:`, `data:`, `javascript:` and an app's own scheme are refused here, because a chat app's links come from a model's reply or a page it was given (`url_openable(url)` asks the same question, for a view that would rather show an unopenable link as plain text). Linux: the OpenURI portal, else `xdg-open`, never through a shell. Windows: `ShellExecuteW` | `on_done` gets `Url_Opened{url, ok}`: `ok` false when the URL was refused, nothing is registered for it, or the person dismissed the chooser — show the link to copy then. The string lives only while the message is handled |
| `poster(Msg, on_done: Handler(Msg, Poster(Msg)))` · `post_from(p, msg) -> bool` | a way in for code Baldr didn't start: a C library calling back on its own thread (libmpv's wakeup, sd-bus, PipeWire); keep the Poster in State and hand it to the library; `post_from` is safe from any thread, queues the message and wakes the loop as a job's `post` does — no polling job; after the run has ended it posts nowhere (false), safely, so a late callback between `run` returning and the library's shutdown is harmless | the Poster arrives in `on_done`; posted messages reach `update` in order |
| `toplevel_activate(Msg, id)` / `toplevel_set_minimized(Msg, id, on)` / `toplevel_set_maximized(Msg, id, on)` / `toplevel_set_fullscreen(Msg, id, on)` / `toplevel_close(Msg, id)` | asks the desktop to raise, minimise or restore, maximise or restore, make fullscreen or not, or close window `id` from `toplevels()` (a taskbar's buttons); nothing for a window that has gone, or where the desktop doesn't list windows | the change comes back through `toplevels_changed` |
| `workspace_activate(Msg, id)` / `workspace_assign(Msg, id, output)` | switches to workspace `id` from `workspaces()`, or moves it to the screen named `output`; each goes with the compositor's commit | the change comes back through `workspaces_changed` |
| `lock_session(Msg, on_locked, on_finished, on_shown)` | locks the session (Wayland: ext-session-lock-v1) for a lock screen that is a Baldr app. While the lock is live the app's `.Lock` surfaces open — one per screen, `Surface_Desc{kind = .Lock, output = o.name}` for each of `outputs()`, tagged by the screen's name (a hash of it), at the screen's size, opaque and without glass; they follow screens coming and going — and no other surface opens (one declared then waits for the unlock; one already open stays, hidden by the desktop). Menus and popovers on a lock surface open inside it; the keyboard follows the desktop's choice of lock surface; text fields (`password = true` too), the pointer and touch work as anywhere. Ignored while a lock is live | `on_locked` when every screen is hidden; `on_shown` once every lock surface has had a frame of its own on screen since (the lock screen is up: a locker that sleeps the machine waits for it); `on_finished` when the desktop refused (another lock is live, or it has no lock protocol) or, after `on_locked`, ended the lock itself — then call `unlock_session` |
| `keyboard_locks(ui) -> Lock_Keys` · `keyboard_layout(ui) -> (name, layouts)` · `ui.surface.keyboard` | read in a view, no command: the lock keys that are on (`{.Caps, .Num}`; the locked ones, so Caps Lock on before the view showed counts), the active layout's name as the keymap has it ("English (UK)") and how many layouts there are, and whether this surface (or a popup of it) has the keyboard. A lock screen puts its password card where the keyboard is and the clock on the other screens, says Caps Lock, and names the layout when there is more than one | views are built again whenever any of it changes |
| `unlock_session(Msg)` | unlocks the session and closes the lock surfaces: the only thing that unlocks. Baldr never does on its own — not when the app quits, returns from `run`, crashes, drops its lock surfaces, loses the desktop or hears `on_finished`; the session stays locked, as the protocol promises. Before the desktop answered `lock_session`, it withdraws the lock (the session is unlocked the moment the desktop locks it). The app may quit straight after: the desktop has the unlock before the connection closes | nothing comes back |

Inside a worker: `post(job, msg)` queues a message (copied; heap-allocate
what it points to and let `update` own it), `cancelled(job)` says whether
to stop, and `job.data` / `job.tag` are what the command passed. Quitting
cancels every job and waits a moment for the workers to return.

`App.start(s) -> Cmd` runs once after `init` for the command an app begins
with (read its file, start a job).

Three shapes cover most background work. **Progress:** one `job` that
posts as it goes (`09_jobs`). **Polling:** an `every` line whose message
returns a `job` that fetches and posts the result; the timer's phase is
kept, so a slow fetch does not pile up. **A live connection:** one
long-running `job` that blocks on its socket, posts each message as it
arrives and returns when `cancelled` — the app sees a stream of messages
and never a thread. The network client itself (HTTP, TLS) is the app's;
Odin core has sockets, not HTTP.

## Subscriptions (what the app listens to)

`App.subscriptions(s, out)` declares, from the state, what the app listens
to. It is called at start and after every update: a line that is still
there keeps running (an `every` timer keeps its phase, its message is
refreshed), a new line starts, a gone line stops.

| Subscription | Behaviour | Outcome |
|---|---|---|
| `every(Msg, ms, msg, tag)` | sends `msg` each `ms` milliseconds; a blocked app gets one when it wakes, not a burst | `msg` |
| `watch(Msg, path, on_change: Handler(Msg, File_Change), tag)` | reports changes to a file (also through a save-and-rename) or to a directory and its entries; inotify on Linux, nothing on a backend without watches yet | `File_Change{path, name, kind}` with the sub's `tag`: `name` is the entry inside a watched directory ("" for the path itself), `kind` Created / Modified / Removed |
| `outputs_changed(Msg, msg, tag)` | sends `msg` when a screen is added, removed or changes (mode, scale, position, transform); `baldr.outputs()` has the new set: name, description, logical `pos` and `size`, `mode_px`, `scale`, `transform`, `refresh`, `primary`. The list is in arrival order, so use `primary` for "the first screen" — the top-left-most one, or the connector `BALDR_PRIMARY_OUTPUT` names. It is also sent when one of the app's surfaces moves to another screen (`surface_rect` answers anew). Surfaces declared for a screen (a bar's `layer.output`, a lock surface's `output`) open and close with it by themselves, before `msg` is handled | `msg` |
| `toplevels_changed(Msg, msg, tag)` | sends `msg` once for each batch of changes to the desktop's windows (opened, closed, retitled, moved to another screen, activated, minimised, maximised, fullscreen); `baldr.toplevels()` has the new list: `id`, `handle`, `title`, `app_id`, `outputs`, `parent`, `activated`, `maximized`, `minimized`, `fullscreen`. `id` is Baldr's and means nothing to anyone else; `handle` is the compositor's name for the window on this app's own connection (the foreign-toplevel handle's object id), what an app passes to the compositor over another channel to name exactly that window where an app id and a title cannot. Wayland: wlr-foreign-toplevel-management; empty elsewhere | `msg` |
| `workspaces_changed(Msg, msg, tag)` | likewise for workspaces; `baldr.workspaces()`: `id`, `identifier` (the compositor's, stable across runs), `name`, `number`, `outputs`, `active`, `urgent`, `hidden`, `can_activate`, `can_assign`. Wayland: ext-workspace; empty elsewhere | `msg` |

`File_Filter{name, patterns, mime}` lists globs (`"*.png"`) or MIME types.
A command is returned from `update`; the outcome arrives as an ordinary
message, so it goes through `update` like everything else.

## Feedback

| Builder | Behaviour | A11y |
|---|---|---|
| `toast(ui, text, on_close: Msg, action, on_action: Maybe(Msg), duration_ms, tone, key)` | a brief message that slides up at the bottom, centred; sends `on_close` after `duration_ms` (5 s), from its ×, and waits while the pointer rests on it; an optional `action` button; several stack upwards; the app keeps the list of toasts in its state and builds one call per toast | Status announced politely (assertively for `.Danger`), Button "Dismiss" |
| `progress(ui, value, label, width, flex, indeterminate, key)` | a 6 px bar: the fill eases to `value` (0..1); `indeterminate` sweeps a band, still under reduce-motion | Progress named `label` with the value, or Busy |
| `spinner(ui, size, label, key)` | eight dots with a bright one going round; still under reduce-motion | Status named `label` (default "Loading"), Busy, polite |
| `badge(ui, label, tone, key)` | a small pill: `Tone` is `.Neutral`, `.Primary`, `.Success`, `.Warning` or `.Danger`, always readable on its tint | Text |

## Overlays

Overlays are built into the overlay root — a second top-level node over the
whole viewport, painted after the page and hit-tested before it — so any view
proc can open one from anywhere. Popover and dialog open state belongs to the
app: pass `open` and a `dismiss` message; the toolkit queues `dismiss` on an
outside press or Escape and the app flips its flag. Select owns its own open
state. All three enter/leave with a fade (instant under reduce-motion).

On a `.Layer` surface (a shell's bar), a popover, menu, submenu, select list,
context menu or tooltip opens on a surface of its own beside its anchor, so
it reaches past the bar: the compositor places it (flipping and sliding to
stay on the screen), a menu or popover opened by a click takes a grab and a
press anywhere else sends its `dismiss`. The view builds it exactly as in a
window.

| Builder | Behaviour | A11y |
|---|---|---|
| `popover(ui, anchor, open, dismiss: Msg, placement, min_width, glass, align) -> bool` | glass surface anchored to `anchor`'s rect; `.Below` (default) / `.Above` / `.Right` / `.Left`, flips at the viewport edge; `align` is where it sits along the anchor — `.Start` (default: its start with the anchor's), `.Center` (its middle over the anchor's: a dock's menu over its button) or `.End` — across it above or below, down it beside, and it slides back onto the screen near an edge, on a popup surface too; outside press (not on the anchor) or Escape queues `dismiss`; close the scope with `end`. **Inside its window its glass takes the worst case**: what shows through is whatever the app drew under it — a white page as easily as a dark one — and nothing measures that, so the tint rises until the text reads over anything and the secondary and accent colours are solved with it. On a popup surface of its own the compositor measures what is behind it and the thinner tint made for that is kept | Group |
| `select(ui, selected, options, on_change: Handler(Msg,int), placeholder, width, disabled, label, tag, key)` | trigger shows the option; click / Enter / Space open the list, starting at the selected option (highlighted when opened from the keyboard); Up/Down move on from it, Home / End go to the ends, Enter or click picks (index via `on_change`) and closes; outside press / Escape close; `width = 0` sizes the trigger (and its list) to the widest option at the text size in force, the desktop's large text included, so labels read in full without a width measured by eye — the widest option decides, so picking does not resize it, and it is capped at `SELECT_FIT_MAX`; otherwise the trigger is a box of `width` and an option too long for it is cut with "…" on one line rather than wrapping to a second, the whole of it on hover . Its list fits the window and scrolls, opening at the option in force | Combo_Box (Has_Popup; Expanded / Collapsed) → Menu of Menu_Items (Selected) |
| `dialog(ui, open, dismiss: Msg, title, width) -> bool` | scrim + centred card; focus moves in (to its `default` button when it has one) and Tab is trapped inside; scrim press or Escape queues `dismiss`; focus returns to the opener on close; close the scope with `end`; if the focused control goes away while it is open, its default button (else its first control) takes focus again. **`dismiss` is the safe answer, never the destructive one** — a scrim press and Escape mean "not now", and someone who clicks beside a dialog has chosen nothing; anything destructive belongs on a button inside it (a dismissal that discards a draft, or crash-recovered work the dialog offers back, is the easy mistake). **A press on the scrim does nothing** unless `dismiss_outside` is set: a dialog holding a form holds typed work, and a stray click beside it must not throw that away. Escape, Cancel and ✕ all still close it, so nothing becomes a trap. Set `dismiss_outside = true` for a dialog holding nothing worth keeping — a picture at full size, an about box. | Dialog (Modal), name = title |
| `menu(ui, anchor, open, dismiss: Msg, placement, min_width) -> bool` | popover that acts as a menu: opened from the keyboard its first item is highlighted; opened with the pointer nothing is until a key: the first Down highlights the first item, Up the last, and Enter acts only on the row the pointer rests on; Up/Down walk on from the highlighted item, Home / End go to the ends, Enter activates, Escape / outside press queue `dismiss`; focus returns to `anchor` on close (context menus, submenus and menu bar menus alike) | Menu |
| `menu_bar(ui, key)` + `menu_bar_menu(ui, title) -> bool` | the File / Edit / View strip; the bar owns which menu is open: click or Down / Enter / Space open, hovering another title switches, Left / Right move across titles and across open menus, F10 reaches the bar, Escape closes and returns focus to the title. Moving along the bar swaps the dropdown **at once** — no fade out of the one leaving, none in for the one arriving — as every desktop does it; opening the first and closing the last keep their transitions. Fill an open menu with `menu_item` / `separator` and close with `end` | Menu_Bar of Menu_Item titles (Has_Popup; Expanded / Collapsed), Menus of Menu_Items |
| `submenu(ui, label, icon, theme_icon, disabled, min_width) -> bool` | a menu row (`icon` or `theme_icon` before the label, as on a `menu_item`) with a chevron that opens a further menu beside it, first item level with the row: when the pointer rests on it, on click, Right, Enter or Space; Left or Escape inside it close it and focus returns to the row, the pointer resting on another row of the parent closes it too; an item activated inside closes the whole chain; nests; close with `end` only when it returns true | Menu_Item (Has_Popup; Expanded / Collapsed) whose popup is a Menu |
| `context_menu(ui, open, dismiss: Msg, min_width) -> bool` | a menu at the latest right-click / Menu-key / drop position (an Alt-drop's Copy here / Move here opens where it landed) (`Ui.context_pos`); pair with a table's or icon view's `on_context` | Menu |
| `menu_item(ui, label, on_click: Msg, shortcut, disabled, icon, theme_icon, checked: Maybe(bool), radio, tag, key)` | label left (a check mark or radio dot in a leading slot when `checked` is given; `icon`, or `theme_icon`: an icon theme name (`icon` standing in when no theme provides it) such as a jump-list action's Icon= or a dbusmenu icon-name, before it), shortcut hint right; activating queues `on_click` and the menu's `dismiss` | Menu_Item, name = label |
| `separator(ui, key)` | hairline between groups (horizontal in a column/menu, vertical in a row) | Separator |
| `tooltip(ui, anchor, text)` | shown 600 ms after the pointer rests on `anchor`, or while it has visible keyboard focus; hidden on leave, press, Escape | anchor's `describe` = text; the tip itself is role Tooltip |
| `live(ui, node, level: Live = .Polite)` | marks the node as a live region: a screen reader says what it holds out loud when that changes, although nothing took focus — a status line, "3 of 8 copied", an error raised elsewhere on the screen. `.Assertive` interrupts what is being spoken, `.Polite` waits its turn, `.Off` stops it. A toast, the drag announcement and the busy spinner are live already | `object:announcement` with its politeness whenever its name (or the first text in it) changes |

```odin
more := baldr.button(ui, "Actions…", Msg(Menu_Open{}), variant = .Outline)
baldr.tooltip(ui, more, "Rename, duplicate or delete the file")
if baldr.menu(ui, more, s.menu_open, Msg(Menu_Closed{})) {
	defer baldr.end(ui)
	baldr.menu_item(ui, "Rename", Msg(Rename{}), shortcut = "F2")
	baldr.separator(ui)
	baldr.menu_item(ui, "Delete…", Msg(Confirm{true}), shortcut = "Del")
}
if baldr.dialog(ui, s.confirm, Msg(Confirm{false}), title = "Delete this file?") {
	defer baldr.end(ui)
	baldr.text(ui, "The file is moved to the bin.")
	baldr.row(ui, gap = .sm, justify = .End); { defer baldr.end(ui)
		baldr.button(ui, "Cancel", Msg(Confirm{false}), variant = .Outline)
		baldr.button(ui, "Delete", Msg(Delete{}), variant = .Danger)
	}
}
```

## Editing in place

A label becomes a text field where it stands, the same way in a table
cell, an icon view tile and a tree item. The view asks the app to start
one through `on_edit` — on F2 for the cursor item, or a slow second click
on the one selected item (a double-click activates instead); a table
sends `Cell_Ref{row, col}`, an icon view the tile's index, a tree the
item's `tag`. The app then builds that cell with `cell_edit`, or gives
`icon_item` / `tree_item` an `on_submit`, and the field takes focus with
the name selected up to its extension. Enter or leaving the field
commits through `on_submit` (Ev.tag is the row or the item's tag), Escape
sends `on_cancel`, and in a table Tab commits and asks `on_edit` for the
next cell (Shift+Tab the previous), so a data table edits like a
spreadsheet. The app decides which cells may change and what a commit
does; a rename that fails just rebuilds with the old name.

**An icon tile's editor is a card over the tile**, because a
tile's label is ~120 px and the names people rename most are not: a
one-line field there showed a window of the name that scrolled with the
caret. It is **two tiles wide** (never wider than the view), centred on its
own tile, opaque and shadowed over its neighbours, and it **wraps** over as
many lines as the name needs, up to `INLINE_EDIT_LINES`, growing down over
the tiles below. Enter, Escape, Tab and leaving are the one-line editor's
keys exactly; a newline pasted into it commits as a space, since a name has
none. A table cell and a tree row keep the one-line field — a row is wide.

## Zoom

Ctrl + wheel over a node that asked for it sends the wheel travel (px,
positive to zoom in; a notch is 48) through `on_zoom`: tables and icon
views take `on_zoom` in their builders (row density, tile size — the
tile's icon and thumbnail scale with it), any other node through
`zoomable(ui, node, on_zoom)`. Ctrl++ and Ctrl+- are the app's
`shortcut`s. Touch pinch comes later.

## Hover

The pointer resting on a node that asked for it sends `true` through
`on_hover` once when it comes over the node or anything inside it, and
`false` once when it leaves, the pointer leaves the surface, or the node goes
away: `hoverable(ui, node, on_hover)` (a toast that waits while it is looked
at, a launcher row made current). Only the pointer moving counts: rows
scrolling or rebuilding under a still pointer send nothing, so keys walking
a list keep working.

## Keyboard shortcuts

`shortcut(ui, "Ctrl+Shift+N", msg)` binds a key combination for the window
while the view declares it. A key the focused widget uses (Delete in a text
field, Ctrl+C in an editor) stays with the widget, and so does a character
being typed: a binding on a printable key with no Ctrl, Alt or Super ("/",
"R", "Shift+/") waits while the focus is a text field, an editable text
area, a time picker taking digits or a view with type-ahead. Nothing fires
under a modal dialog. An app's binding also wins over the keyboard drag's
Ctrl+X pick-up, so a file view whose app binds Cut and Paste to Ctrl+X /
Ctrl+V cuts and pastes; a view whose app binds none keeps keyboard drag.
A binding on Space wins the same way over the Space a table, icon view or
tree uses for its selection (Space for Quick Look); Ctrl+Space still toggles.

**Ctrl+Shift+C / X / V / A / Y go to the app that binds them**, over the
editor, field, markdown view, styled text or selection scope that has the
keyboard: those five widgets treat Ctrl+C the same with or without Shift,
so holding Shift asks them for nothing they do not already do, and an
editor that binds Ctrl+Shift+C to "Copy as Formatted Text" (`copy_html`)
would otherwise copy plain text and never see the key. Bind none and Shift
stays ignored, exactly as before. The chords a text widget *does* use with
Shift held stay its own however they are bound — Ctrl+Shift+Z is Redo and
Ctrl+Shift+Left selects a word, as plain Shift+Home is a selection and
never a command.
**A binding on Enter wins over the Enter those three views use to activate**
— so a file manager's Alt+Enter is Properties rather than Open (request
179) — and a view with no `on_activate` leaves Enter alone altogether, so
it reaches the window's shortcuts and a dialog's default button. In a
**field** the same holds for a *modified* Enter, while a plain
one stays `on_submit`'s: committing what has been typed is the field's own
key, and a dialog must submit however sloppily Enter was pressed.
An arrow, Home, End or Page key held with Alt or Super goes past a focused
view or control (table, icon view, tree, slider, radio group, calendar,
time picker, split) to the window, so Alt+Left / Alt+Up can be Back and Up;
text editing keeps its own.
**A binding on Page Up, Page Down, Home or End beats a scroll the pointer
is merely resting over** — a reader that binds Page Down to
turn the page turns it wherever the pointer is, instead of scrolling the
sidebar the pointer was left over. A scroll the keyboard is *inside* keeps
those keys, so a list or an editor being read with them is unaffected.
A key held with Ctrl, Alt or Super types nothing into a focused field, so
"Ctrl+1" never adds a 1; AltGr still types. Modifiers are Ctrl, Shift, Alt and Super (Cmd / Meta / Win);
keys are letters, digits, F1–F12, arrows and names such as Delete, Enter,
Escape, Space, Home, Page_Up, Comma; "Ctrl++" is the plus key. A string
that does not parse is a build diagnostic. A menu item's `shortcut` shows
the hint; `shortcut(ui, …)` is what makes it work.

Keys are letters, digits, F1–F24, arrows, the media and system keys a
laptop has (`"Volume_Up"`, `"Media_Play"`, `"Brightness_Down"`, `"Print"`)
and names such as Delete, Enter, Escape, Space, Home, Page_Up, Comma. The
keypad arrives as the key it doubles — KP_1 as N1, KP_Enter as Enter — so a
widget sees one of each.

`menu_item(…, checked = true)` shows a check mark (a dot with `radio =
true`) in a leading slot and sets the Checked state; give the plain items
of such a menu `checked = false` so their labels line up.

### Asking what was pressed

`key_capture(ui, on, handler)` is the other direction: while a view declares
it, every press comes to the handler as a `Chord` instead of reaching the
focused widget or the window's shortcuts. A `Chord` carries the portable
`key`, the platform's own `keysym` name (`"q"`, `"comma"`,
`"XF86AudioPlay"` — what a compositor's configuration file is written in),
the `mods`, and `held`, true while only modifiers are down so a field can
show "Super+…" as the chord forms. `chord_text(chord)` writes it the way a
person reads it. Escape arrives like any other key: a capture that should be
cancellable does that itself, and nothing is captured under a modal dialog.

While it listens, the desktop is asked to stop acting on its own shortcuts
(`keyboard-shortcuts-inhibit-unstable-v1` on Wayland), so Super+Q reaches
the app instead of closing the window — without which the chords most worth
rebinding could not be captured at all. `inhibit_shortcuts(ui, on)` is that
alone, for a remote desktop, a virtual machine or a game passing keys to a
guest. The desktop decides: one without the protocol keeps its shortcuts,
and one with it usually keeps an escape hatch so a window cannot hold the
keyboard. `examples/20_shortcuts` is a shortcut editor built on both.

**Keeping the screen on.** `keep_awake(ui, on)` is declared from the view
the same way, by whatever is playing: while it is set the desktop is asked
not to dim, blank or lock the screen (`idle-inhibit-unstable-v1` on Wayland,
`SetThreadExecutionState` on Windows; nothing on X11 yet). It is for
watching rather than doing — a video or a slideshow playing, a presentation,
a recipe left open across the room — and not for work going on in the
background, which wants the *system* kept awake and is a different ask. A
build that stops asking gives the screen back, so a player need only set it
while it is actually playing. The desktop decides: one without the protocol
dims as it always did, and a compositor is entitled to require the window to
be visible, so a paused and hidden player cannot hold the screen on however
hard it asks. `spikes/keep_awake` is the live check.

## Motion and effects

**The theme a surface paints with is not the one you handed it.** On glass,
each surface adapts its own copy to what the compositor reports is behind
it: the tint thickens until the text reads, the text may take the other
family's colours, and the washes — `fill`, `fill_strong`, and the hover and
press layers — are re-solved so they are worth on that backdrop what they
are worth on an opaque window. So read colours from `ui.theme` inside
`view`, never from a theme the app built at start-up and kept: the two are
the same until a surface adapts, and then they are not, which shows up as
one control answering the pointer and its neighbour not.

**Text drawn straight on the desktop** is the same question with no glass
to answer it, and there the app decides. A surface with
`backdrop = .Measure` asks the compositor how bright what is behind it is
without asking for a blur — a readout on the wallpaper has nothing to blur
behind it, and a blur would hide exactly the contrast that decides whether
a letter reads. `backdrop_range(ui)` is the answer in the view (and whether
one has come at all), and `legible_ink(range, preferred, contrast)` turns
it into the colour and the halo to draw with: the preferred colour where it
reads over the darkest, the brightest and the average of what is behind;
failing that the same colour moved lighter or darker, whichever moves less,
keeping its hue; and only where no single colour reads — a photograph that
runs from a dark hedge to a bright sky under one line — the colour nearest
it that reads over the average, with a halo on the far side of that average
(`legible_halo_over`). The halo's tone follows **the backdrop**, not the
ink: it is there to carry the text over the parts the ink does not read
against, so a light ink over a dark photograph takes a *dark* halo although
the ink is dark in absolute terms. `set_glow(t, n, glow)` puts that halo on
a text or icon node (`{}` takes it off). It is the same halo an icon view's
labels wear over a wallpaper (`Label_Over.Anything`), which has to wear it
blind — `legible_halo(ink)` is that blind rule, and picks whichever tone
stands off the ink. `examples/36_desk_text`
is a corner of readouts that follows the wallpaper under it.

**What the binary carries.** `notices()` is what this build embeds that its
licence asks be passed on — `Notice{name, use, licence, text}`, with the
notice in full rather than a summary of it. Every Baldr binary carries Inter
and JetBrains Mono (SIL OFL 1.1) and Twemoji Mozilla (CC-BY 4.0), because
`#load` puts the bytes in whether the app draws with them or not, so an app
shipped on an installer or a `.deb` must carry those notices with it. It
follows the `#config` choices: swap the UI face with
`-define:BALDR_UI_FONT=…` and the notice says that face is the app's own to
account for rather than handing over Inter's licence for a font that is not
there. `notices_text()` is all of them as one block, for writing a LICENCES
file at build time. The strings are static — nothing to free.

**Fonts an app chooses.** `text_family(ui.tree.text, "EB Garamond")` gives a
`Family_Id` for a family this machine has, and `text_family_bytes(ui.tree.text,
"Wordmark", REGULAR, BOLD)` one from bytes the app carries — the face a design
asks for that a machine will not have. `text(…, family = id)` draws in it, and
`text(…, mono = true)` in the code face without naming anything. A family's
regular face stands in for the ones it was not given, and the toolkit's own
fonts stay behind it for what it lacks — emoji, CJK, symbols — so nothing
falls out of the page. The bytes are copied (`#load`ed data works), and they
must be TrueType or OpenType: a `.woff2` wants a Brotli decompressor, which
the dependency rule does not allow, so convert it when the app is built.
`text_family_ok(te, id)` says whether it loaded; a family that did not comes
back as 0 and the theme's fonts draw.

**Themes and the desktop.** `set_theme(&ui.tree, th)` gives a window a theme
of the app's own; the desktop's reduce motion, reduce transparency and text
size are folded into it (and into Baldr's own theme) and stay current, and
the desktop's light / dark changes leave it alone. `follow_system_theme(&ui.tree)`
gives it back to the desktop: it is the third choice an appearance setting
has — Light, Dark, **System** — and without it the first two were one-way
until the app restarted. `App.adjust_theme` runs over a set theme as over
every other, so an app's own type scale or radii survive someone picking
Light without the app calling its adjust proc by hand. The text size is GNOME's
text-scaling factor or the Windows text-size setting: every role in the type
scale is drawn that much larger, as is any size an app sets itself
(`text(…, size = 18)`, `editor_options(…, size = 18)`), so a reader who asks
for large text gets it everywhere; it is clamped to 0.5–3×, and icons and
spacing keep their own sizes, as they do on those desktops.
`BALDR_TEXT_SCALE=1.5` sets it for testing.

**Component styles and density.** Each widget kind has a style on the
theme: `th.button`, `th.field`, `th.list_row`, `th.menu` and the rest, 25 in
all. Every field is a `Maybe` that follows the global tokens when left alone.
`th.density` makes every control's height 4 px shorter (−1) or taller (+1)
a step. A subtree can take a theme of its own through `theme_area`. The
desktop's own colour scheme is followed where it has one: KDE's, or a
Windows contrast theme in the person's colours. The guide's *Theming*
section has the examples.

**A theme's own faces and target size.** Each step of the
type scale may name a family of its own, `th.type.title.family =
"Space Grotesk"`, for a design whose headings (`display`, `headline`,
`title`) or controls' labels (`label`: buttons, tabs, chips, segmented and
menu-bar labels, table headers, breadcrumbs, tooltips) are set in a display
face over body text in another. Name it as `font_family` is named — a
family this machine has, or one registered with `text_family_bytes` under
that name, before or after the theme names it — and set it in
`App.adjust_theme` so it survives a Light/Dark switch; one that cannot be
found draws as `font_family`. Body text, fields and editors follow
`font_family` itself. `th.min_target = 44` makes every control that takes
a click or the keyboard at least that big across and down, with a mouse as
much as with a finger: buttons and icon buttons, checkboxes, sliders,
fields, selects, tabs, menu items, list and tree rows. The control grows
with its content centred (a `clickable` text too: its line sits in the
middle of the height it grew to), a `width` or `height` the app fixed is
kept, and what takes no click keeps its size; 0, the default, is the toolkit's own
sizes. A touchscreen still makes controls 44 tall by itself.

Glass follows the compositor
too: a window goes opaque when blur stops being offered, and back. Glass
has three levels, `theme.glass = .Clear / .Frosted / .Solid`, one setting
for every theme; where the compositor says how bright it is behind a glass
surface, its tint and text colours follow so text keeps 4.5:1. A
disabled control shows no hover or press, and its text, icons and pictures
draw dimmed, whichever widget it is.

**Where a row below says "the accent", it means one of two colours.**
`theme.color.primary` is the accent as a **fill** — a selection, a
switched-on toggle, a Primary button, a progress bar, a tab's indicator, a
focus ring. `theme.color.accent_text` is the accent as **ink** — a Ghost
button's label and icon, a breadcrumb's current place, a link, an unread
count, a marked row's glyph, a tree row's expander. They are the same colour
in every theme the toolkit generates, so the distinction costs an app
nothing; it exists for a style whose accent reads well as a fill and badly as
text, which a mid grey does. A `Theme_Palette` sets `accent_text` to split
them, and left unset it is the fill lifted to 4.5:1 on the view, so ink is
readable whatever the accent is.

| Proc | Notes |
|---|---|
| `transition(ui, node, enter, exit, duration_ms, easing)` | `.Fade`, `.Fade_Up`, `.Fade_Down`, `.Fade_Scale`; exiting nodes fade before removal; `easing` `.Ease_Out` (default), `.Ease_In_Out`, `.Spring`; instant under reduce-motion; a node's fill, border, shadow and glass fade with it, except an overlay's — a popover, menu, select's list or dialog is whole from its first frame to its last and only what is on it fades, so the controls it opens over never read through it (`Transition.whole`) |
| `column / row / wrap(…, animate = true)` or `animate_moves(ui, node)` | children glide to their new positions when a rebuild moves them (paint-time shift; never on a window resize) |
| smooth scrolling | keyboard jumps, focus-into-view and table / icon-view reveals ease into place (`scroll_to_smooth`); wheel, drag and fling take over instantly |
| checkbox | the box fills and the tick draws in; tab panels fade in when switched to |
| hover / press / focus | eased automatically over `theme.motion.fast`; nothing to write |
| glass | `card(glass = true)`, `popover(…, glass = true)` (the default) or `material =` on column/row; `theme.glass` Clear (a glow behind text and icons), Frosted (default) or Solid (opaque under reduce transparency and high contrast); a glass popup inside its window — menu, context menu, popover, select's list — is built and painted in a theme solved for the worst case, because the app's own content is under it and nobody measures it, while a `card` keeps the 0.55 tint floor; a bright top edge on bars, popovers and sheets, and on a popover a 1 px edge and a drop shadow that leaves the see-through card clear. The theme's `fill` and `fill_strong`, the edge and the rim are the design's tokens converted for linear-light blending, so on glass they separate as the design shows in every mode |

## The node door

`Custom_Kind{size, paint, paint_over, user, overhang}` makes a node that
paints itself (`paint` appends draw commands after the node's own
background, before its children; `paint_over` after the children, for guides
and indicators; `t.paint_opacity` is the inherited transition opacity;
`overhang` is how far outside its rect it may draw, so damage tracking
repaints that too). Nodes without a fixed
`size` lay out their children like a box. Toggle, slider and tabs are built
on it; app widgets can be too. `mount` / `update` / `set_*` for imperative use
are planned.

### A window that takes the screen

`Surface_Desc.fullscreen` asks the desktop for the whole screen, and
`ui.surface.fullscreen` says what it did — a request and its answer, which
are not the same thing: a compositor may refuse (a tiling layout, a locked
session, another window already full screen on that output). Build from the
answer. `ui.surface.maximized` reads back the same way. Asking is live, a
window is not reopened for it, and only a window asks — a layer surface is
placed by the desktop already.

```odin
surfaces :: proc(s: ^State, out: ^[dynamic]baldr.Surface_Desc(Msg)) {
	append(out, baldr.Surface_Desc(Msg){tag = 1, kind = .Window, title = "Reading", fullscreen = s.reading})
}
view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	if !ui.surface.fullscreen do toolbar(ui) // …only when it is not the whole screen
}
```

**A window sized by its app.** `Surface_Desc.size` is watched after the
window opens, not only when it is made: a player that fits its window to the
film it has just loaded declares the new size and the next frame is drawn at
it. Declare it *once*, when the app knows the size — the person's own
resizing afterwards is theirs, and nothing asks again until the declaration
changes. While the desktop is sizing the window (maximised, full screen or
tiled) the size is **dropped rather than remembered**, so unmaximising never
makes a window jump to something asked for minutes ago; an app that still
wants it hears the change in `on_state` and can ask again. What is asked for
is kept to the screen the window is on, which saves the app looking itself
up in `outputs()` first.

## Charts

`chart(ui, series, kind = .Line)` draws `[]Chart_Series` as a line, an area,
bars or a scatter; a series may carry its own `kind`, so bars with a line over
them is one call. `x_labels` names the categories along the bottom, label
i at x = i. Bars stand on their x, so a missing category is a gap and series
of different lengths line up; the pointer reads the bar it is over, and with
several series the readout names it. `y_min` /
`y_max` pin the value axis where the data alone would mislead, and
`on_select` hears the point a reader picked — by pointer or by key — as a
`Chart_Hit`. `x_min` / `x_max` pin the bottom axis too, for a history shown
against a moving window of time: a series with only its latest readings is
drawn from where it starts, with nothing before it (no zeros padding it
out). `x_grid` draws a vertical grid line at every multiple of it along x,
at fixed values, so the grid scrolls as the window moves and a steady value
still reads as live. `chart_color(th, i)` is the colour the chart gives
series `i`, for a mark elsewhere that stands for the same thing (a
sidebar's sparkline).

The axis ticks land on round numbers and are written the way the desktop
writes numbers (its decimal mark, its thousands separator). Bars and areas
always include zero: both are read as quantities, and an axis that starts at
20 draws four fifths of a quantity that is not there. There is no second
vertical axis — two measures of different size are two charts, or one indexed
to a common base.

Identity never rests on colour: two or more series carry a legend, a scatter's
series take a marker shape as well as a slot colour, and each series is in the
accessibility tree with its own summary ("Sales, 12 points, 31.2 to 79.4,
ending 61.5"). The chart takes focus; Left and Right walk the points, Up and
Down change series, Home and End go to the ends, Enter picks, and whatever the
cursor is on is read out as it moves. The series palette is fixed, in a fixed
order, and measured for colour-blind separation on both surfaces rather than
derived from the app's theme — `baldr/chart_palette.odin` has the numbers.

`sparkline(ui, values, width = 64, height = 28, color, fill, y_min, y_max,
span, label)` is a value's recent history as nothing but its line, beside
the number it shows (a Task Manager's sidebar, a list row). It is not a small
chart: a chart is read, a sparkline is taken in at a glance next to an exact
number, so it has no axes, legend or readout and takes no focus. Values go
oldest first; `span` is how many the width holds, so a history still filling
up grows in from the right, and past it only the latest show, scaled to what
shows. `y_min` / `y_max` pin the scale (0–100 for a percentage); otherwise it
runs from 0 (or the lowest value below it) to the highest. `color` is the
line's (`{}`: the accent), `fill` shades under it, and the stroke stays inside
the box at its peaks. It is decorative, since the number beside it is what is
read; with a `label` it is an Image named that, described by its range and
latest value.

## Node graphs

`graph(ui, nodes, wires)` draws `[]Graph_Node` — boxes with input and output
ports — and `[]Graph_Wire` between them, on a canvas that pans and zooms. The
app owns the graph: it passes what it has and hears what the reader did
through one `on_event` (`Graph_Moved`, `Graph_Connected`, `Graph_Cut`,
`Graph_Selected`, `Graph_Activated`, `Graph_Deleted`). The widget owns only
the pan and the zoom.

Pointer: drag a node to move it, drag from one port to another to wire them
(either direction — an input to an output is the same connection), click a
wire to cut it, drag the background to pan, Ctrl + wheel to zoom about the
pointer. Keyboard: Tab walks the nodes, an arrow goes to the nearest node in
that direction, Shift with an arrow moves the node, Ctrl with one pans, Ctrl
+ and Ctrl - zoom, Ctrl 0 resets the view, Enter opens a node and Delete asks
for it to go. The canvas pans to keep the keyboard's node on screen.

Every node is an object in the accessibility tree, lying over the box it
stands for and named with its connections ("Amplifier, 1 in, 1 out, from
Microphone, to Speakers"), so a reader can walk a graph it cannot see.

A node's `inputs` and `outputs` are borrowed for the build that passes them,
as a text's string is: keep them in the app's state, not in a slice literal
inside a procedure that returns before the view runs.

## A window's own frame

For a window the desktop is not decorating (`Surface_Desc.undecorated`),
`window_chrome(ui, title)` opens a title bar and leaves it open — it is a
row, so the app builds its own controls into it — and `window_buttons(ui,
on_close = …)` puts the window's minimise, maximise and close where the
desktop wants them: at the end, or before the title. Close it with `end` as
any other container.

```odin
baldr.window_chrome(ui, "Notes"); {
	defer baldr.end(ui)
	tabs(ui, s)                                    // the app's own
	baldr.window_buttons(ui, on_close = Msg(Quit{}))    // …and the window's
}
```

Both take an `ink` colour for a bar that is part of a page the app chose —
a sticky note's yellow paper, where the theme's near-white title would
vanish — and it covers the title and the window's own buttons. Like an
editor's ink it stays until changed, and passing nothing keeps the theme's.

Dragging the bar moves the window, a double click maximises or restores it,
a right click opens the desktop's own window menu. The buttons are focusable
and named, so the keyboard reaches them. `on_close` is the app's message, for
a document that wants to ask before it goes; without one the window closes
the way the desktop's own close button closes it.

The bar follows the desktop's choices for a title bar, as the desktop's own
title bars do (`Titlebar_Prefs`):

| Choice | Values |
|---|---|
| `button_layout` | GNOME's button-layout: the buttons before the colon on the left, those after it on the right, in that order. `"close,minimize,maximize:"` is the Mac's; `":minimize,maximize,close"` (and `""`) the usual. A button left out isn't shown, except close, which always is; `window_buttons`' `buttons` (a dialog's `{.Close}`) limit them further |
| `double_click` | `Maximize` (maximise or restore; the usual), `Minimize`, `Roll_Up` (up to the bar, or back down), `Menu` (the desktop's window menu), `None` (the second press only drags) |
| `wheel` | `None` (the usual), or `Roll_Up`: up over the bar rolls the window up, down brings it back, as XFCE has it; a touchpad's small steps add up to a notch |

With nothing said, a window follows the desktop's own (GNOME's
`button-layout` and `action-double-click-titlebar`, read through the
Settings portal and followed as they change). An app that owns these
settings — the compositor's read from compositor.conf — passes them in
`App.titlebar`, and `set_titlebar_prefs(&ui.tree, p)` (before the bar is
built) when they change; `titlebar_action_of(word)` reads a double-click
action as GNOME and the reference compositor write it.

Rolled up, the window shrinks to its bar (a floating window chooses its own
size), and keeps its size to come back to. It is laid out at that size
still, so nothing in it moves and no view switches layout; what is below the
bar is inert until it comes back — out of reach of the pointer, the keyboard
and assistive technology — and the keyboard, if it was down there, waits on
the bar's first control and returns after. The bar reads Collapsed to a
screen reader meanwhile, and `ui.surface.rolled` says so to the view. A
maximised, full-screen or tiled window (`ui.surface.tiled`) never rolls up;
maximising a rolled-up one brings it down first, and one the desktop
maximises while rolled comes back at its own size, not its bar's. A menu
opened from the bar while rolled up is cut to the bar, as a window's menus
open inside it.

An undecorated window also takes the pointer near its own borders to resize,
with the matching cursor. A compositor may claim those borders itself
(the reference compositor does), in which case the compositor resizes the window and the
client's edges never fire — both are correct.

## Your own widgets

| Builder | Notes | Accessibility |
|---|---|---|
| `custom(ui, paint, user, measure, width, height, flex, label, role, focusable, keys, on_key, tag, key)` | a node that sizes and paints itself: `paint` gets a `Painter` (`rect`, `theme`, `user`, `hovered`, `pressed`, `focused`, `disabled`) and draws with `draw_rect`, `draw_circle`, `draw_line`, `draw_polyline`, `draw_arc`, `draw_bezier`, `draw_icon`, `draw_text` (the string is copied), `draw_text_size`, `draw_clip` / `draw_unclip`; `measure` answers for the room offered, else `width` / `height` / `flex`. It repaints whenever it is built. While focused, `on_key` hears the `keys` it names and every other key goes on to the window. Pointer input through `clickable`, `pointer_area`, `pointer_track`, `hoverable`, `draggable`, `drop_target`. `examples/37_custom` | the `role` and `label` given (a focusable one with no role is a Group); `set_describe` for its value |

## What the desktop has to support

Nearly all of Baldr needs a window and nothing else: every widget, every
layout, drag and drop, the clipboard, dialogs, notifications and the
accessibility tree work the same on any Wayland compositor and on Windows.
A short list of calls asks for more than a window, and this is what each
one needs and what it does where it is not there.

Nothing here has to be asked about before it is called. There is no
`caps()` to branch on, on purpose: each of these degrades to something
sensible and says so through its ordinary answer — the list comes back
empty, the command does nothing, `on_finished` arrives, the slot reports
no token. An app writes the call once and reads the answer.

**Standard, and widely implemented.** These are freedesktop protocols that
wlroots compositors (sway, hyprland, river, the reference compositor), GNOME and KDE
answer — a panel written against them is not tied to one compositor.

| call | needs | where absent |
|---|---|---|
| `Surface_Desc{kind = .Layer, …}` | `wlr-layer-shell` | an undecorated window |
| `lock_session` / `unlock_session` | `ext-session-lock-v1` | `on_finished` at once; no lock surface is ever stood in for by a window |
| `toplevels()`, `toplevels_changed`, `toplevel_activate` and the rest | `wlr-foreign-toplevel-management` | the list is empty, the commands do nothing |
| `workspaces()`, `workspaces_changed`, `workspace_activate`, `workspace_assign` | `ext-workspace` | the list is empty, the commands do nothing |
| `Surface_Desc{backdrop = .Blur}` | `ext-background-effect` | the surface is drawn without blur, and `reduce_transparency` turns it opaque anyway |
| `Surface_Desc{backdrop = .Measure}`, `backdrop_range` | `rikkiti-backdrop-v1` (see below) | no numbers: `backdrop_range` answers `false`, and a view draws what it would have drawn anyway |
| `outputs()`, `outputs_changed` | `xdg-output` (Wayland); nothing in particular on Windows | always answers. One caveat, below: `pos` is in the desktop's own coordinates, and Windows' are device pixels |

**One compositor's own.** Two protocols in the tree are specific to a single compositor — their wire names say so
(`platform/wayland/wl/gen_rikkiti_applet_v1.odin`,
`gen_rikkiti_backdrop_v1.odin`). The *API* over them is not: `applet_slot`
means "a bar's place for another program's applet", which any compositor
could implement, in the same way `notify` is not a GNOME call because
GNOME's daemon answers it.

| call | needs | where absent |
|---|---|---|
| `applet_slot` | `rikkiti-applet-v1` | an empty place of the size asked for, reporting nothing — no token, so the bar never starts an applet |
| `Surface_Desc{backdrop = .Blur}` on a shell surface, luminance-tuned | `rikkiti-backdrop-v1` | plain blur, or none |
| `Surface_Desc{backdrop = .Measure}` + `backdrop_range`, for text on the desktop | `rikkiti-backdrop-v1` **version 2** (`measure_as_shown`: the numbers unblurred) | version 1 reports them blurred, which still says roughly how bright the wallpaper is; no protocol at all and `backdrop_range` says `false` |

**Everything else in the toolkit** needs none of this. A desktop
application never touches the two tables above.

**`Output.pos` is in the desktop's own coordinate space, and the platforms
differ.** Wayland lays the desktop out in logical pixels, so `pos` + `size`
is a screen's rectangle there. Windows lays it out in device pixels and has
no logical desktop plane at all — dragging a window between screens of
different DPI rescales the window rather than moving it through one — so on
Windows a screen's rectangle is `pos` + `mode_px`. Every field still means
what it says: `size` is always that screen's logical size (`mode_px` /
`scale`). The two agree wherever every screen is at 100%, which is most
machines, and an app that only asks "which screen is this, and how big is
it" never meets the difference. `refresh` is also coarser on Windows, which
keeps whole hertz: a 59.94 Hz panel reports 60000 mHz there and 59940 on
Wayland.

**On Windows** the whole of both tables is absent: the lists are empty,
layer surfaces are plain undecorated windows, and the lock and applet calls
answer that they cannot. That is the contract, not a gap to be filled — a
Baldr app that also wants to be a Linux shell asks for these and gets a
window on a platform with no shell to speak of. **On macOS** it is the same,
and by design. **On X11** likewise: these stay nil, because X11's equivalents
belong to a window manager rather than to an application.

## Accessibility contract

Every interactive builder sets a role and name (the debug lint reports
missing names and too-transparent glass tints), is reachable with Tab and
activated with Enter/Space, shows a focus ring after keyboard navigation, and
respects the OS reduce-motion and reduce-transparency settings.

On a Linux desktop that has an accessibility bus, that tree is served to
screen readers over AT-SPI2 with no work from the app: the window and its
widgets with their roles, names, descriptions, states and extents; an entry
or editor's text, caret and selection; a slider's value and step; and the
events a reader follows — focus, the caret, text inserted and deleted, a
value, a name, the states a control changes about itself, and children
arriving or leaving. A reader can also act: press a button, move the focus,
move a caret. The app sets `label`, `describe` and the state flags; the
bridge does the rest.

A reader can also type: inserting, deleting, replacing or setting the text
of a field or an editor, and cutting, copying and pasting, all through the
widget's own editing path — so a reader's edit is an undo step like any
other and the app hears it as ordinary typing. A read-only editor reports
its text and says it cannot be typed into. Selecting a child of a list is
mapped to what clicking it does; deselecting and clearing are refused,
because nothing in the toolkit knows what an app means by them.

It costs nothing where nothing is listening — with no accessibility bus the
bridge never starts — and only what is being read where something is:
objects a reader has asked about are watched for changes, a few per
wake-up. `BALDR_A11Y=0` turns it off; `BALDR_A11Y_DEBUG=1` prints what it
registered as and every question it answers. The gaps that remain are narrow: deselecting or clearing a
selection from outside, which nothing in the toolkit can give a meaning to.
