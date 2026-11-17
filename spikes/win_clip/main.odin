#+build windows
package main

// win_clip — what the Windows clipboard has, and what the backend makes of
// it. No window and no Vulkan, so it runs over ssh: a test can put a picture
// on the clipboard with PowerShell and this says what Baldr reads back.
//
//   win_clip                 the forms on the clipboard now
//   win_clip <mime> <file>   read that form and write it to <file>
//   win_clip --set-text <s>  put text on the clipboard (offering it back)
//
// The bytes go to a file so the picture can be decoded away from Windows
// and checked against the one the test put there.

import "core:fmt"
import "core:os"
import "baldr:platform"
import "baldr:platform/win32"

main :: proc() {
	b := win32.backend()
	if ok, why := b.init(b); !ok {
		fmt.eprintln("init failed:", why)
		os.exit(1)
	}
	defer b.shutdown(b)

	args := os.args[1:]
	if len(args) >= 2 && args[0] == "--set-text" {
		fmt.println("set-text", b.clipboard_set_data(b, []platform.Clip_Item{{mime = "text/plain;charset=utf-8", data = transmute([]u8)args[1]}}))
		return
	}
	types := b.clipboard_types(b)
	fmt.println("types", len(types))
	for t in types do fmt.println("type", t)
	if len(args) < 2 do return

	data, ok := b.clipboard_get_data(b, args[0])
	if !ok {
		fmt.println("read", args[0], "none")
		return
	}
	fmt.println("read", args[0], len(data), "bytes")
	if err := os.write_entire_file(args[1], data); err != nil {
		fmt.println("write failed", args[1], err)
		return
	}
	fmt.println("wrote", args[1])
}
