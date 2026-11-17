// chat_cache — does a long chat re-shape paragraphs whose text has not
// changed?
//
// A chat of markdown_view messages, rebuilt once a second with nothing
// changed: the case a streaming reply hits on every burst. A warm cache
// shapes nothing, because `markdown_view` keeps its own per-block cache and
// a rebuild of unchanged text never reaches `text_lines`. A rebuild that
// walks the view in order is the LRU sequential-scan worst case for
// `LINES_CACHE_MAX`, so a cost that appears once N passes the cap is that
// cache churning. The first open still lays out every message, seen or not;
// `list` with `estimated_height` and `key_of` is the answer to that.
//
// Judge it with BALDR_FAST=1: a debug build is over ten times slower here.
//
// It cannot be a headless test: there is no font engine there, so
// `text_lines` — and its cache — never runs. The number to watch is
// `shaped` in the BALDR_DEBUG_FRAMES line.
//
//   BALDR_DEBUG_FRAMES=1 ./build.sh spike chat_cache run
//
// `BALDR_CHAT_N` sets how many messages (default 600); try it either side
// of 256, the cap. `BALDR_CHAT_WOBBLE` moves the width by a fraction of a
// pixel every rebuild.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "baldr:baldr"

Msg :: union { Tick }
Tick :: struct {}

State :: struct {
	n:     int,
	ticks: int,
	// One Markdown_Doc per message, as a chat app holds them: the parse is the
	// app's and is done once, so anything re-done per rebuild is the toolkit's.
	docs:  []Markdown_Doc,
}

Markdown_Doc :: baldr.Markdown_Doc

// body is message `i`'s text — distinct per message, as a chat's is, so
// nothing collapses into one cache entry.
body :: proc(i: int) -> string {
	return fmt.tprintf("Message %d — the quick brown fox jumps over the lazy dog, and then says something a little longer so the paragraph wraps.", i)
}

main :: proc() {
	n := 600
	if v, ok := os.lookup_env("BALDR_CHAT_N", context.temp_allocator); ok {
		if parsed, good := strconv.parse_int(v); good && parsed > 0 do n = parsed
	}
	fmt.eprintfln("chat_cache: %d messages. Watch `shaped` in the frames line: it is the paragraph cache's misses.", n)
	fmt.eprintfln("            A warm cache should shape 0 a frame. LINES_CACHE_MAX is %d.", baldr.LINES_CACHE_MAX)

	baldr.run(baldr.App(State, Msg){
		title = "chat cache", app_id = "baldr.chat_cache", size = {720, 700},
		init = proc() -> State {
			n := 600
			if v, ok := os.lookup_env("BALDR_CHAT_N", context.temp_allocator); ok {
				if parsed, good := strconv.parse_int(v); good && parsed > 0 do n = parsed
			}
			docs := make([]Markdown_Doc, n)
			for i in 0 ..< n {
				baldr.md_init(&docs[i])
				baldr.md_set(&docs[i], body(i))
			}
			return {n = n, docs = docs}
		},
		// A tick a second rebuilds the view without changing a single
		// message, which is the case that should cost nothing: a streaming
		// reply rebuilds like this on every burst.
		subscriptions = proc(s: ^State, out: ^[dynamic]baldr.Sub(Msg)) {
			append(out, baldr.every(Msg, 1000, Tick{}))
		},
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			s.ticks += 1
			return {}
		},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			n := min(s.n if s.n > 0 else 600, len(s.docs))
			// BALDR_CHAT_WOBBLE: change the available width by a fraction of
			// a pixel each rebuild. `wrap_w` is part of the paragraph
			// cache's key and of markdown_view's per-block cache, so a width
			// that is not bit-identical between rebuilds re-shapes every block.
			wobble: f32 = 0
			if _, on := os.lookup_env("BALDR_CHAT_WOBBLE", context.temp_allocator); on {
				wobble = 0.25 if s.ticks % 2 == 0 else 0
			}
			baldr.column(ui, flex = 1, padding = .md); defer baldr.end(ui)
			baldr.text(ui, fmt.tprintf("%d messages, rebuild %d — nothing below has changed", n, s.ticks))
			baldr.scroll(ui, flex = 1); defer baldr.end(ui)
			baldr.column(ui, gap = .sm); defer baldr.end(ui)
			for i in 0 ..< n {
				baldr.card(ui, padding = .sm, max_width = 520 + wobble, key = u64(i) + 1)
				defer baldr.end(ui)
				// markdown_view, as a chat renders a reply: plain `text` nodes
				// keep their measured size and shape nothing on a rebuild, so
				// they would not show the cost.
				baldr.markdown_view(ui, &s.docs[i], label = "Reply", key = u64(i) + 1)
			}
		},
	})
}
