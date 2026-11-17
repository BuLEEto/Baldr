package baldr

// Coming through a GPU reset.
//
// A card can be reset by anything on it, and every client is told its
// device is gone. The device is built again (gpu/recover.odin), everything
// the toolkit had uploaded is uploaded again from what it still holds on the
// CPU, and the app is told that its canvases — which live in VRAM and have
// no copy — are gone. If the card will not come back after a few tries, the
// app exits non-zero so whatever started it can start it again: alive but
// never drawing is the one answer that helps nobody.

import "baldr:gpu"
import "baldr:third_party/runa"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

// GPU_RECOVER_TRIES is how many times the device is asked for again before
// the app gives up, and GPU_RECOVER_WAIT_MS how long it leaves between
// tries — a card being reset takes a moment, and asking in a tight loop
// neither helps it nor leaves the log readable.
@(private) GPU_RECOVER_TRIES   :: 8
@(private) GPU_RECOVER_WAIT_MS :: f64(250)

// gpu_reset_rehearsal is BALDR_SIMULATE_GPU_RESET: a number of
// milliseconds after which the run pretends its device has gone, and again
// every that many if a second number follows (`2000,5000`). It lets an app
// test its own App.gpu_reset without a real reset. Nothing is faulted: the
// device is taken down and built again exactly as a real reset leaves it.
@(private)
gpu_reset_rehearsal :: proc(rt: ^Runtime($State, $Msg), now_ms: f64) {
	if rt.r == nil || rt.rehearse_ms <= 0 || gpu.lost(rt.r) do return
	if now_ms < rt.rehearse_ms do return
	rt.rehearse_ms = rt.rehearse_ms + rt.rehearse_every if rt.rehearse_every > 0 else 0
	fmt.eprintfln("baldr: BALDR_SIMULATE_GPU_RESET: pretending the device has gone")
	gpu.simulate_device_lost(rt.r)
}

// gpu_rehearsal_read reads BALDR_SIMULATE_GPU_RESET against the run's
// clock: "1500" is once at a second and a half, "1500,3000" then every
// three seconds. Both zero when it is unset or does not parse — a debug
// knob never stops an app starting.
@(private)
gpu_rehearsal_read :: proc(now_ms: f64) -> (at_ms, every_ms: f64) {
	v := os.get_env("BALDR_SIMULATE_GPU_RESET", context.temp_allocator)
	if v == "" do return
	first, _, rest := strings.partition(v, ",")
	at, ok := strconv.parse_f64(strings.trim_space(first))
	if !ok || at <= 0 do return
	at_ms = now_ms + at
	if every, ok2 := strconv.parse_f64(strings.trim_space(rest)); ok2 && every > 0 do every_ms = every
	return
}

// gpu_note_lost records, once, that a frame could not draw; a line per
// frame would flood the log. The run loop does the rebuilding: a frame is
// no place to take the device apart.
@(private)
gpu_note_lost :: proc(fc: ^Frame_Ctx) {
	if fc == nil || fc.r == nil do return
	if !gpu.lost_first(fc.r) do return
	if gpu.lost(fc.r) {
		fmt.eprintfln("baldr: the GPU was reset; rebuilding the device")
	} else {
		// The device is fine; this window's surface is not, which the
		// compositor's own end of it decides. Nothing here can bring it back.
		fmt.eprintfln("baldr: this window's drawing surface is gone; it will not draw again")
	}
}

