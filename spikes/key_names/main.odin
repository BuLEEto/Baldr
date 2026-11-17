#+build darwin
package main

// What this Mac's keyboard layout calls each key (Backend.key_name).
//
//   ./build.sh spike key_names run
//
// The virtual key codes are positional, so the *names* move with the
// layout and the codes do not: switch the input source to French and
// code 12 should stop saying "q" and start saying "a", which is why the
// layout is asked rather than a table printed.

import "core:fmt"
import "baldr:platform/cocoa"

// The home row's codes, some punctuation, and a few that type nothing.
CODES := []u32{12, 13, 14, 15, 17, 16, 0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39,
	43, 47, 44, 27, 24, 36, 48, 49, 53, 123, 124, 125, 126, 122, 96}

main :: proc() {
	fmt.println("code  name")
	for c in CODES {
		n := cocoa.key_name_of(c, context.temp_allocator)
		fmt.printfln("%4d  %q%s", c, n, "" if n != "" else "   (types nothing printable, and not in the table)")
	}
}
