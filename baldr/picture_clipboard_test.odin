package baldr

@(require) import "base:runtime"
@(require) import "core:sync"
@(require) import "core:testing"
@(require) import "core:time"
@(require) import "baldr:platform"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them. ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh
// check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Pictures on the clipboard, through a backend that stands in for the
// desktop's.


@(private = "file")
Pc_Msg :: union { Pasted_Image }

// Board is the stand-in clipboard: the forms on offer, and what an app set.
@(private = "file")
Board :: struct {
	offered: []string,
	forms:   map[string][]u8,
	set:     [dynamic]platform.Clip_Item,
	reads:   int, // clipboard_read calls: reading was left to a thread
}

@(private = "file")
board_backend :: proc(board: ^Board, with_read := true) -> platform.Backend {
	b := platform.Backend{data = board}
	b.clipboard_types = proc(b: ^platform.Backend, allocator := context.allocator) -> []string {
		return (^Board)(b.data).offered
	}
	b.clipboard_get_data = proc(b: ^platform.Backend, mime: string, allocator := context.allocator) -> ([]u8, bool) {
		src, have := (^Board)(b.data).forms[mime]
		if !have do return nil, false
		out := make([]u8, len(src), allocator)
		copy(out, src)
		return out, true
	}
	b.clipboard_set_data = proc(b: ^platform.Backend, items: []platform.Clip_Item) -> bool {
		board := (^Board)(b.data)
		for it in items {
			if it.later != nil do platform.clip_later_retain(it.later) // held while offered, as a backend does
			append(&board.set, it)
		}
		return true
	}
	if with_read {
		b.clipboard_read = proc(b: ^platform.Backend, mime: string) -> (platform.Clip_Reader, bool) {
			board := (^Board)(b.data)
			src, have := board.forms[mime]
			if !have do return {}, false
			board.reads += 1
			r := platform.Clip_Reader{user = raw_data(src), fd = len(src)}
			r.read = proc(r: platform.Clip_Reader, allocator: runtime.Allocator) -> ([]u8, bool) {
				out := make([]u8, r.fd, allocator)
				copy(out, ([^]u8)(r.user)[:r.fd])
				return out, true
			}
			return r, true
		}
	}
	return b
}

@(private = "file")
board_destroy :: proc(board: ^Board) {
	for it in board.set do if it.later != nil do platform.clip_later_release(it.later)
	delete(board.set)
	delete(board.forms)
}

// paste_and_wait runs paste_image and waits for its outcome to arrive.
@(private = "file")
paste_and_wait :: proc(t: ^testing.T, rt: ^Runtime(int, Pc_Msg)) -> (got: Pasted_Image, arrived: bool) {
	run_cmd(rt, paste_image(Pc_Msg, proc(e: Ev(Pasted_Image)) -> Pc_Msg { return e.value }))
	deadline := time.tick_now()
	for time.tick_since(deadline) < 5 * time.Second {
		clear(&rt.msgs)
		mailbox_drain(&rt.mailbox, &rt.jobs, &rt.msgs)
		for m in rt.msgs do if v, ok := m.(Pasted_Image); ok do return v, true
		time.sleep(time.Millisecond)
	}
	return {}, false
}

@(private = "file")
runtime_destroy :: proc(rt: ^Runtime(int, Pc_Msg)) {
	jobs_shutdown(&rt.mailbox, &rt.jobs)
	delete(rt.jobs)
	delete(rt.msgs)
	delete(rt.mailbox.mail)
}

@(private = "file")
checker :: proc(w, h: int) -> Image {
	px := make([]u8, w * h * 4, context.temp_allocator)
	for y in 0 ..< h do for x in 0 ..< w {
		c := [4]u8{200, 40, 40, 255} if (x / 4 + y / 4) % 2 == 0 else [4]u8{30, 90, 220, 128}
		copy(px[(y * w + x) * 4:], c[:])
	}
	img, _ := image_from_rgba(w, h, px)
	return img
}

// A copied picture is offered as image/png at once; its PNG is made on a
// thread from the pixels as they were at the copy, and it lives as long as
// the backend holds it.
@(test)
copy_image_offers_the_picture_as_png :: proc(t: ^testing.T) {
	board: Board
	defer board_destroy(&board)
	b := board_backend(&board)
	rt: Runtime(int, Pc_Msg)
	rt.backend = &b
	defer runtime_destroy(&rt)

	img := checker(40, 24)
	defer image_destroy(&img)
	run_cmd(&rt, copy_image(Pc_Msg, &img))
	img.pixels[0] = 7 // the app goes on changing its picture
	testing.expect_value(t, len(board.set), 1)
	if len(board.set) != 1 do return
	it := board.set[0]
	testing.expect(t, it.mime == "image/png" && it.later != nil && it.data == nil, "a PNG, made later")
	png := it.later.wait(it.later)
	back, ok := image_load(png, context.temp_allocator)
	want := checker(40, 24)
	defer image_destroy(&want)
	testing.expect(t, ok && string(back.pixels) == string(want.pixels), "the picture as it was copied")
	for i := 0; i < 1000 && sync.atomic_load(&it.later.refs) != 1; i += 1 do time.sleep(time.Millisecond)
	testing.expect_value(t, sync.atomic_load(&it.later.refs), 1) // the encoder and the command let go; the backend holds it

	none: Image
	run_cmd(&rt, copy_image(Pc_Msg, &none))
	testing.expect_value(t, len(board.set), 1) // nothing copied
}

