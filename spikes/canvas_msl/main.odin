// canvas_msl — does gpu/shaders/canvas.metal compile, and does it hold the
// functions the canvas passes ask for?
//
// The shipped code compiles this source at runtime with
// `newLibraryWithSource`, so compiling it the same way is both the fastest
// loop for porting a shader and a more faithful test than `xcrun metal`
// (which needs the full Metal toolchain, not just the command line tools).
// No window, no surface, no frame — a device and a string.
//
//   tools/mac-sync.sh run ./build.sh spike canvas_msl run
package main

import "core:fmt"
import "core:os"
import MTL "vendor:darwin/Metal"
import NS "vendor:darwin/AppKit"

SRC :: #load("../../gpu/shaders/canvas.metal", string)

// Every entry point the Metal canvas backend looks up. A library that
// compiles but is missing one fails just as badly, later and less clearly.
WANT := []string{
	"canvas_fs",
	"blend_main",
	"transform_main",
	"filter_main",
	"dab_vert", "dab_frag",
	"stroke_vert", "stroke_frag",
	"fill_main", "copy_main",
}

main :: proc() {
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()

	dev := MTL.CreateSystemDefaultDevice()
	if dev == nil {
		fmt.eprintln("no Metal device")
		os.exit(1)
	}
	fmt.printfln("device: %s", dev->name()->odinString())

	src := NS.String.alloc()->initWithOdinString(SRC)
	opts := MTL.CompileOptions.alloc()->init()
	defer opts->release()
	lib, err := dev->newLibraryWithSource(src, opts)
	if lib == nil {
		fmt.eprintln("canvas.metal did not compile:")
		if err != nil do fmt.eprintln(err->localizedDescription()->odinString())
		os.exit(1)
	}
	defer lib->release()
	fmt.printfln("canvas.metal compiled (%d bytes of source)", len(SRC))

	bad := 0
	for name in WANT {
		ns := NS.String.alloc()->initWithOdinString(name)
		fn := lib->newFunctionWithName(ns)
		if fn == nil {
			fmt.printfln("  MISSING  %s", name)
			bad += 1
		} else {
			fmt.printfln("  ok       %s", name)
			fn->release()
		}
	}
	if bad > 0 {
		fmt.eprintfln("%d function(s) missing", bad)
		os.exit(1)
	}
	fmt.println("all entry points present")
}
