#+build windows
package audio

@(require) import "core:testing"

// The WASAPI backend's bookkeeping: how many of the app's own samples the
// device still holds. `GetCurrentPadding` counts the silence the stream
// runs on between clips too, so the thread records each block it hands over
// (the cumulative frame it ends at, and its real samples) and retires them
// as the device consumes frames. None of this needs a device.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
wa_fixture :: proc() -> Wa_Stream {
	return Wa_Stream{channels = 1}
}

@(test)
wasapi_queued_counts_only_the_apps_own_samples :: proc(t: ^testing.T) {
	ws := wa_fixture()
	wa_push(&ws, 480, 480) // a block of real audio
	wa_push(&ws, 480, 0)   // and a block of the silence the stream runs on
	testing.expect_value(t, int(ws.pending), 480)

	// the device has played the first block and none of the second
	wa_retire(&ws, 480)
	testing.expect_value(t, int(ws.pending), 0)
}

@(test)
wasapi_queued_keeps_a_block_until_it_is_wholly_played :: proc(t: ^testing.T) {
	ws := wa_fixture()
	wa_push(&ws, 480, 480)
	// half of it has been heard: the block is still counted, as sound still
	// to come. The error is bounded by one block.
	wa_retire(&ws, 240)
	testing.expect_value(t, int(ws.pending), 480)
	wa_retire(&ws, 0)
	testing.expect_value(t, int(ws.pending), 0)
}

@(test)
wasapi_queued_drains_to_zero_over_a_clip :: proc(t: ^testing.T) {
	ws := wa_fixture()
	// a second of audio in 20 ms blocks, then silence behind it
	for _ in 0 ..< 50 do wa_push(&ws, 960, 960)
	testing.expect_value(t, int(ws.pending), 48_000)
	for i in 1 ..= 50 {
		played := u64(i) * 960
		wa_retire(&ws, u32(ws.total - played))
		testing.expectf(t, int(ws.pending) == 48_000 - i * 960,
			"after %d blocks played, %d samples still queued", i, ws.pending)
	}
	testing.expect_value(t, int(ws.pending), 0)
}

// The ring of blocks is finite. Overrunning it must cost an undercount of
// one block, never a count that runs away and never reaches zero.
@(test)
wasapi_queued_survives_more_blocks_than_the_ring_holds :: proc(t: ^testing.T) {
	ws := wa_fixture()
	for _ in 0 ..< WA_CHUNKS * 3 do wa_push(&ws, 480, 480)
	testing.expect(t, int(ws.pending) > 0, "something is still queued")
	wa_retire(&ws, 0) // the device has played everything
	testing.expect_value(t, int(ws.pending), 0)
}

// Two channels: counts are samples, not frames, everywhere in this package.
@(test)
wasapi_queued_is_samples_not_frames :: proc(t: ^testing.T) {
	ws := Wa_Stream{channels = 2}
	wa_push(&ws, 480, 960) // 480 stereo frames is 960 samples
	testing.expect_value(t, int(ws.pending), 960)
	wa_retire(&ws, 0)
	testing.expect_value(t, int(ws.pending), 0)
}

// --- a whole clip, against a device that plays what it is given ---
//
// `wa_plan` and the two accounting procs are the whole of the render
// thread's arithmetic, so they are driven here against a simulated device:
// it consumes a period at a time, the app writes nothing after the clip,
// and the stream keeps running on silence as a real one does.

@(private = "file")
Wa_Fake_Device :: struct {
	frames:  u32, // the whole buffer
	period:  u32, // what it consumes between wake-ups
	padding: u32, // what it still holds
}