// gpu_recover_step is the run loop's attempt, at most one per wait: rebuild
// the device, put back what the toolkit had on it, tell the app what it
// lost. Returns false when the app should stop — the card has not come back
// after GPU_RECOVER_TRIES and hanging would be worse than exiting.
@(private)
gpu_recover_step :: proc(rt: ^Runtime($State, $Msg), now_ms: f64) -> bool {
	if rt.r == nil || !gpu.lost(rt.r) do return true
	if rt.gpu_retry_ms > 0 && now_ms < rt.gpu_retry_ms do return true
	rt.gpu_retry_ms = now_ms + GPU_RECOVER_WAIT_MS

	// The threads waiting on canvas batches hold fences the teardown is
	// about to destroy, and waiting on a destroyed fence is a crash inside
	// the driver. A lost device answers a wait at once (the spec requires a
	// finite answer), so this is a moment; the bound is for when it is not.
	canvas_reads_drain(rt.canvas_host)

	if !gpu.recover(rt.r) {
		tries := gpu.recoveries_failed(rt.r)
		if tries >= GPU_RECOVER_TRIES {
			fmt.eprintfln("baldr: the GPU did not come back after %d tries; exiting so something can start us again", tries)
			return false
		}
		return true
	}
	rt.gpu_retry_ms = 0 // the next loss, whenever it comes, is answered at once
	fmt.eprintfln("baldr: the GPU is back; everything drawn is being uploaded again")

	// What the toolkit uploaded is gone with the device: the glyph and
	// picture atlases are marked unmade, and the next frame makes and fills
	// them from the pixels runa still holds.
	text_engine_gpu_lost(rt.te)

	// Canvases are the app's, live only in VRAM, and have no copy to put
	// back — which is why the app is told rather than quietly handed empty
	// ones.
	canvas_host_gpu_lost(rt.canvas_host)

	for c in rt.ctxs {
		c.fc.frames = 0
		tree_fonts_changed(&c.ui.tree) // everything measured against the old atlases is measured again
		mark_paint_dirty(&c.ui.tree, c.ui.tree.root)
		ask_view(c, {procedure = "gpu reset"})
	}
	if rt.app.gpu_reset != nil {
		if cmd := rt.app.gpu_reset(&rt.state); cmd.kind != .None do run_cmd(rt, cmd)
	}
	return true
}

// canvas_reads_drain lets the threads reading canvases back finish before
// the device under them goes. It is `canvases_shutdown`'s wait, without the
// destroying: the same threads, the same fences, the same reason.
@(private)
canvas_reads_drain :: proc(h: ^Canvas_Host) {
	if h == nil || h.r == nil do return
	gpu.canvas_idle(h.r)
	for i := 0; i < 1000 && sync.atomic_load(&h.waiters) > 0; i += 1 do time.sleep(time.Millisecond)
}

// canvas_host_gpu_lost drops every canvas a host holds: their pages died
// with the device. The slots stay taken rather than being handed out again,
// so an app that kept a Canvas gets a clean false from canvas_valid and
// from every call, instead of drawing into whatever took the slot next.
// canvas_destroy on such a handle frees the slot, which is how an app that
// tidies up in App.gpu_reset gets its numbers back.
@(private)
canvas_host_gpu_lost :: proc(h: ^Canvas_Host) {
	if h == nil do return
	for &e in h.entries {
		if !e.used do continue
		e.lost = true
		e.page = 0
		// The reference host's pixels are its own heap and this is the last
		// pointer to them, so free before dropping. A GPU host keeps none,
		// and a nil delete is fine.
		delete(e.pixels, h.allocator)
		e.pixels = nil
		image_destroy(&e.display)
	}
}

// text_engine_gpu_lost marks every atlas page and picture unmade, so the
// next frame creates them again and fills them from the pixels the text
// engine and runa still hold.
@(private)
text_engine_gpu_lost :: proc(te: ^Text_Engine) {
	if te == nil do return
	for format in runa.Atlas_Format {
		for &st in te.pages[format] do st = {}
		for &p in atlas_pages(te, format) {
			p.is_dirty = true
			p.dirty_min = {}
			p.dirty_max = {p.width, p.height}
		}
	}
	for &st in te.image_pages do st = {}
	// A picture keeps its entry (the pixels are still the app's) but not its
	// page, so the next draw makes a texture again; a stale page number
	// would name something else.
	for _, &p in te.pictures { p.real = false; p.page = 0 }
}
