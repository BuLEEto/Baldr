// editor_probe — one case, repeated, so a profiler can see inside it:
// real Markdown (this repo's own docs, to the size asked for) in a
// markdown_editor, laid out again and again with nothing changed, then
// with a width that wobbles, then with a key typed each time.
//
//	build/editor_probe            # ~4.6 MB of markdown
//	PROBE_MB=1 build/editor_probe
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "baldr:baldr"

Msg :: union { int }

main :: proc() {
	te: baldr.Text_Engine
	if !baldr.text_engine_init(&te) { fmt.println("fonts failed"); return }
	defer baldr.text_engine_destroy(&te)

	want := 4_600_000
	if v := os.get_env("PROBE_MB", context.temp_allocator); len(v) > 0 {
		if mb, ok := strconv.parse_f64(v); ok do want = int(mb * 1024 * 1024)
	}
	src: strings.Builder
	dir, derr := os.open("docs")
	if derr != nil { fmt.println("no docs/ here"); return }
	files, _ := os.read_dir(dir, -1, context.allocator)
	os.close(dir)
	for f in files {
		if !strings.has_suffix(f.name, ".md") do continue
		if data, derr2 := os.read_entire_file_from_path(f.fullpath, context.allocator); derr2 == nil {
			strings.write_string(&src, string(data))
			strings.write_string(&src, "\n")
			delete(data)
		}
	}
	one := strings.to_string(src)
	if len(one) == 0 { fmt.println("no markdown in docs/"); return }
	b := strings.builder_make()
	for strings.builder_len(b) < want do strings.write_string(&b, one)
	text := strings.to_string(b)

	ui: baldr.Ui(Msg)
	baldr.ui_init(&ui)
	defer baldr.ui_destroy(&ui)
	baldr.tree_use_text_engine(&ui.tree, &te)
	doc := baldr.document_make(text)
	defer baldr.document_destroy(&doc)

	build :: proc(ui: ^baldr.Ui(Msg), doc: ^baldr.Document, w: f32) {
		baldr.begin_view(ui)
		baldr.column(ui, flex = 1)
		baldr.markdown_editor(ui, doc, flex = 1)
		baldr.end(ui)
		baldr.end_view(ui)
		baldr.frame(&ui.tree, {w, 800})
	}
	t0 := time.tick_now()
	build(&ui, &doc, 1200)
	open := time.duration_milliseconds(time.tick_since(t0))

	t1 := time.tick_now()
	for _ in 0 ..< 60 do build(&ui, &doc, 1000) // nothing changed at all
	idle := time.duration_milliseconds(time.tick_since(t1)) / 60

	t3 := time.tick_now()
	for i in 0 ..< 10 do build(&ui, &doc, 1000 + f32(i % 2)) // …and a width that wobbles by a pixel
	resize := time.duration_milliseconds(time.tick_since(t3)) / 10

	keys := 60
	if v := os.get_env("PROBE_KEYS", context.temp_allocator); len(v) > 0 {
		if k, ok := strconv.parse_int(v); ok do keys = max(k, 1)
	}
	t2 := time.tick_now()
	for i in 0 ..< keys {
		baldr.document_replace(&doc, {0, 0}, {0, 0}, "x", group = u64(i + 1))
		build(&ui, &doc, 1000)
	}
	key := time.duration_milliseconds(time.tick_since(t2)) / f64(keys)

	fmt.printfln("%.1f MB of real markdown, %d blocks: open %.1f ms, idle frame %.1f ms, resize %.1f ms, one key %.1f ms",
		f32(len(text)) / (1024 * 1024), baldr.block_count(&doc), open, idle, resize, key)
}