// wa_run_pass is one turn of the render thread's loop, with the COM calls
// replaced by the fake device.
@(private = "file")
wa_run_pass :: proc(ws: ^Wa_Stream, dev: ^Wa_Fake_Device, ring_frames: ^int) {
	played := min(dev.padding, dev.period)
	dev.padding -= played
	wa_retire(ws, dev.padding)
	pass := wa_plan(dev.frames, dev.padding, ring_frames^)
	if pass.idle do return
	if pass.silent {
		wa_push(ws, pass.take, 0)
	} else {
		wa_push(ws, pass.take, int(pass.take) * ws.channels)
		ring_frames^ -= int(pass.take)
	}
	dev.padding += pass.take
}

@(test)
wasapi_a_clip_plays_out_and_queued_reaches_zero :: proc(t: ^testing.T) {
	ws := Wa_Stream{channels = 1}
	dev := Wa_Fake_Device{frames = 1440, period = 480} // three periods of 10 ms
	ring_frames := 48_000                              // a one-second note, written in one go

	// While there is audio to play, the count must never be zero.
	for ring_frames > 0 {
		wa_run_pass(&ws, &dev, &ring_frames)
		testing.expectf(t, int(ws.pending) > 0,
			"nothing queued with %d frames still unwritten", ring_frames)
	}
	testing.expect_value(t, ring_frames, 0)

	// The app has stopped writing and the stream runs on silence. The count
	// must fall to exactly zero, and within the buffer it had queued.
	drained_at := -1
	for pass in 0 ..< 200 {
		wa_run_pass(&ws, &dev, &ring_frames)
		if ws.pending == 0 {
			drained_at = pass
			break
		}
	}
	testing.expectf(t, drained_at >= 0, "the note never finished: %d samples still queued", ws.pending)
	testing.expectf(t, drained_at < 8, "it took %d passes past the end to report finished", drained_at)

	// …and it stays there, however long the stream is left open.
	for _ in 0 ..< 200 do wa_run_pass(&ws, &dev, &ring_frames)
	testing.expect_value(t, int(ws.pending), 0)
}

// The same, written in dribs as a decoder would hand it over, so the thread
// takes short blocks and silence between them.
@(test)
wasapi_a_clip_written_in_pieces_still_reaches_zero :: proc(t: ^testing.T) {
	ws := Wa_Stream{channels = 2}
	dev := Wa_Fake_Device{frames = 1440, period = 480}
	ring_frames := 0
	left := 24_000 // frames still to be handed over by the app

	for _ in 0 ..< 400 {
		if left > 0 { // the app writes 100 frames every other pass
			take := min(left, 100)
			ring_frames += take
			left -= take
		}
		wa_run_pass(&ws, &dev, &ring_frames)
	}
	for _ in 0 ..< 200 do wa_run_pass(&ws, &dev, &ring_frames)
	testing.expect_value(t, left, 0)
	testing.expect_value(t, ring_frames, 0)
	testing.expect_value(t, int(ws.pending), 0)
}

// A device reporting more than it was given would, unguarded, retire every
// block at once while the clip is still playing.
@(test)
wasapi_a_padding_past_what_was_written_does_not_empty_the_count :: proc(t: ^testing.T) {
	ws := Wa_Stream{channels = 1}
	wa_push(&ws, 480, 480)
	wa_retire(&ws, 9_000) // nonsense, larger than everything written
	testing.expect_value(t, int(ws.pending), 480)
}

// wa_plan itself: the three answers it can give.
@(test)
wasapi_a_pass_plays_audio_silence_or_nothing :: proc(t: ^testing.T) {
	full := wa_plan(1440, 1440, 10_000)
	testing.expect(t, full.idle, "a device holding a full buffer is left alone")

	some := wa_plan(1440, 960, 10_000)
	testing.expect(t, !some.idle && !some.silent, "room and audio: it plays audio")
	testing.expect_value(t, int(some.take), 480)

	short := wa_plan(1440, 960, 100)
	testing.expect_value(t, int(short.take), 100) // only what there is

	dry := wa_plan(1440, 960, 0)
	testing.expect(t, dry.silent, "room and nothing to play: explicit silence")
	testing.expect_value(t, int(dry.take), 480) // the whole of the room, so the device moves on
}

}
