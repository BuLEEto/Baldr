package audio

import "core:sync"

// Ring is a lock-free single-producer, single-consumer queue of f32
// samples: the one piece of machinery every backend needs, and the only
// one that can be tested without a sound card.
//
// Audio arrives on a thread the sound server owns and is read by the UI
// thread; neither may wait for the other (a dropped frame, or a glitch in
// the recording), so they meet here.
//
// One writer and one reader, no more: two of either corrupts it silently.
// A `Capture`'s writer is the server's thread and its reader the app; a
// `Playback`'s are the other way round.
//
// `w` and `r` count samples ever written and read; at 48 kHz a u64 lasts
// twelve million years. Counting instead of indexing tells "full" from
// "empty" without a third field.
Ring :: struct {
	buf:  []f32,
	mask: u64, // len(buf) - 1; len(buf) is always a power of two
	w:    u64, // atomic, written only by the producer
	r:    u64, // atomic, written only by the consumer
	lost: u64, // atomic, samples the producer could not fit
}

// ring_init allocates a ring holding at least `samples`, rounded up to a
// power of two. The memory is the caller's; `ring_destroy` frees it.
ring_init :: proc(ring: ^Ring, samples: int, allocator := context.allocator) -> bool {
	n := u64(1)
	for n < u64(max(samples, 2)) do n <<= 1
	buf, err := make([]f32, int(n), allocator)
	if err != nil do return false
	ring^ = {buf = buf, mask = n - 1}
	return true
}

ring_destroy :: proc(ring: ^Ring, allocator := context.allocator) {
	delete(ring.buf, allocator)
	ring^ = {}
}

// ring_capacity is how many samples the ring holds when empty.
ring_capacity :: proc(ring: ^Ring) -> int {
	return len(ring.buf)
}

// ring_available is how many samples a reader could take right now. Safe
// from either thread; from any other it is a guess that was true once.
ring_available :: proc(ring: ^Ring) -> int {
	w := sync.atomic_load_explicit(&ring.w, .Acquire)
	r := sync.atomic_load_explicit(&ring.r, .Acquire)
	return int(w - r)
}

// ring_free is how many samples a writer could add right now.
ring_free :: proc(ring: ^Ring) -> int {
	return ring_capacity(ring) - ring_available(ring)
}

// ring_write copies as much of `src` as fits and returns how many samples
// it took. Short means the reader is behind; the rest is the caller's to
// drop (`ring_write_lossy` counts it instead). Producer thread only.
ring_write :: proc(ring: ^Ring, src: []f32) -> int {
	w := sync.atomic_load_explicit(&ring.w, .Relaxed) // we are the only writer
	r := sync.atomic_load_explicit(&ring.r, .Acquire)
	n := min(len(src), ring_capacity(ring) - int(w - r))
	if n <= 0 do return 0
	at := int(w & ring.mask)
	first := min(n, len(ring.buf) - at)
	copy(ring.buf[at:], src[:first])
	if first < n do copy(ring.buf[:], src[first:n]) // wrapped
	sync.atomic_store_explicit(&ring.w, w + u64(n), .Release)
	return n
}

// ring_write_lossy writes what fits and counts the remainder as lost, for
// a producer with nowhere to put it — a capture callback must return
// whether or not the app has been reading. `ring_lost` reports the total.
ring_write_lossy :: proc(ring: ^Ring, src: []f32) -> int {
	n := ring_write(ring, src)
	if n < len(src) {
		sync.atomic_add_explicit(&ring.lost, u64(len(src) - n), .Relaxed)
	}
	return n
}

// ring_read copies up to `len(dst)` samples out and returns how many.
// Consumer thread only.
ring_read :: proc(ring: ^Ring, dst: []f32) -> int {
	r := sync.atomic_load_explicit(&ring.r, .Relaxed) // we are the only reader
	w := sync.atomic_load_explicit(&ring.w, .Acquire)
	n := min(len(dst), int(w - r))
	if n <= 0 do return 0
	at := int(r & ring.mask)
	first := min(n, len(ring.buf) - at)
	copy(dst[:first], ring.buf[at:])
	if first < n do copy(dst[first:n], ring.buf[:]) // wrapped
	sync.atomic_store_explicit(&ring.r, r + u64(n), .Release)
	return n
}

// ring_lost is the running total of samples the producer had to throw
// away. It only ever grows; keep the last value to see a new gap.
ring_lost :: proc(ring: ^Ring) -> int {
	return int(sync.atomic_load_explicit(&ring.lost, .Relaxed))
}

// ring_clear drops everything queued. Only safe to call with the producer
// stopped — it moves the reader's index to the writer's, and a producer
// running alongside may add more in between.
ring_clear :: proc(ring: ^Ring) {
	w := sync.atomic_load_explicit(&ring.w, .Acquire)
	sync.atomic_store_explicit(&ring.r, w, .Release)
}
