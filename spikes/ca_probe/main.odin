package main

// Which CoreAudio call refuses, and with what OSStatus. `capture_open`
// returning .No_Device on a box with no microphone is the right answer,
// but it is the same answer a wrong binding would give — so this prints
// the raw status of each step rather than the mapped error.
//
//	./build.sh spike ca_probe run

import "core:fmt"
import "baldr:audio"

main :: proc() {
	fmt.println("CoreAudio: which call refuses, and with what")
	p: audio.Playback
	perr := audio.playback_open(&p, audio.Format{48_000, 1})
	fmt.printfln("playback_open  -> %v", perr)
	if perr == .None do audio.playback_close(&p)

	c: audio.Capture
	cerr := audio.capture_open(&c, audio.Format{48_000, 1})
	fmt.printfln("capture_open   -> %v", cerr)
	if cerr == .None {
		fmt.printfln("  capture is open: %d Hz, %d ch", c.format.rate, c.format.channels)
		audio.capture_close(&c)
	}
	fmt.printfln("raw status trail: %v", audio.probe_last_status())
}
