#+build darwin
package main

// What the macOS pasteboard is offering, in the toolkit's terms, and what a
// copy puts there — the typed clipboard (`clipboard_types`,
// `clipboard_get_data`, `clipboard_set_data`) driven straight, with no UI
// in the way.
//
//   ./build.sh spike clip_check run                      # what is on the board
//   ./build.sh spike clip_check run get image/png /tmp/out.png
//   ./build.sh spike clip_check run get text/uri-list
//   ./build.sh spike clip_check run set-files /etc/hosts /etc/services
//   ./build.sh spike clip_check run set-png /tmp/some.png
//
// The point of it is that the other end is observable from a shell, so a
// claim can be checked both ways without trusting this program:
//
//   screencapture -c                     # a TIFF on the board (what a Mac copies)
//   ./build.sh spike clip_check run get image/png /tmp/shot.png
//   sips -g pixelWidth -g pixelHeight /tmp/shot.png     # a real PNG, or not
//
//   osascript -e 'set the clipboard to POSIX file "/etc/hosts"'
//   ./build.sh spike clip_check run get text/uri-list   # file:///etc/hosts
//
//   ./build.sh spike clip_check run set-files /etc/hosts
//   osascript -e 'POSIX path of (the clipboard as «class furl»)'   # /etc/hosts

import "core:fmt"
import "core:os"
import "core:strings"
import "baldr:platform"
import "baldr:platform/cocoa"

main :: proc() {
	b := cocoa.backend()
	args := os.args[1:]
	if len(args) == 0 {
		report(b)
		return
	}
	switch args[0] {
	case "get":
		if len(args) < 2 {
			fmt.eprintln("get needs a mime type")
			os.exit(2)
		}
		data, ok := b.clipboard_get_data(b, args[1], context.allocator)
		if !ok {
			fmt.printfln("%s: nothing", args[1])
			os.exit(1)
		}
		fmt.printfln("%s: %d bytes", args[1], len(data))
		if len(args) >= 3 {
			if werr := os.write_entire_file(args[2], data); werr != nil {
				fmt.eprintfln("could not write %s: %v", args[2], werr)
				os.exit(1)
			}
			fmt.printfln("written to %s", args[2])
		} else if strings.has_prefix(args[1], "text/") {
			fmt.printfln("---\n%s\n---", string(data))
		}
	case "set-files":
		if len(args) < 2 {
			fmt.eprintln("set-files needs at least one path")
			os.exit(2)
		}
		list := strings.builder_make()
		for p in args[1:] {
			strings.write_string(&list, "file://")
			strings.write_string(&list, p) // the paths this is run with have nothing to escape
			strings.write_string(&list, "\r\n")
		}
		item := platform.Clip_Item{mime = "text/uri-list", data = transmute([]u8)strings.to_string(list)}
		fmt.printfln("set-files: %v", b.clipboard_set_data(b, {item}))
		report(b)
	case "set-png":
		if len(args) < 2 {
			fmt.eprintln("set-png needs a file")
			os.exit(2)
		}
		png, rerr := os.read_entire_file_from_path(args[1], context.allocator)
		if rerr != nil {
			fmt.eprintfln("could not read %s: %v", args[1], rerr)
			os.exit(1)
		}
		items := [2]platform.Clip_Item{
			{mime = "image/png", data = png},
			{mime = "text/plain;charset=utf-8", data = transmute([]u8)string("a picture copied by clip_check")},
		}
		fmt.printfln("set-png: %v", b.clipboard_set_data(b, items[:]))
		report(b)
	case:
		fmt.eprintfln("unknown command %q", args[0])
		os.exit(2)
	}
}

report :: proc(b: ^platform.Backend) {
	types := b.clipboard_types(b, context.allocator)
	if len(types) == 0 {
		fmt.println("the pasteboard offers nothing this toolkit reads")
		return
	}
	fmt.printfln("the pasteboard offers %d form(s):", len(types))
	for t in types {
		data, ok := b.clipboard_get_data(b, t, context.allocator)
		if !ok {
			fmt.printfln("   %-26s (nothing came back)", t)
			continue
		}
		defer delete(data)
		if strings.has_prefix(t, "text/") {
			one := string(data)
			if i := strings.index_byte(one, '\n'); i >= 0 do one = one[:i]
			if len(one) > 60 do one = one[:60]
			fmt.printfln("   %-26s %6d bytes   %q", t, len(data), strings.trim_space(one))
		} else {
			fmt.printfln("   %-26s %6d bytes   %s", t, len(data), head_bytes(data))
		}
	}
}

// head_bytes names a picture by its first few bytes, so a form that says
// image/png and is not one shows up here rather than in a decoder.
head_bytes :: proc(data: []u8) -> string {
	switch {
	case len(data) >= 8 && string(data[:8]) == "\x89PNG\r\n\x1a\n": return "a PNG"
	case len(data) >= 3 && data[0] == 0xff && data[1] == 0xd8:     return "a JPEG"
	case len(data) >= 4 && (string(data[:4]) == "II*\x00" || string(data[:4]) == "MM\x00*"): return "a TIFF"
	}
	return "not a form this knows"
}
