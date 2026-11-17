package main

// The clipboard, in the forms only a real desktop can prove.
//
// A picture: Ctrl+C copies the picture shown, as image/png; Ctrl+V pastes
// whatever picture is on the clipboard in its place.
//
// Formatted text: Ctrl+Shift+C copies a short document twice
// over — as text/html and as the Markdown it was written in — which is
// what `copy_html` is for. Read it back from outside the app, where it
// counts:
//
//	wl-paste --list-types          # text/html first, then the five text forms
//	wl-paste -t text/html
//	wl-paste -t text/plain
//
// Each step is logged.

import "core:fmt"
import "baldr:baldr"

W :: 320
H :: 200

State :: struct {
	picture: baldr.Image,
	doc:     baldr.Document, // the editor the formatted copy comes from
}

Copy :: struct {}
Copy_Rich :: struct {}
Paste :: struct {}
Msg :: union { Copy, Copy_Rich, Paste, baldr.Pasted_Image }

// The document, in both forms. The em dash and the accented name are here
// on purpose: an offset counted in runes rather than bytes puts the
// fragment in the wrong place, which is how CF_HTML goes wrong on Windows.
HTML :: `<h2>Spring-loaded folders</h2>` +
	`<p>A drag that <b>rests</b> on a folder <i>opens</i> it — see ` +
	`<a href="https://example.org/dnd">the note</a>.</p>` +
	`<ul><li>Tröst</li><li>two</li></ul>`
TEXT :: `## Spring-loaded folders

A drag that **rests** on a folder *opens* it — see [the note](https://example.org/dnd).

- Tröst
- two
`

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case Copy:
		fmt.eprintfln("clip: copy %dx%d", s.picture.width, s.picture.height)
		return baldr.copy_image(Msg, &s.picture)
	case Copy_Rich:
		fmt.eprintfln("clip: copy formatted, %d bytes of html beside %d of text", len(HTML), len(TEXT))
		return baldr.copy_html(Msg, HTML, TEXT)
	case Paste:
		fmt.eprintln("clip: paste asked")
		return baldr.paste_image(Msg, proc(e: baldr.Ev(baldr.Pasted_Image)) -> Msg { return e.value })
	case baldr.Pasted_Image:
		fmt.eprintfln("clip: pasted ok=%v mime=%q bytes=%d size=%dx%d", v.ok, v.mime, len(v.data), v.image.width, v.image.height)
		if v.ok {
			baldr.image_destroy(&s.picture)
			s.picture = v.image
		}
	}
	return {}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.shortcut(ui, "Ctrl+C", Msg(Copy{}))
	baldr.shortcut(ui, "Ctrl+Shift+C", Msg(Copy_Rich{}))
	baldr.shortcut(ui, "Ctrl+V", Msg(Paste{}))
	baldr.column(ui, flex = 1, padding = .md, gap = .sm); defer baldr.end(ui)
	baldr.text(ui, "Ctrl+C copies the picture, Ctrl+V pastes one")
	baldr.text(ui, "Ctrl+Shift+C copies a document as text/html and as Markdown", role = .Caption, muted = true)
	// The editor matters to the test: it takes Ctrl+C but must pass
	// Ctrl+Shift+C on to the shortcut above. Click into it, then
	// Ctrl+Shift+C: text/html on the clipboard means the shortcut fired; the
	// Markdown alone means the editor ate the key.
	baldr.text_area(ui, &s.doc, label = "Source", width = W, height = 72, key = 2)
	baldr.image(ui, &s.picture, width = W, height = H, fit = .Contain, label = "Picture", key = 1)
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Clip", app_id = "dev.baldr.clip", size = {W + 40, H + 210},
		init = proc() -> (s: State) {
			px := make([]u8, W * H * 4, context.temp_allocator)
			for y in 0 ..< H do for x in 0 ..< W {
				p := px[(y * W + x) * 4:]
				p[0], p[1], p[2], p[3] = u8(x * 255 / W), u8(y * 255 / H), 160, 255
			}
			s.picture, _ = baldr.image_from_rgba(W, H, px)
			s.doc = baldr.document_make(TEXT)
			ring := baldr.path_make()
			defer baldr.path_destroy(&ring)
			baldr.path_ellipse(&ring, {160, 100}, {70, 70})
			baldr.path_ellipse(&ring, {160, 100}, {45, 45})
			m, _ := baldr.mask_make({80, 20}, {160, 160})
			defer baldr.mask_destroy(&m)
			baldr.path_fill(&ring, &m, .Evenodd)
			baldr.image_paint(&s.picture, &m, baldr.rgb(0xFFFFFF, 0.85))
			return
		},
		update = update,
		view = view,
	})
}
