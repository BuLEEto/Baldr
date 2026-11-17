package audio

@(require) import "core:math"
@(require) import "core:sync"
@(require) import "core:testing"
@(require) import "core:thread"
@(require) import "core:time"

// The ring is the part of this package that can be tested without a sound
// card, and the worst to get wrong: it carries every sample between two
// threads with no lock. Two real threads hammer it below, the only way an
// ordering bug shows up.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(test)
a_ring_rounds_its_size_up_to_a_power_of_two :: proc(t: ^testing.T) {
	r: Ring
	testing.expect(t, ring_init(&r, 1000))
	defer ring_destroy(&r)
	testing.expect_value(t, ring_capacity(&r), 1024)
	testing.expect_value(t, ring_available(&r), 0)
	testing.expect_value(t, ring_free(&r), 1024)
}

@(test)
a_ring_gives_back_what_it_was_given_in_order :: proc(t: ^testing.T) {
	r: Ring
	ring_init(&r, 64)
	defer ring_destroy(&r)

	src: [40]f32
	for &v, i in src do v = f32(i)
	testing.expect_value(t, ring_write(&r, src[:]), 40)
	testing.expect_value(t, ring_available(&r), 40)

	dst: [40]f32
	testing.expect_value(t, ring_read(&r, dst[:]), 40)
	for v, i in dst do testing.expect_value(t, v, f32(i))
	testing.expect_value(t, ring_available(&r), 0)
	testing.expect_value(t, ring_read(&r, dst[:]), 0) // empty reads 0, not stale data
}

// The wrap is where an off-by-one lives: write and read past the end of
// the buffer repeatedly, with sizes that are not a factor of the capacity,
// and check every sample is the one that was put in.
@(test)
a_ring_wraps_without_losing_or_repeating_a_sample :: proc(t: ^testing.T) {
	r: Ring
	ring_init(&r, 16) // tiny on purpose, so it wraps many times
	defer ring_destroy(&r)

	next_in, next_out: f32
	src: [7]f32
	dst: [5]f32
	for _ in 0 ..< 200 {
		for &v in src { v = next_in; next_in += 1 }
		wrote := ring_write(&r, src[:])
		next_in -= f32(len(src) - wrote) // what it refused was not consumed
		for _ in 0 ..< 2 {
			got := ring_read(&r, dst[:])
			for v in dst[:got] {
				testing.expectf(t, v == next_out, "sample %.0f came back as %.0f", next_out, v)
				next_out += 1
			}
		}
	}
	testing.expect(t, next_out > 400, "and plenty of samples actually went through")
}

// A full ring refuses the excess rather than overwriting what has not been
// read, and says how much it dropped.
@(test)
a_full_ring_counts_what_it_could_not_take :: proc(t: ^testing.T) {
	r: Ring
	ring_init(&r, 8)
	defer ring_destroy(&r)

	src: [20]f32
	for &v, i in src do v = f32(i)
	testing.expect_value(t, ring_write_lossy(&r, src[:]), 8)
	testing.expect_value(t, ring_lost(&r), 12)
	testing.expect_value(t, ring_write_lossy(&r, src[:]), 0) // still full
	testing.expect_value(t, ring_lost(&r), 32)

	// and what it kept is the FIRST eight, not the last: a reader's oldest
	// unread audio is not thrown away to make room for newer
	dst: [8]f32
	ring_read(&r, dst[:])
	for v, i in dst do testing.expect_value(t, v, f32(i))
}

@(test)
clearing_a_ring_drops_everything_queued :: proc(t: ^testing.T) {
	r: Ring
	ring_init(&r, 32)
	defer ring_destroy(&r)
	src: [20]f32
	ring_write(&r, src[:])
	testing.expect_value(t, ring_available(&r), 20)
	ring_clear(&r)
	testing.expect_value(t, ring_available(&r), 0)
	testing.expect_value(t, ring_free(&r), 32)
}

@(private = "file")
Hammer :: struct {
	ring:  ^Ring,
	total: int,
	sent:  int,
	done:  bool,
}

@(private = "file")
hammer_produce :: proc(th: ^thread.Thread) {
	h := (^Hammer)(th.data)
	buf: [13]f32 // a size that divides neither the capacity nor the total
	next := f32(0)
	for h.sent < h.total {
		n := min(len(buf), h.total - h.sent)
		for i in 0 ..< n { buf[i] = next + f32(i) }
		took := ring_write(h.ring, buf[:n])
		next += f32(took)
		h.sent += took
		if took == 0 do time.sleep(50 * time.Microsecond) // full: let the reader catch up
	}
	sync.atomic_store_explicit(&h.done, true, .Release)
}

