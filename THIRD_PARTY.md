# Third-party code, fonts and data

Baldr itself is under the zlib licence ([`LICENSE`](LICENSE)). This file
lists everything else in the repository that someone else made, its licence,
and where the full text is.

## What every Baldr program carries

An app built on Baldr embeds the following whether or not it uses them,
because Odin's `#load` puts the bytes into the binary at compile time. Most
of their licences ask that a notice goes with the program.

**`baldr.notices()` returns each notice in full**, for an About box or a
credits page, and `baldr.notices_text()` returns them as one block of text
for a `LICENCES` file. Both follow the build: if an app swaps a font with
`-define:BALDR_UI_FONT=…`, the notice says that font is the app's to
account for. Showing what they return is all an app has to do.

| | Used for | Licence | Full text |
|---|---|---|---|
| **Inter**, © The Inter Project Authors | the UI typeface and its italic | SIL Open Font Licence 1.1 | [`assets/fonts/InterVariable-OFL.txt`](assets/fonts/InterVariable-OFL.txt) |
| **JetBrains Mono**, © The JetBrains Mono Project Authors | the code face: editors, terminals, `mono` text | SIL Open Font Licence 1.1 | [`assets/fonts/JetBrainsMono-OFL.txt`](assets/fonts/JetBrainsMono-OFL.txt) |
| **Twemoji**, Mozilla's COLRv0 build, artwork © Twitter, Inc. and contributors | colour emoji | CC-BY 4.0 (artwork); Apache 2.0 (Mozilla's build tooling, only needed to regenerate the font) | [`assets/fonts/Twemoji-Mozilla-CCBY.txt`](assets/fonts/Twemoji-Mozilla-CCBY.txt) |
| **Lucide**, © Lucide Icons and Contributors, with icons from **Feather**, © Cole Bemis | the icon set, compiled in as path data (`baldr/icons_data.odin`) | ISC; MIT for the Feather icons | [`third_party/lucide/LICENSE`](third_party/lucide/LICENSE) |
| **Unicode data**, © Unicode, Inc. | tables built from Unicode's data files: line breaking, word and grapheme boundaries, bidirectional text, scripts, normalisation, and the emoji picker's list | Unicode License v3 | [`third_party/unicode/LICENSE`](third_party/unicode/LICENSE) |
| **Wayland protocol definitions** (Linux builds only), each © its authors | the Wayland backend's bindings, generated from each protocol's XML | MIT, HPND or zlib, as each file states | [`platform/wayland/wl/NOTICE.txt`](platform/wayland/wl/NOTICE.txt), collected from [`platform/wayland/wl/xml/`](platform/wayland/wl/xml/) |

## Also in the repository

- **[runa](third_party/runa/)**, the pure-Odin text engine (shaping, bidi,
  line breaking, rasterisation), under zlib. It is vendored byte for byte
  from its release tag with no local patches, and has its own
  [`LICENSE`](third_party/runa/LICENSE). Its `tools/ucd/` directory holds
  the Unicode Character Database files its tables are built from, each with
  Unicode's header, and one file that is not Unicode's:
- **PyThaiNLP's Thai word list** (`third_party/runa/tools/ucd/thai_words.txt`,
  PyThaiNLP's `words_th.txt`, © the PyThaiNLP project), under
  [CC-BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). runa
  compiles it in only when an app builds with
  `-define:RUNA_THAI_DICT=true`, for dictionary-based Thai line breaking;
  Baldr does not set it, so no Baldr program contains it. An app that turns
  it on takes on the licence's attribution and share-alike terms for it.
- **Test and sample files** in `assets/test/` and `assets/sample/` were made
  for Baldr: a font with one glyph per CFF2 flex spelling, a PNG in every
  interlacing pass, and the two small pictures the gallery shows. They are
  under Baldr's own licence.

## Not in the repository

- **Odin's own libraries** (`base:`, `core:`, `vendor:`) are part of every
  Odin program, under Odin's zlib licence, © Ginger Bill. They come with
  the compiler, not with Baldr.
- **Libraries the operating system provides**, loaded at run time and never
  shipped with Baldr: the Vulkan loader and driver, and on Linux
  `libwayland-client`, `libwayland-cursor`, `libxkbcommon`, the `libxcb`
  family, `libpulse` and glibc; the system frameworks on Windows and macOS.
