#+build darwin
package main

// cocoa_clipboard — does the macOS clipboard round-trip through the real
// NSPasteboard?
//
// It cannot be a headless test: there is no pasteboard without a running
// window server, and the whole point is the system one that Cmd-C and Cmd-V
// use. So this sets it, reads it back, and prints what it got — run it, then
// paste into TextEdit to see the same text arrive somewhere else.
//
//   tools/mac-sync.sh run './build.sh spike cocoa_clipboard run'
//
// It takes no window and opens nothing.

import "core:fmt"
import "core:os"
import "core:strings"
import "baldr:platform"
import "baldr:platform/cocoa"

CASES := []string{
	"hello from Baldr",
	"",                                  // an empty string is a legitimate thing to copy
	"a\nb\tc",                           // newlines and tabs survive
	"déjà vu — ünïcödé, 日本語, 🇬🇧👨‍👩‍👧", // the NS.AT/CFSTR mangling trap
	"a string that is quite a lot longer than the others, " +
	"so that nothing depends on it fitting in some small buffer somewhere",
}

main :: proc() {
	b := cocoa.backend()
	if ok, why := b.init(b); !ok {
		fmt.eprintfln("cocoa init failed: %s", why)
		os.exit(1)
	}
	defer b.shutdown(b)

	if b.clipboard_set == nil || b.clipboard_get == nil {
		fmt.eprintln("the backend has no clipboard")
		os.exit(1)
	}

	bad := 0
	for want in CASES {
		if !b.clipboard_set(b, want) {
			fmt.printfln("  SET FAILED  %q", want)
			bad += 1
			continue
		}
		got, ok := b.clipboard_get(b, context.temp_allocator)
		switch {
		case !ok:
			// Note: an empty string *does* round-trip — AppKit hands back an
			// empty NSString rather than nil for one, so this is a real
			// failure, not the empty case.
			fmt.printfln("  GET FAILED  %q", want)
			bad += 1
		case got != want:
			fmt.printfln("  MISMATCH    set %q, got %q", want, got)
			bad += 1
		case:
			fmt.printfln("  ok          %q (%d bytes)", got, len(got))
		}
	}

	// Leave something behind to paste by hand, which is the part no
	// automated check can do: it proves the *system* board was written, not
	// a buffer of our own.
	last := "Baldr wrote this to the macOS clipboard — paste it somewhere."
	b.clipboard_set(b, last)
	fmt.printfln("\nclipboard now holds: %q", last)
	fmt.println("paste it into TextEdit to confirm it is the system board.")
	if bad > 0 {
		fmt.eprintfln("%d case(s) failed", bad)
		os.exit(1)
	}
	_ = strings.clone
	fmt.println("all cases round-tripped")
}
