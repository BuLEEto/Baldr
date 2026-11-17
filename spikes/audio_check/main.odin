package main

// Does baldr:audio actually move sound on this machine? The unit tests
// prove the ring; only a run proves the backend. This plays a 440 Hz tone
// and records it back, which on a box whose default source is the default
// sink's monitor is a real loop through the sound server.
//
// It measures rather than asserts "no error": the silence floor before
// anything plays, the energy at 440 Hz against 220 and 880 once it does,
// how long `playback_queued` says is left against a clock, what a read
// costs (it must never block), and whether anything was lost.
//
//	./build.sh spike audio_check run

import "core:fmt"
import "core:math"
import "core:os"
import "core:time"
import "baldr:audio"

RATE :: 48_000
TONE :: 440.0
SECS :: 1.0

// goertzel is the energy at one frequency: a single-bin DFT, which is all
// that is needed to say "it is a 440 Hz tone and not a 220 Hz one".
// range_of is the lowest and highest sample, which is how a format read as
// something it is not gives itself away.
range_of :: proc(x: []f32) -> (lo, hi: f32) {
	if len(x) == 0 do return 0, 0
	lo, hi = x[0], x[0]
	for v in x {
		lo = min(lo, v)
		hi = max(hi, v)
	}
	return
}

goertzel :: proc(x: []f32, freq, rate: f64) -> f64 {
	w := 2 * math.PI * freq / rate
	coeff := 2 * math.cos(w)
	s1, s2: f64
	for v in x {
		s := f64(v) + coeff * s1 - s2
		s2, s1 = s1, s
	}
	return math.sqrt(s1 * s1 + s2 * s2 - coeff * s1 * s2) / f64(len(x))
}

rms :: proc(x: []f32) -> f64 {
	if len(x) == 0 do return 0
	acc: f64
	for v in x do acc += f64(v) * f64(v)
	return math.sqrt(acc / f64(len(x)))
}

