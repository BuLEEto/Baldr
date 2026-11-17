// canvas_staging.odin — the buffers canvas work is copied through, kept and
// handed out again instead of made afresh.
//
// Every `canvas_write` needs memory the CPU writes and the GPU reads, let go
// when the batch that read it has finished. For video that is the whole
// frame (8 MB at 1080p, 33 MB at 4K) sixty times a second, and making it
// afresh is a create, allocate, map, unmap and free per frame for memory the
// same size as last frame's. So a finished buffer goes on an idle list and
// the next request of about that size takes it. The policy is shared code so
// both backends follow one; each supplies `canvas_buffer` (make one),
// `buffer_destroy`, and a `staging` field on its Renderer.
//
// Three rules keep the idle list from becoming a leak: a buffer is reused
// only for a request it is at most a quarter too big for, the list holds at
// most STAGING_FREE_BYTES, and a buffer unwanted for STAGING_IDLE_FLUSHES
// flushes is let go. A streaming app settles on the buffers it cycles, and
// one that stops streaming gives the memory back.
package gpu

// STAGING_SLACK bounds how much bigger than the request a reused buffer may
// be: `need + need / STAGING_SLACK`, so a quarter. A size that drifts a
// little (a window resized by a pixel, a stroke one segment longer) still
// reuses, and no reuse wastes more than a quarter; unbounded, a 33 MB frame
// buffer could end up serving a 64-byte curve.
@(private)
STAGING_SLACK :: 4

// STAGING_FREE_BYTES caps what the idle list holds. Past it a returned
// buffer is destroyed rather than kept: enough for several 4K frames in
// flight, not enough to hide a runaway.
@(private)
STAGING_FREE_BYTES :: 128 << 20

// STAGING_IDLE_FLUSHES is how many canvas flushes a buffer may go unwanted
// before it is let go — two seconds of a 60 fps stream, and far longer for
// an app that only draws when poked, since the count only moves when canvas
// work is flushed.
@(private)
STAGING_IDLE_FLUSHES :: 120

// Staging is the idle list and what it has done, on the Renderer.
@(private)
Staging :: struct {
	free:    [dynamic]Idle_Buffer,
	bytes:   int, // what `free` holds
	made:    u64, // buffers created, because none idle would do
	reused:  u64, // requests an idle buffer answered
	dropped: u64, // idle buffers let go (aged out, or the list was full)
}

// Idle_Buffer is a buffer waiting to be handed out again, and how many
// flushes it has waited.
@(private)
Idle_Buffer :: struct {
	buf:  Buffer,
	idle: u32,
}

// Canvas_Staging says what the staging buffers have cost: how many were
// created against how many requests an idle one answered, how many were let
// go, and what is waiting now. For a stream that reuses properly `made`
// stops rising while `reused` goes up once a frame. Read it with
// canvas_staging_stats (BALDR_DEBUG_CANVAS prints it).
Canvas_Staging :: struct {
	made, reused, dropped: u64,
	idle:                  int, // buffers waiting to be used again
	idle_bytes:            int,
}

// canvas_staging_stats is the staging pool's counters. Cheap; for a debug
// line or a spike measuring whether a stream allocates per frame.
canvas_staging_stats :: proc(r: ^Renderer) -> Canvas_Staging {
	if r == nil do return {}
	return {
		made = r.staging.made, reused = r.staging.reused, dropped = r.staging.dropped,
		idle = len(r.staging.free), idle_bytes = r.staging.bytes,
	}
}

// staging_fit picks the idle buffer to answer a request of `need` bytes for
// `use`: the smallest one at least that big and no more than a quarter
// bigger. Smallest first so a big buffer is not spent on a small write while
// a snug one sits idle. Separate from staging_reuse so the choice can be
// tested without a device.
@(private)
staging_fit :: proc(free: []Idle_Buffer, need: int, use: Buffer_Use) -> (int, bool) {
	best, found := 0, false
	for ib, i in free {
		if ib.buf.use != use || ib.buf.size < need do continue
		if ib.buf.size > need + need / STAGING_SLACK do continue
		if !found || ib.buf.size < free[best].buf.size do best, found = i, true
	}
	return best, found
}

// staging_reuse takes an idle buffer for the request, or says there was
// none. It never touches the device.
@(private)
staging_reuse :: proc(r: ^Renderer, need: int, use: Buffer_Use) -> (Buffer, bool) {
	if need <= 0 do return {}, false
	i, found := staging_fit(r.staging.free[:], need, use)
	if !found do return {}, false
	b := r.staging.free[i].buf
	unordered_remove(&r.staging.free, i)
	r.staging.bytes -= b.size
	r.staging.reused += 1
	return b, true
}

// staging_take is what canvas_queue.odin asks for when it needs a buffer the
// CPU writes and the GPU reads: an idle one of about that size, or a new one.
// The buffer is the caller's until it hands it back with staging_give (which
// the batch it is recorded into does).
@(private)
staging_take :: proc(r: ^Renderer, size: int, use: Buffer_Use) -> (Buffer, bool) {
	if b, ok := staging_reuse(r, size, use); ok do return b, true
	b, ok := canvas_buffer(r, size, use)
	if ok do r.staging.made += 1
	return b, ok
}

// staging_give takes a buffer back when the work that read it is done,
// either onto the idle list or, if that is full enough already, to the
// device. The caller's handle is spent either way.
@(private)
staging_give :: proc(r: ^Renderer, b: ^Buffer) {
	if b.size <= 0 || b.ptr == nil {
		buffer_destroy(r, b) // nothing, or not memory the CPU can write: not ours to keep
		return
	}
	if r.staging.bytes + b.size > STAGING_FREE_BYTES {
		r.staging.dropped += 1
		buffer_destroy(r, b)
		return
	}
	append(&r.staging.free, Idle_Buffer{buf = b^})
	r.staging.bytes += b.size
	b^ = {}
}

// staging_age lets go of the buffers nobody has wanted for a while. Called
// once per canvas_flush, so a burst's peak is not held for the rest of the
// run — and so the count only moves while there is canvas work, which is why
// an app that draws rarely keeps its buffers between draws.
@(private)
staging_age :: proc(r: ^Renderer) {
	for i := 0; i < len(r.staging.free); {
		r.staging.free[i].idle += 1
		if r.staging.free[i].idle > STAGING_IDLE_FLUSHES {
			b := r.staging.free[i].buf
			unordered_remove(&r.staging.free, i)
			r.staging.bytes -= b.size
			r.staging.dropped += 1
			buffer_destroy(r, &b)
			continue
		}
		i += 1
	}
}

// staging_clear lets every idle buffer go: the device has gone (recover.odin)
// or the renderer is shutting down. The counters stay, so a run's totals
// survive a reset.
@(private)
staging_clear :: proc(r: ^Renderer) {
	for &ib in r.staging.free {
		b := ib.buf
		r.staging.dropped += 1
		buffer_destroy(r, &b)
	}
	clear(&r.staging.free)
	r.staging.bytes = 0
}

// staging_shutdown clears the list and frees it: the renderer is going, or
// the device is being torn down to be rebuilt (recover.odin), which is why
// the counters are left alone — the run's totals carry on across a reset.
@(private)
staging_shutdown :: proc(r: ^Renderer) {
	staging_clear(r)
	delete(r.staging.free)
	r.staging.free, r.staging.bytes = nil, 0
}
