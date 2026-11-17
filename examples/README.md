# Examples

Each example is one small program, and each one builds and runs with a
single command from the repository's root:

```bash
./build.sh example 01_hello run
```

On Windows, from `cmd` or PowerShell, it is plain Odin commands instead
(see the README's [Getting started](../README.md#getting-started)). Odin
does not create the output folder, so make it once:

```bat
mkdir build
odin build examples\01_hello -collection:baldr=. -out:build\01_hello.exe -debug
build\01_hello.exe
```

Every example's first comment says what it shows and how to drive it.

## Where to start

Read them in this order and you have met most of what an app is made of:

1. **`01_hello`**: the whole shape of an app in 50 lines, with a `State`, a
   `Msg`, `update` and `view`.
2. **`04_controls`**: values bound to state, and every change coming back
   as a message.
3. **`05_overlays`**: menus, selects, tooltips and a modal dialog, and
   which of them keep their own open state.
4. **`10_files`**: effects from `update`, such as reading and writing a
   file, a timer, a delay and a file watch, with nothing waiting on the disk.
5. **`09_jobs`**: work on threads that reports progress as messages and
   can be cancelled.
6. **`00_gallery`**: the gallery, with most of the widgets on its first
   page and every theme a click away. Use it to find the widget you need, then read
   its row in [`docs/widgets.md`](../docs/widgets.md).

## All of them

### The basics

| | |
|---|---|
| `00_gallery` | the gallery: most widgets on one page, the larger ones on their own tabs, and switchable themes |
| `00_headless` | the toolkit with no window: build a view, lay it out, paint it, and print the draw lists and the accessibility tree. This is how the test suite works |
| `01_hello` | the counter |
| `02_theme_lab` | themes and typefaces side by side: every button variant, chips, a field, the focus ring |
| `03_scroll` | a scrolling list with the overlay scroll bar: wheel, trackpad, thumb, track |
| `04_controls` | checkbox, toggle and slider bound to state |
| `05_overlays` | select, menu, tooltips, a clickable card, a modal dialog |
| `15_control_centre` | a Control Centre's tiles: round icon toggles, large sliders whose icon follows the value |
| `09_jobs` | background work on threads, with progress and cancel |
| `10_files` | a note kept in a file: read, write, watch, a timer and a delay |
| `11_theme_icons` | icons from the desktop's icon theme, by name, loaded off the UI thread |
| `20_shortcuts` | rebinding a shortcut by pressing it, including keys the desktop would normally take |
| `23_chrome` | a window that draws its own title bar and still does everything a real one does |
| `37_custom` | a widget of your own: a star rating drawn from scratch with `custom`, with hover preview, click, keys and its accessible name |
| `38_windows` | two windows from one state: a Preferences window that belongs to the main one (`parent`), opened and closed by messages |

### Text and editing

| | |
|---|---|
| `07_code` | the code editor: line numbers, syntax colour, bracket matching, find, go to line |
| `08_rich` | the rich-text editor, with markdown in and out |
| `19_markdown` | a live-preview markdown editor with the app's own toolbar |
| `25_terminal` | a terminal's screen (no pty): colours, styles, box drawing, emoji, CJK, a prompt |
| `26_reply` | a read-only markdown view that streams in a few characters at a time |
| `27_conversation` | one selection across several messages, copied in order |
| `29_styled_text` | chat bubbles whose text the app styled itself |
| `31_emoji` | the emoji picker in a popover, with recents and skin tone kept by the app |
| `32_chat` | a chat that follows its newest message: rows of different heights, stable keys |
| `33_reading` | a page in its own colours (Paper, Sepia, Night), its controls included |
| `34_mentions` | a field whose `@` offers completions |

### Drawing, data and pictures

| | |
|---|---|
| `21_charts` | line, area, bar and scatter charts, readable by keyboard and screen reader |
| `22_graph` | a node graph: drag, wire, pan and zoom, all of it from the keyboard too |
| `28_lines` | lines over a picture: marching ants, a rotated transform box, a crop frame, guides, the pixel grid |
| `24_desktop` | an icon grid that keeps each icon where it was put |
| `35_spring` | spring-loaded folders: hold a drag over a folder and it opens |
| `30_audio` | a voice memo: record, watch the level, play back (`baldr:audio`) |

### Desktop-shell surfaces

These are what a desktop shell is made of: bars, docks, launchers,
applets. They use the Wayland layer-shell and the reference compositor's
own protocols, so they show at their best on a compositor that offers
them. Elsewhere a layer surface opens as an ordinary undecorated window
and an applet asks and is told no, so they still run.

| | |
|---|---|
| `06_panel` | a top bar that reserves its space, with popups and a launcher |
| `12_applet` | a clock that runs inside another program's bar |
| `13_taskbar` | the open windows and workspaces, and the buttons that act on them |
| `14_bar_applets` | a bar that hosts `12_applet` in a slot, as a separate process |
| `16_launcher` | a search launcher over a blurred desktop |
| `17_toasts` | glass notification cards on one surface |
| `18_dock` | a dock that hides at the screen's edge and magnifies under the pointer |
| `36_desk_text` | readouts drawn on the wallpaper, in an ink that follows what is behind them |

## Building them all

```bash
./build.sh examples     # every example, in a couple of minutes
```