// Two real threads: a ring exercised from one thread proves nothing about
// its memory ordering. The producer runs flat out, the consumer reads in
// differently-sized bites, and every sample must arrive once and in order.
@(test)
a_ring_crossing_two_threads_keeps_every_sample_in_order :: proc(t: ^testing.T) {
	r: Ring
	ring_init(&r, 256)
	defer ring_destroy(&r)

	h := Hammer{ring = &r, total = 200_000}
	th := thread.create(hammer_produce)
	testing.expect(t, th != nil, "the producer thread started")
	th.data = &h
	thread.start(th)
	defer { thread.join(th); thread.destroy(th) }

	dst: [97]f32
	want := f32(0)
	got_total := 0
	deadline := time.time_add(time.now(), 10 * time.Second)
	for got_total < h.total {
		n := ring_read(&r, dst[:])
		for v in dst[:n] {
			if v != want {
				testing.expectf(t, false, "sample %.0f arrived as %.0f after %d", want, v, got_total)
				return
			}
			want += 1
		}
		got_total += n
		if n == 0 {
			if sync.atomic_load_explicit(&h.done, .Acquire) && ring_available(&r) == 0 do break
			if time.since(deadline) >= 0 {
				testing.expectf(t, false, "stalled with %d of %d through", got_total, h.total)
				return
			}
		}
	}
	testing.expect_value(t, got_total, h.total)
	testing.expect_value(t, ring_lost(&r), 0) // the producer backed off instead of dropping
}

// --- the public surface, with no device involved ---

@(test)
a_format_converts_between_samples_and_milliseconds :: proc(t: ^testing.T) {
	mono := Format{48_000, 1}
	testing.expect_value(t, samples_for_ms(mono, 20), 960)
	testing.expect_value(t, ms_for_samples(mono, 960), 20)

	stereo := Format{48_000, 2}
	testing.expect_value(t, samples_for_ms(stereo, 20), 1920) // interleaved: twice the samples
	testing.expect_value(t, ms_for_samples(stereo, 1920), 20)
	testing.expect_value(t, ms_for_samples(Format{0, 0}, 100), 0) // no divide by zero
}

@(test)
a_nonsense_format_is_refused_before_any_device_is_touched :: proc(t: ^testing.T) {
	c: Capture
	testing.expect_value(t, capture_open(&c, Format{0, 1}), Error.Bad_Format)
	testing.expect_value(t, capture_open(&c, Format{48_000, 0}), Error.Bad_Format)
	testing.expect_value(t, capture_open(&c, Format{48_000, 99}), Error.Bad_Format)
	testing.expect(t, !c.open, "and nothing was left half-open")

	p: Playback
	testing.expect_value(t, playback_open(&p, Format{1, 1}), Error.Bad_Format)
	testing.expect(t, !p.open)
}

// Every call on a stream that was never opened answers rather than reading
// through a nil backend pointer, so a caller that carries on after a failed
// `capture_open` does not crash in the next `capture_read`.
@(test)
a_closed_stream_answers_every_call_without_crashing :: proc(t: ^testing.T) {
	c: Capture
	buf: [16]f32
	n, err := capture_read(&c, buf[:])
	testing.expect_value(t, n, 0)
	testing.expect_value(t, err, Error.Closed)
	testing.expect_value(t, capture_available(&c), 0)
	testing.expect_value(t, capture_lost(&c), 0)
	capture_close(&c) // twice, on something never opened
	capture_close(&c)

	p: Playback
	wn, werr := playback_write(&p, buf[:])
	testing.expect_value(t, wn, 0)
	testing.expect_value(t, werr, Error.Closed)
	testing.expect_value(t, playback_writable(&p), 0)
	testing.expect_value(t, playback_queued(&p), 0)
	testing.expect_value(t, playback_underruns(&p), 0)
	testing.expect(t, playback_drained(&p), "nothing queued is drained")
	testing.expect_value(t, playback_error(&p), Error.Closed)
	playback_flush(&p)
	playback_close(&p)
	playback_close(&p)
}

@(test)
every_error_has_something_to_show_a_person :: proc(t: ^testing.T) {
	for e in Error {
		s := error_text(e)
		testing.expectf(t, len(s) > 0, "%v has no text", e)
		testing.expectf(t, s[0] >= 'a' && s[0] <= 'z', "%v reads as a sentence fragment: %q", e, s)
	}
}

// A sine written through a ring comes back as the same sine: the sanity
// check that the f32 path is a byte path and nothing is being converted.
@(test)
a_tone_survives_the_ring_unchanged :: proc(t: ^testing.T) {
	r: Ring
	ring_init(&r, 4096)
	defer ring_destroy(&r)

	tone: [1000]f32
	for &v, i in tone do v = math.sin_f32(2 * math.PI * 440 * f32(i) / 48_000)
	ring_write(&r, tone[:])

	back: [1000]f32
	testing.expect_value(t, ring_read(&r, back[:]), 1000)
	worst := f32(0)
	for v, i in back do worst = max(worst, abs(v - tone[i]))
	testing.expect_value(t, worst, 0) // bit for bit, not merely close
}

}
