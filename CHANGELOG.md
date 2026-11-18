# Changelog

Baldr follows [semantic versioning](https://semver.org). Until 1.0, a minor
version may break the API; every break is listed here.

## Unreleased

### Added

- `italic` on `text` and `button_options`.
- `muted` on `tree_item`: muted ink, otherwise an ordinary row.
- `tag` on `open_files`, `save_file` and `split`, returned as the `Ev`'s tag.
- Completion that answers later: `editor_complete(on_ask, open_on)` sends a
  `Complete_Ask`, and `editor_completions` passes the answer back. Stale
  answers are dropped; the last one narrows as you type.
- `on_word_click` on `code_editor`: Ctrl+click (Cmd+click on macOS) on a
  word, with the word underlined while the key is held.
- The caret follows the desktop's blink settings (GNOME, Windows):
  `A11y_Prefs` gains `steady_caret`, `caret_blink_ms` and
  `caret_blink_timeout_ms`.

### Changed

- A caret stops blinking, shown, after 10 seconds without input, and stays
  steady under reduced motion. A blink repaints only the caret.
- A file dialog's `Ev.tag` is the command's `tag` (0 by default), where it
  was an internal token.
- On macOS a rich editor's link follows on Cmd+click, as well as Ctrl+click.
- Chart bars are placed by their x, not their index: a missing category
  leaves a gap, series of different lengths line up, and labels sit under
  their bars.

### Fixed

- A chart rebuilt with unchanged data drew its labels from freed memory.
- A node graph drew its titles from freed memory, did not repaint when its
  nodes changed, and leaked its ports on every build.
- With several bar series, the pointer reads the bar it is over, not always
  the first; the readout names the series.
- A click on a completion row puts it in, as Enter does; it closed the list
  and took the keyboard out of the editor.
- A closing modal dialog no longer takes focus back from where the app put
  it.
- `set_focus` on an editor's builder node focuses its text, where it did
  nothing; `BALDR_DEBUG_EVENTS` reports a refused `set_focus`.
- Editors no longer take the window's chords: their Ctrl+letter commands
  need Ctrl alone (so Ctrl+Shift+F reaches the window), and Alt or Super with
  an arrow goes to the window from fields and editors, except on macOS.

## 0.1.0 — 2026-11-17

The first public release.

### Added

- **The app model.** One `State`, one `Msg`, an `update` and a `view`, built
  with scoped builders. The view runs after a message, not every frame; the
  reconciler keeps the node tree, and layout, paint and render redo only what
  changed. An idle window draws nothing and uses no CPU.
- **About 80 widgets** and some 25 modifiers that add to any node. That
  covers buttons and toggles, text, number, date, time and colour fields and
  pickers, lists, tables and tree views (virtualised, with rows of any
  height), icon views, tabs, menus and menu bars, dialogs, popovers, toasts
  and tooltips, split panes, a code editor, a rich-text and markdown editor,
  a markdown view, a terminal, charts, node graphs and an emoji picker.
  `custom` is a widget of your own that sizes and paints itself.
- **Text** through runa: shaping, bidi, line breaking, OpenType features,
  font fallback, variable fonts, colour emoji with skin tones, and rich text
  with inline objects.
- **Theming** that follows the desktop by default: light and dark, accent,
  contrast, fonts and text size, a KDE colour scheme, and a Windows contrast
  theme in the person's own colours. There are three layers: global tokens,
  a style for each widget kind (every field optional, deriving from the
  tokens), and a subtree with a theme of its own. Density can be compact or
  spacious, and the smallest target size is set by the theme.
- **Accessibility** on all three platforms: AT-SPI2, NSAccessibility and UI
  Automation, from one mapping. Every interactive widget has a role, a name,
  keyboard operation and a focus ring, and `baldr.lint` reports a control
  left without a name. Any form control can be marked invalid or required. The desktop's text size, reduce motion and reduce
  transparency are followed.
- **Locale** from the desktop: dates, times, numbers, day names and the first
  day of the week.
- **Desktop integration**: window icons and windows that belong to
  another, notifications, tray and status items, file dialogs, the clipboard and primary selection, drag and drop between apps,
  opening URLs and revealing files, the OS keychain, single-instance
  relaunch and keep-awake.
- **Async work** as commands from `update` (jobs on threads, delays, file
  IO, the clipboard) and subscriptions (timers, file watches).
- **A GPU canvas** an app draws into, with its own shaders, blur chains and
  recovery from a lost device. Video frames from an app's decoder go to a
  canvas, or are imported as GPU buffers on Linux.
- **Pictures**: PNG, JPEG, GIF, WebP, BMP, ICO, QOI, TGA, netpbm, SVG and
  XPM decoded in Odin. Animated GIF and WebP play by themselves, JPEG
  photos are turned upright by their EXIF orientation, and PNG is written.
- **Audio** playback and capture of PCM on PulseAudio, WASAPI and CoreAudio.
- **Bounds on untrusted input**: a picture's claimed size is checked before
  it is decoded, and an SVG's work is capped. Pastes and drops are capped
  in size and time. `open_path` refuses files a desktop would run, and
  `open_url` refuses mail links that attach files. Notification bodies are
  escaped, and a D-Bus message that will not decode costs only itself.
  Screen-reader actions reach only what a reader is shown, and the
  single-instance channel is private to the user.
- **Shell surfaces** on Wayland: layer surfaces for bars, docks and
  launchers, applet embedding, the session lock, toplevel and workspace
  management, and backdrop blur.
- **Backends** for Wayland, X11, Windows and macOS, drawn with Vulkan, or
  Metal on macOS. No C is compiled into the tree.
- **Headless tests**: layout, reconciliation, paint and accessibility run
  without a window or a GPU.
- **40 examples** and a gallery, a guide, a per-widget reference and a
  generated API reference.
- **Development aids**: per-frame timings, memory growth by source line,
  damage and drawing-bounds checks (`BALDR_DEBUG_*`), and a test gate that
  fails on a leak or on a widget drawing outside its box.