// A paste reads the best picture form on offer, off the UI thread, and the
// app gets the picture, the form and its bytes.
@(test)
paste_image_reads_the_best_form :: proc(t: ^testing.T) {
	board: Board
	defer board_destroy(&board)
	b := board_backend(&board)
	rt: Runtime(int, Pc_Msg)
	rt.backend = &b
	defer runtime_destroy(&rt)

	img := checker(33, 17)
	defer image_destroy(&img)
	png, _ := image_encode_png(&img, context.temp_allocator)
	board.offered = {"text/html", "image/jpeg", "image/png", "image/webp"}
	board.forms["image/png"] = png
	board.forms["image/jpeg"] = {1, 2, 3} // not what is read: PNG comes first
	got, arrived := paste_and_wait(t, &rt)
	testing.expect(t, arrived, "an outcome")
	testing.expect(t, got.ok && got.mime == "image/png" && len(got.data) == len(png), "the PNG, as it came")
	testing.expect(t, got.image.width == 33 && string(got.image.pixels) == string(img.pixels), "decoded")
	testing.expect_value(t, board.reads, 1) // started here, read on a thread
	image_destroy(&got.image) // the app's
	mailbox_release(&rt.mailbox)

	board.offered = {"image/webp"} // a form Baldr cannot decode: its bytes, for an app that can
	board.forms["image/webp"] = {'R', 'I', 'F', 'F'}
	got, arrived = paste_and_wait(t, &rt)
	testing.expect(t, arrived && !got.ok && got.mime == "image/webp" && len(got.data) == 4 && got.image.pixels == nil, "the bytes, no picture")
	mailbox_release(&rt.mailbox)

	board.offered = {"text/plain"}
	got, arrived = paste_and_wait(t, &rt)
	testing.expect(t, arrived && !got.ok && got.mime == "" && got.data == nil, "no picture")
	mailbox_release(&rt.mailbox)

	board.offered = {"image/png"}
	board.forms["image/png"] = png[:len(png) - 30] // cut short: refused, never decoded
	got, arrived = paste_and_wait(t, &rt)
	testing.expect(t, arrived && !got.ok && got.mime == "image/png", "a broken PNG is no picture")
	mailbox_release(&rt.mailbox)
}

// Without a backend that reads on a thread, the form is read where the paste
// starts and still decoded on a thread; an SVG is drawn at its own size.
@(test)
paste_image_without_threaded_reads_and_from_svg :: proc(t: ^testing.T) {
	board: Board
	defer board_destroy(&board)
	b := board_backend(&board, with_read = false)
	rt: Runtime(int, Pc_Msg)
	rt.backend = &b
	defer runtime_destroy(&rt)

	SVG :: `<svg xmlns="http://www.w3.org/2000/svg" width="30" height="20"><rect width="30" height="20" fill="#ff0000"/></svg>`
	board.offered = {"image/svg+xml"}
	board.forms["image/svg+xml"] = transmute([]u8)string(SVG)
	got, arrived := paste_and_wait(t, &rt)
	testing.expect(t, arrived && got.ok && got.image.width == 30 && got.image.height == 20, "drawn at its size")
	if got.ok do testing.expect(t, got.image.pixels[0] == 255 && got.image.pixels[1] == 0 && got.image.pixels[3] == 255, "red")
	testing.expect_value(t, board.reads, 0)
	image_destroy(&got.image)
	mailbox_release(&rt.mailbox)
}

// A plain message as the handler cannot carry the picture: it is freed
// rather than lost.
@(test)
paste_image_with_a_plain_message_frees_the_picture :: proc(t: ^testing.T) {
	board: Board
	defer board_destroy(&board)
	b := board_backend(&board)
	rt: Runtime(int, Pc_Msg)
	rt.backend = &b
	defer runtime_destroy(&rt)
	img := checker(8, 8)
	defer image_destroy(&img)
	png, _ := image_encode_png(&img, context.temp_allocator)
	board.offered = {"image/png"}
	board.forms["image/png"] = png
	run_cmd(&rt, paste_image(Pc_Msg, Pc_Msg(Pasted_Image{})))
	for i := 0; i < 5000 && len(rt.msgs) == 0; i += 1 {
		mailbox_drain(&rt.mailbox, &rt.jobs, &rt.msgs)
		time.sleep(time.Millisecond)
	}
	testing.expect_value(t, len(rt.msgs), 1)
	mailbox_release(&rt.mailbox) // the tracking allocator says whether the picture was freed
}

} // when ODIN_TEST