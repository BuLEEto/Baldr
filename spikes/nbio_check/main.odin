package main

// Does core:nbio's read complete on this platform? It opens, stats, then
// reads with `all = true`, with nothing of Baldr in it. On Windows that read
// never calls back for a file shorter than the buffer (`.HANDLE_EOF` ends it
// only when nothing at all was read), so it re-arms for ever; pass "one" as
// the second argument for a single read, which completes.

import "core:fmt"
import "core:nbio"
import "core:os"
import "core:time"

State :: struct {
	handle: nbio.Handle,
	buf:    []u8,
	steps:  [4]bool, // open, stat, read, close
	done:   bool,
}

main :: proc() {
	path := "nbio_check.txt"
	if len(os.args) > 1 do path = os.args[1]
	if err := os.write_entire_file_from_bytes(path, transmute([]u8)string("hello from the spike\n")); err != nil {
		fmt.printfln("could not write %s: %v", path, err)
		return
	}
	if err := nbio.acquire_thread_event_loop(); err != nil {
		fmt.printfln("no event loop: %v (nbio unavailable here)", err)
		return
	}
	defer nbio.release_thread_event_loop()
	s: State

	on_close :: proc(o: ^nbio.Operation, s: ^State) {
		s.steps[3] = true
		s.done = true
	}
	on_read :: proc(o: ^nbio.Operation, s: ^State) {
		s.steps[2] = true
		fmt.printfln("read: %d bytes, err %v", o.read.read, o.read.err)
		nbio.close_poly(s.handle, s, on_close)
	}
	on_stat :: proc(o: ^nbio.Operation, s: ^State) {
		s.steps[1] = true
		fmt.printfln("stat: size %d, type %v, err %v", o.stat.size, o.stat.type, o.stat.err)
		s.buf = make([]u8, int(o.stat.size) + 1)
		// `all = true` asks nbio to keep reading until the buffer is full or
		// the file ends; `all = false` is one read.
		if len(os.args) > 2 && os.args[2] == "one" {
			nbio.read_poly(s.handle, 0, s.buf, s, on_read)
		} else {
			nbio.read_poly(s.handle, 0, s.buf, s, on_read, all = true)
		}
	}
	on_open :: proc(o: ^nbio.Operation, s: ^State) {
		s.steps[0] = true
		fmt.printfln("open: err %v", o.open.err)
		if o.open.err != .None {
			s.done = true
			return
		}
		s.handle = o.open.handle
		nbio.stat_poly(s.handle, s, on_stat)
	}
	nbio.open_poly(path, &s, on_open, mode = {.Read})

	start := time.tick_now()
	for !s.done && time.duration_seconds(time.tick_since(start)) < 5 {
		nbio.tick()
	}
	fmt.printfln("mode=%s opened=%v stat=%v read=%v closed=%v  (done=%v)", "one read" if len(os.args) > 2 && os.args[2] == "one" else "all", s.steps[0], s.steps[1], s.steps[2], s.steps[3], s.done)
	if !s.done do fmt.println("TIMED OUT — a callback never fired")
}
