package baldr

// text/uri-list, the form files take on the clipboard and in a drag:
// one `file://` URI per line, percent-encoded, CRLF-separated, `#` lines
// are comments.

import "core:strings"
import "core:sys/posix"

// uri_list_encode writes local `paths` as a text/uri-list. The string is the
// caller's to free.
uri_list_encode :: proc(paths: []string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for p in paths {
		strings.write_string(&b, "file://")
		if len(p) > 0 && p[0] != '/' do strings.write_byte(&b, '/') // a relative path still needs the root slash
		for c in transmute([]u8)p {
			if uri_unreserved(c) || c == '/' {
				strings.write_byte(&b, c)
			} else {
				strings.write_byte(&b, '%')
				strings.write_byte(&b, HEX_UPPER[c >> 4])
				strings.write_byte(&b, HEX_UPPER[c & 15])
			}
		}
		strings.write_string(&b, "\r\n")
	}
	return strings.to_string(b)
}

// uri_list_decode returns the local paths of a text/uri-list. Comment lines
// and other schemes are skipped, and so is anything that is not plainly a
// file on this machine: a URI naming another host (whose path would
// otherwise be read as one here), a relative path, or one that decodes to a
// NUL. The slice and its strings are the caller's to free.
uri_list_decode :: proc(text: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	rest := text
	for len(rest) > 0 {
		line := rest
		if nl := strings.index_byte(rest, '\n'); nl >= 0 {
			line = rest[:nl]
			rest = rest[nl + 1:]
		} else {
			rest = ""
		}
		line = strings.trim_right(line, "\r ")
		if len(line) == 0 || line[0] == '#' do continue
		if !strings.has_prefix(line, "file:") do continue
		p := line[5:]
		if strings.has_prefix(p, "//") { // file://host/path
			p = p[2:]
			slash := strings.index_byte(p, '/')
			if slash < 0 do continue
			if !uri_host_is_local(p[:slash]) do continue
			p = p[slash:]
		}
		if len(p) == 0 || p[0] != '/' do continue
		path := uri_decode(p, allocator)
		if strings.index_byte(path, 0) >= 0 {
			delete(path, allocator)
			continue
		}
		append(&out, path)
	}
	return out[:]
}

// uri_host_is_local says whether a file URI's host is this machine: empty,
// `localhost`, or (where it can be asked) this machine's own name, which
// some file managers write.
@(private)
uri_host_is_local :: proc(host: string) -> bool {
	if host == "" || strings.equal_fold(host, "localhost") do return true
	when ODIN_OS == .Linux || ODIN_OS == .Darwin {
		name: [256]u8
		if posix.gethostname(raw_data(name[:]), len(name)) == .OK {
			return strings.equal_fold(host, string(cstring(raw_data(name[:]))))
		}
	}
	return false
}

@(private)
uri_decode :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if c == '%' && i + 2 < len(s) + 0 && i + 2 <= len(s) - 1 {
			hi, lo := hex_val(s[i + 1]), hex_val(s[i + 2])
			if hi >= 0 && lo >= 0 {
				strings.write_byte(&b, u8(hi << 4 | lo))
				i += 2
				continue
			}
		}
		strings.write_byte(&b, c)
	}
	return strings.to_string(b)
}

@(private)
HEX_UPPER := "0123456789ABCDEF"

@(private)
uri_unreserved :: proc(c: u8) -> bool {
	switch c {
	case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '.', '_', '~': return true
	}
	return false
}

@(private)
hex_val :: proc(c: u8) -> int {
	switch c {
	case '0' ..= '9': return int(c - '0')
	case 'a' ..= 'f': return int(c - 'a') + 10
	case 'A' ..= 'F': return int(c - 'A') + 10
	}
	return -1
}