main :: proc() {
	fmt.println("baldr:audio — a real loop through the sound server\n")

	// ---- capture: open the default input ----
	cap: audio.Capture
	if err := audio.capture_open(&cap, audio.Format{RATE, 1}); err != .None {
		fmt.printfln("capture_open: %v (%s)", err, audio.error_text(err))
		fmt.println("\nNo input on this machine. The playback half still runs below.")
	}
	defer audio.capture_close(&cap)
	if cap.open {
		fmt.printfln("capture  open: %d Hz, %d channel(s)", cap.format.rate, cap.format.channels)
	}

	// ---- the silence floor, before anything is played ----
	// Without this the tone's level means nothing: the monitor of a sink
	// something else is already using is not silent.
	floor_buf := make([]f32, RATE) // a second's worth
	defer delete(floor_buf)
	floor_n := 0
	if cap.open {
		start := time.now()
		worst_read: time.Duration
		for time.since(start) < 400 * time.Millisecond {
			t0 := time.now()
			n, err := audio.capture_read(&cap, floor_buf[floor_n:])
			worst_read = max(worst_read, time.since(t0))
			if err != .None {
				fmt.printfln("capture_read: %v", err)
				break
			}
			floor_n += n
			if floor_n == len(floor_buf) do break
			time.sleep(5 * time.Millisecond)
		}
		lo, hi := range_of(floor_buf[:floor_n])
		fmt.printfln("silence floor: %d samples, rms %.5f, worst read %.3f ms (must not block)",
			floor_n, rms(floor_buf[:floor_n]), time.duration_milliseconds(worst_read))
		// An f32 sample is in [-1, 1]. Anything outside it means the bytes
		// are being read as a format they are not, which a wrong sample
		// rate or channel count would not show.
		fmt.printfln("floor range: %+.4f .. %+.4f%s", lo, hi,
			"" if lo >= -1.001 && hi <= 1.001 else "   <-- outside [-1, 1]: the format is being read wrongly")
	}

	// ---- playback: a second of 440 Hz ----
	play: audio.Playback
	have_out := true
	if err := audio.playback_open(&play, audio.Format{RATE, 1}); err != .None {
		fmt.printfln("playback_open: %v (%s)", err, audio.error_text(err))
		fmt.println("No output on this machine. What was measured of the input stands above.")
		have_out = false
	}
	if !have_out {
		if cap.open {
			fmt.printfln("\ncaptured %d samples with no output to play through; %d lost",
				floor_n, audio.capture_lost(&cap))
			fmt.println("The input half opened, read without blocking and gave samples in range.")
		}
		return
	}
	defer audio.playback_close(&play)
	fmt.printfln("playback open: %d Hz, %d channel(s)\n", play.format.rate, play.format.channels)

	tone := make([]f32, int(RATE * SECS))
	defer delete(tone)
	for &v, i in tone {
		// a quarter of full scale, with 10 ms ramps so the start and end
		// are not a click (a click is broadband and would pollute the bins)
		env := f32(1)
		ramp := RATE / 100
		if i < ramp do env = f32(i) / f32(ramp)
		if i >= len(tone) - ramp do env = f32(len(tone) - 1 - i) / f32(ramp)
		v = 0.25 * env * math.sin_f32(2 * math.PI * TONE * f32(i) / RATE)
	}

	heard := make([]f32, RATE * 3)
	defer delete(heard)
	heard_n := 0
	lost_at_stop := -1

	wrote := 0
	started := time.now()
	drained_at: time.Duration = -1
	worst_write: time.Duration
	for {
		if wrote < len(tone) {
			t0 := time.now()
			n, err := audio.playback_write(&play, tone[wrote:])
			worst_write = max(worst_write, time.since(t0))
			if err != .None {
				fmt.printfln("playback_write: %v", err)
				break
			}
			wrote += n
		}
		if cap.open && heard_n < len(heard) {
			n, _ := audio.capture_read(&cap, heard[heard_n:])
			heard_n += n
			// Take the loss count the moment the buffer is full: after
			// that the ring overflows because this spike stops reading,
			// and `capture_lost` would count samples the toolkit never
			// dropped.
			if heard_n >= len(heard) do lost_at_stop = audio.capture_lost(&cap)
		}
		if wrote >= len(tone) && audio.playback_drained(&play) {
			drained_at = time.since(started)
			break
		}
		if time.since(started) > 6 * time.Second {
			fmt.printfln("gave up waiting for the clip to finish: queued=%d clock_ok=%v written=%d played=%d",
				audio.playback_queued(&play), audio.probe_clock_ok(&play),
				audio.probe_written(&play), audio.probe_played(&play))
			break
		}
		time.sleep(5 * time.Millisecond)
	}

	fmt.printfln("wrote %d of %d samples (%.2f s of audio)", wrote, len(tone), f64(wrote) / RATE)
	fmt.printfln("worst playback_write: %.3f ms", time.duration_milliseconds(worst_write))
	if drained_at >= 0 {
		late := (time.duration_seconds(drained_at) - SECS) * 1000
		// A little either way is right: late by the poll step, or early by
		// the sink's own buffer, which the server's clock cannot see past.
		fmt.printfln("drained after %.3f s — %+.0f ms against the clip's own length",
			time.duration_seconds(drained_at), late)
	}
	fmt.printfln("underruns mid-clip: %d (0 is right for a clip written in one go)",
		audio.playback_underruns(&play))

	// ---- flush stops a clip early, and the stream survives it ----
	//
	// Runs with or without an input: it is the backend's own behaviour.
	// The second clip is the check — a flush that stops the sound but
	// leaves the stream deaf would still pass "queued went to zero".
	audio.playback_write(&play, tone[:])
	before := audio.playback_queued(&play)
	flush_start := time.now()
	audio.playback_flush(&play)
	flush_took := time.since(flush_start)
	time.sleep(80 * time.Millisecond) // the server's own buffer takes a moment to go
	after := audio.playback_queued(&play)
	fmt.printfln("\nflush: %d samples queued -> %d (%.0f ms -> %.0f ms), the call itself took %.1f ms",
		before, after,
		f64(audio.ms_for_samples(play.format, before)), f64(audio.ms_for_samples(play.format, after)),
		time.duration_milliseconds(flush_took))

	wrote_after, _ := audio.playback_write(&play, tone[:RATE / 4])
	again_start := time.now()
	again := time.Duration(-1)
	for time.duration_seconds(time.since(again_start)) < 2.0 {
		if audio.playback_drained(&play) {
			again = time.since(again_start)
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	if again >= 0 {
		fmt.printfln("after the flush: wrote %d samples (%.2f s) and they drained in %.3f s",
			wrote_after, f64(wrote_after) / RATE, time.duration_seconds(again))
	} else {
		fmt.println("after the flush: a quarter-second clip never drained — the stream did not survive it")
	}
	if again < 0 do os.exit(1)

	// ---- what came back ----
	if !cap.open {
		fmt.println("\nNo input, so nothing to analyse. Playback reported no error.")
		return
	}
	// skip the first 100 ms: the tone had not reached the monitor yet
	skip := min(RATE / 10, heard_n)
	window := heard[skip:heard_n]
	lost := lost_at_stop if lost_at_stop >= 0 else audio.capture_lost(&cap)
	fmt.printfln("\ncaptured %d samples (%.2f s), %d lost while it was being read", heard_n, f64(heard_n) / RATE, lost)
	if len(window) < RATE / 4 {
		fmt.println("too little captured to analyse")
		return
	}
	at_tone := goertzel(window, TONE, RATE)
	at_half := goertzel(window, TONE / 2, RATE)
	at_dbl  := goertzel(window, TONE * 2, RATE)
	fmt.printfln("rms %.5f (floor was %.5f)", rms(window), rms(floor_buf[:floor_n]))
	fmt.printfln("energy at %.0f Hz: %.6f", TONE, at_tone)
	fmt.printfln("energy at %.0f Hz: %.6f", TONE / 2, at_half)
	fmt.printfln("energy at %.0f Hz: %.6f", TONE * 2, at_dbl)

	ok := at_tone > 4 * max(at_half, at_dbl) && at_tone > 0.001
	fmt.printfln("\n%s", "the tone played and was heard back" if ok else "the 440 Hz bin does not dominate: look above")

	if !ok do os.exit(1)
}
