// Wire format: encoding Values and Messages to bytes and decoding bytes back,
// per the D-Bus Specification "Type System" and "Message Format" sections.
//
// Encoding always writes little-endian ('l'), byte by byte, so it is correct
// on any host. Decoding honours the message's own endianness flag because a
// bus forwards messages from other clients verbatim.
//
// Alignment: y g v → 1, n q → 2, b i u s o h a → 4, x t d ( { → 8. An
// array's length is followed by padding to its *element* alignment (even
// for an empty array) and that padding is not counted in the length.
// Padding bytes must be zero; the decoder checks.
package dbus

import "base:runtime"
import "core:unicode/utf8"

// Builder accumulates encoded bytes. `err` is sticky: the first failure
// wins and every later put is a no-op, so callers can check once at the end.
Builder :: struct {
	buf: [dynamic]u8,
	err: Error,
}

// builder_init prepares b to append into `allocator`.
builder_init :: proc(b: ^Builder, allocator := context.allocator) {
	b.buf = make([dynamic]u8, allocator)
	b.err = .None
}

// builder_destroy frees the buffer.
builder_destroy :: proc(b: ^Builder) {
	delete(b.buf)
	b^ = {}
}

@(private)
put_pad :: proc(b: ^Builder, n: int) {
	for len(b.buf) % n != 0 do append(&b.buf, 0)
}

@(private)
put_u8 :: proc(b: ^Builder, v: u8) {
	append(&b.buf, v)
}

@(private)
put_u16 :: proc(b: ^Builder, v: u16) {
	append(&b.buf, u8(v), u8(v >> 8))
}

@(private)
put_u32 :: proc(b: ^Builder, v: u32) {
	append(&b.buf, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}

@(private)
put_u64 :: proc(b: ^Builder, v: u64) {
	put_u32(b, u32(v))
	put_u32(b, u32(v >> 32))
}

// put_u32_at back-patches an array length.
@(private)
put_u32_at :: proc(b: ^Builder, at: int, v: u32) {
	b.buf[at + 0] = u8(v)
	b.buf[at + 1] = u8(v >> 8)
	b.buf[at + 2] = u8(v >> 16)
	b.buf[at + 3] = u8(v >> 24)
}

// put_str writes a `s`/`o` body: u32 length, bytes, NUL. Caller aligns.
@(private)
put_str :: proc(b: ^Builder, s: string) -> bool {
	if len(s) > MAX_MESSAGE_LEN || !utf8.valid_string(s) do return false
	for i := 0; i < len(s); i += 1 {
		if s[i] == 0 do return false
	}
	put_u32(b, u32(len(s)))
	append(&b.buf, ..transmute([]u8)s)
	append(&b.buf, 0)
	return true
}

// put_sig writes a `g` body: u8 length, bytes, NUL.
@(private)
put_sig :: proc(b: ^Builder, s: string) -> bool {
	if !signature_valid(s) do return false
	put_u8(b, u8(len(s)))
	append(&b.buf, ..transmute([]u8)s)
	append(&b.buf, 0)
	return true
}

// value_matches_sig checks, without allocating, that v encodes to exactly
// the complete type sig. Used to keep array elements honest: an array whose
// items disagree with its declared element type would corrupt the message.
value_matches_sig :: proc(v: Value, sig: string, depth := 0) -> bool {
	if len(sig) == 0 || depth > MAX_DEPTH do return false
	switch x in v {
	case bool:        return sig == "b"
	case u8:          return sig == "y"
	case i16:         return sig == "n"
	case u16:         return sig == "q"
	case i32:         return sig == "i"
	case u32:         return sig == "u"
	case i64:         return sig == "x"
	case u64:         return sig == "t"
	case f64:         return sig == "d"
	case string:      return sig == "s"
	case Object_Path: return sig == "o"
	case Signature:   return sig == "g"
	case Unix_Fd:     return sig == "h"
	case []u8:        return sig == "ay"
	case Variant:     return sig == "v"
	case Array:
		return sig[0] == 'a' && sig[1:] == x.sig
	case Dict:
		if len(sig) < 4 || sig[0] != 'a' || sig[1] != '{' || sig[len(sig) - 1] != '}' do return false
		inner := sig[2:len(sig) - 1]
		if len(inner) < len(x.key_sig) || inner[:len(x.key_sig)] != x.key_sig do return false
		return inner[len(x.key_sig):] == x.value_sig
	case Struct:
		if len(x.fields) == 0 || sig[0] != '(' || sig[len(sig) - 1] != ')' do return false
		rest := sig[1:len(sig) - 1]
		for f in x.fields {
			n := signature_first(rest)
			if n == 0 || !value_matches_sig(f, rest[:n], depth + 1) do return false
			rest = rest[n:]
		}
		return len(rest) == 0
	case nil:
		return false
	}
	return false
}

// encode_value appends v (aligned for its type) to b. Failure modes: nil
// value, invalid string/path/signature, array element mismatch, nesting
// deeper than MAX_DEPTH, array longer than MAX_ARRAY_LEN. On failure
// b.err is set and later puts are ignored.
encode_value :: proc(b: ^Builder, v: Value, depth := 0) {
	if b.err != .None do return
	if depth > MAX_DEPTH {
		b.err = .Invalid_Message
		return
	}
	switch x in v {
	case bool:
		put_pad(b, 4)
		put_u32(b, 1 if x else 0)
	case u8:
		put_u8(b, x)
	case i16:
		put_pad(b, 2)
		put_u16(b, u16(x))
	case u16:
		put_pad(b, 2)
		put_u16(b, x)
	case i32:
		put_pad(b, 4)
		put_u32(b, u32(x))
	case u32:
		put_pad(b, 4)
		put_u32(b, x)
	case i64:
		put_pad(b, 8)
		put_u64(b, u64(x))
	case u64:
		put_pad(b, 8)
		put_u64(b, x)
	case f64:
		put_pad(b, 8)
		put_u64(b, transmute(u64)x)
	case string:
		put_pad(b, 4)
		if !put_str(b, x) do b.err = .Invalid_Message
	case Object_Path:
		put_pad(b, 4)
		if !object_path_valid(x.path) || !put_str(b, x.path) do b.err = .Invalid_Message
	case Signature:
		if !put_sig(b, x.sig) do b.err = .Invalid_Message
	case Unix_Fd:
		put_pad(b, 4)
		put_u32(b, u32(x))
	case []u8:
		if len(x) > MAX_ARRAY_LEN {
			b.err = .Too_Large
			return
		}
		put_pad(b, 4)
		put_u32(b, u32(len(x)))
		append(&b.buf, ..x)
	case Array:
		if !signature_is_single(x.sig) {
			b.err = .Invalid_Message
			return
		}
		put_pad(b, 4)
		len_at := len(b.buf)
		put_u32(b, 0)
		put_pad(b, alignment_of(x.sig[0]))
		start := len(b.buf)
		for it in x.items {
			if !value_matches_sig(it, x.sig, depth + 1) {
				b.err = .Invalid_Message
				return
			}
			encode_value(b, it, depth + 1)
		}
		if !finish_array(b, len_at, start) do return
	case Dict:
		if len(x.key_sig) != 1 || !is_basic_code(x.key_sig[0]) || !signature_is_single(x.value_sig) {
			b.err = .Invalid_Message
			return
		}
		put_pad(b, 4)
		len_at := len(b.buf)
		put_u32(b, 0)
		put_pad(b, 8)
		start := len(b.buf)
		for e in x.entries {
			if !value_matches_sig(e.key, x.key_sig, depth + 1) || !value_matches_sig(e.value, x.value_sig, depth + 1) {
				b.err = .Invalid_Message
				return
			}
			put_pad(b, 8)
			encode_value(b, e.key, depth + 1)
			encode_value(b, e.value, depth + 1)
		}
		if !finish_array(b, len_at, start) do return
	case Struct:
		if len(x.fields) == 0 {
			b.err = .Invalid_Message
			return
		}
		put_pad(b, 8)
		for f in x.fields do encode_value(b, f, depth + 1)
	case Variant:
		if x.value == nil {
			b.err = .Invalid_Message
			return
		}
		sig: [MAX_SIGNATURE_LEN + 1]u8
		n := write_signature(sig[:], x.value^)
		if n == 0 || !put_sig(b, string(sig[:n])) {
			b.err = .Invalid_Message
			return
		}
		encode_value(b, x.value^, depth + 1)
	case nil:
		b.err = .Invalid_Message
	}
}

// finish_array back-patches the length of an array whose elements began at
// `start`; false (and b.err) if the array exceeds MAX_ARRAY_LEN.
@(private)
finish_array :: proc(b: ^Builder, len_at, start: int) -> bool {
	if b.err != .None do return false
	n := len(b.buf) - start
	if n > MAX_ARRAY_LEN {
		b.err = .Too_Large
		return false
	}
	put_u32_at(b, len_at, u32(n))
	return true
}

// write_signature writes v's signature into buf without allocating; returns
// the length, or 0 if it does not fit or v is not encodable.
@(private)
write_signature :: proc(buf: []u8, v: Value, depth := 0) -> int {
	if depth > MAX_DEPTH || len(buf) == 0 do return 0
	put1 :: proc(buf: []u8, c: u8) -> int {
		if len(buf) < 1 do return 0
		buf[0] = c
		return 1
	}
	puts :: proc(buf: []u8, s: string) -> int {
		if len(buf) < len(s) || len(s) == 0 do return 0
		copy(buf, transmute([]u8)s)
		return len(s)
	}
	switch x in v {
	case bool:        return put1(buf, 'b')
	case u8:          return put1(buf, 'y')
	case i16:         return put1(buf, 'n')
	case u16:         return put1(buf, 'q')
	case i32:         return put1(buf, 'i')
	case u32:         return put1(buf, 'u')
	case i64:         return put1(buf, 'x')
	case u64:         return put1(buf, 't')
	case f64:         return put1(buf, 'd')
	case string:      return put1(buf, 's')
	case Object_Path: return put1(buf, 'o')
	case Signature:   return put1(buf, 'g')
	case Unix_Fd:     return put1(buf, 'h')
	case Variant:     return put1(buf, 'v')
	case []u8:        return puts(buf, "ay")
	case Array:
		if put1(buf, 'a') == 0 do return 0
		n := puts(buf[1:], x.sig)
		return 0 if n == 0 else 1 + n
	case Dict:
		n := puts(buf, "a{")
		if n == 0 do return 0
		k := puts(buf[n:], x.key_sig)
		if k == 0 do return 0
		n += k
		w := puts(buf[n:], x.value_sig)
		if w == 0 do return 0
		n += w
		if put1(buf[n:], '}') == 0 do return 0
		return n + 1
	case Struct:
		if len(x.fields) == 0 do return 0
		n := put1(buf, '(')
		for f in x.fields {
			w := write_signature(buf[n:], f, depth + 1)
			if w == 0 do return 0
			n += w
		}
		if put1(buf[n:], ')') == 0 do return 0
		return n + 1
	case nil:
		return 0
	}
	return 0
}

// encode_body encodes a body (a sequence of complete values) starting at an
// 8-aligned origin, i.e. as it would sit after the header. Returns the bytes
// (allocated from `allocator`) and the body signature.
encode_body :: proc(body: []Value, allocator := context.allocator) -> (bytes: []u8, sig: string, err: Error) {
	b: Builder
	builder_init(&b, allocator)
	for v in body do encode_value(&b, v)
	if b.err != .None {
		err = b.err // read before destroy zeroes the builder
		builder_destroy(&b)
		return nil, "", err
	}
	sigbuf: [MAX_SIGNATURE_LEN + 1]u8
	n := 0
	for v in body {
		w := write_signature(sigbuf[n:], v)
		if w == 0 {
			builder_destroy(&b)
			return nil, "", .Invalid_Message
		}
		n += w
	}
	sigout := make([]u8, n, allocator)
	copy(sigout, sigbuf[:n])
	return b.buf[:], string(sigout), .None
}

// encode_message serialises m (header + body) into a new byte slice from
// `allocator`. `m.serial` must be non-zero (the connection assigns it);
// `m.signature` is overwritten with the body's signature (allocated from
// `allocator` too; "" for an empty body). Failure modes: missing required
// header fields for the type, invalid names/paths, unencodable body.
encode_message :: proc(m: ^Message, allocator := context.allocator) -> ([]u8, Error) {
	if m.serial == 0 do return nil, .Invalid_Message
	switch m.type {
	case .Method_Call:
		if !object_path_valid(m.path) || !member_name_valid(m.member) do return nil, .Invalid_Message
		if m.interface != "" && !interface_name_valid(m.interface) do return nil, .Invalid_Message
	case .Method_Return:
		if m.reply_serial == 0 do return nil, .Invalid_Message
	case .Error:
		if m.reply_serial == 0 || !interface_name_valid(m.error_name) do return nil, .Invalid_Message
	case .Signal:
		if !object_path_valid(m.path) || !interface_name_valid(m.interface) || !member_name_valid(m.member) do return nil, .Invalid_Message
	case .Invalid:
		return nil, .Invalid_Message
	}
	if m.destination != "" && !bus_name_valid(m.destination) do return nil, .Invalid_Message
	if m.sender != "" && !bus_name_valid(m.sender) do return nil, .Invalid_Message
	if len(m.fds) > int(max(u32)) do return nil, .Too_Large

	body, sig, berr := encode_body(m.body, allocator)
	if berr != .None do return nil, berr
	m.signature = sig

	b: Builder
	builder_init(&b, allocator)
	put_u8(&b, 'l')
	put_u8(&b, u8(m.type))
	put_u8(&b, transmute(u8)m.flags)
	put_u8(&b, PROTOCOL_VERSION)
	put_u32(&b, u32(len(body)))
	put_u32(&b, m.serial)
	put_u32(&b, 0) // header field array length, patched below
	// Fields: a(yv). The array's elements start at offset 16 (8-aligned already).
	fields_start := len(b.buf)
	field_str :: proc(b: ^Builder, code: Header_Field, type_code: u8, s: string) {
		if s == "" do return
		put_pad(b, 8)
		put_u8(b, u8(code))
		put_u8(b, 1)
		put_u8(b, type_code)
		put_u8(b, 0)
		put_pad(b, 4)
		if !put_str(b, s) do b.err = .Invalid_Message
	}
	field_u32 :: proc(b: ^Builder, code: Header_Field, v: u32) {
		put_pad(b, 8)
		put_u8(b, u8(code))
		put_u8(b, 1)
		put_u8(b, 'u')
		put_u8(b, 0)
		put_pad(b, 4)
		put_u32(b, v)
	}
	field_str(&b, .Path, 'o', m.path)
	field_str(&b, .Interface, 's', m.interface)
	field_str(&b, .Member, 's', m.member)
	field_str(&b, .Error_Name, 's', m.error_name)
	if m.reply_serial != 0 do field_u32(&b, .Reply_Serial, m.reply_serial)
	field_str(&b, .Destination, 's', m.destination)
	field_str(&b, .Sender, 's', m.sender)
	if len(sig) > 0 {
		put_pad(&b, 8)
		put_u8(&b, u8(Header_Field.Signature))
		put_u8(&b, 1)
		put_u8(&b, 'g')
		put_u8(&b, 0)
		if !put_sig(&b, sig) do b.err = .Invalid_Message
	}
	if len(m.fds) > 0 do field_u32(&b, .Unix_Fds, u32(len(m.fds)))
	put_u32_at(&b, 12, u32(len(b.buf) - fields_start))
	put_pad(&b, 8)
	append(&b.buf, ..body)
	delete(body, allocator)
	if b.err == .None && len(b.buf) > MAX_MESSAGE_LEN do b.err = .Too_Large
	if b.err != .None {
		err := b.err // read before destroy zeroes the builder
		builder_destroy(&b)
		return nil, err
	}
	return b.buf[:], .None
}

// ------------------------------------------------------------------ reader

// Reader decodes from a byte slice. `big` selects the byte order; `fd_count`
// bounds `h` indices; `depth` guards recursion. Every read bounds-checks.
Reader :: struct {
	buf:       []u8,
	pos:       int,
	big:       bool,
	fd_count:  u32,
	depth:     int,
	allocator: runtime.Allocator,
}

@(private)
r_need :: proc(r: ^Reader, n: int) -> bool {
	return n >= 0 && n <= len(r.buf) - r.pos
}

// r_align skips to the next multiple of n, requiring the skipped bytes to be zero.
@(private)
r_align :: proc(r: ^Reader, n: int) -> bool {
	for r.pos % n != 0 {
		if r.pos >= len(r.buf) || r.buf[r.pos] != 0 do return false
		r.pos += 1
	}
	return true
}

@(private)
r_u8 :: proc(r: ^Reader) -> (u8, bool) {
	if !r_need(r, 1) do return 0, false
	v := r.buf[r.pos]
	r.pos += 1
	return v, true
}

@(private)
r_u16 :: proc(r: ^Reader) -> (u16, bool) {
	if !r_align(r, 2) || !r_need(r, 2) do return 0, false
	p := r.buf[r.pos:]
	r.pos += 2
	if r.big do return u16(p[0]) << 8 | u16(p[1]), true
	return u16(p[1]) << 8 | u16(p[0]), true
}

@(private)
r_u32 :: proc(r: ^Reader) -> (u32, bool) {
	if !r_align(r, 4) || !r_need(r, 4) do return 0, false
	p := r.buf[r.pos:]
	r.pos += 4
	if r.big do return u32(p[0]) << 24 | u32(p[1]) << 16 | u32(p[2]) << 8 | u32(p[3]), true
	return u32(p[3]) << 24 | u32(p[2]) << 16 | u32(p[1]) << 8 | u32(p[0]), true
}

@(private)
r_u64 :: proc(r: ^Reader) -> (u64, bool) {
	if !r_align(r, 8) || !r_need(r, 8) do return 0, false
	p := r.buf[r.pos:]
	r.pos += 8
	v: u64
	for i := 0; i < 8; i += 1 {
		if r.big do v = v << 8 | u64(p[i])
		else do v |= u64(p[i]) << (8 * uint(i))
	}
	return v, true
}

// r_str reads a `s`/`o` body (after the caller's u32 length), validating the
// NUL terminator, UTF-8, and absence of embedded NUL. Clones into r.allocator.
@(private)
r_str :: proc(r: ^Reader, n: u32) -> (string, bool) {
	if n > u32(MAX_MESSAGE_LEN) || !r_need(r, int(n) + 1) do return "", false
	raw := r.buf[r.pos:r.pos + int(n)]
	if r.buf[r.pos + int(n)] != 0 do return "", false
	r.pos += int(n) + 1
	for c in raw do if c == 0 do return "", false
	s := string(raw)
	if !utf8.valid_string(s) do return "", false
	out := make([]u8, len(raw), r.allocator)
	copy(out, raw)
	return string(out), true
}

@(private)
r_string :: proc(r: ^Reader) -> (string, bool) {
	n, ok := r_u32(r)
	if !ok do return "", false
	return r_str(r, n)
}

@(private)
r_signature :: proc(r: ^Reader) -> (string, bool) {
	n, ok := r_u8(r)
	if !ok do return "", false
	s, sok := r_str(r, u32(n))
	if !sok || !signature_valid(s) do return "", false
	return s, true
}

// decode_value reads one value of complete type `sig` (which the caller has
// validated with signature_first). Everything allocated comes from
// r.allocator. ok=false means the bytes do not match the signature: the
// message is malformed and the reader's position is unspecified.
decode_value :: proc(r: ^Reader, sig: string) -> (v: Value, ok: bool) {
	if len(sig) == 0 || r.depth > MAX_DEPTH do return nil, false
	switch sig[0] {
	case 'y':
		x, xok := r_u8(r)
		return x, xok
	case 'b':
		x, xok := r_u32(r)
		if !xok || x > 1 do return nil, false
		return x == 1, true
	case 'n':
		x, xok := r_u16(r)
		return i16(x), xok
	case 'q':
		x, xok := r_u16(r)
		return x, xok
	case 'i':
		x, xok := r_u32(r)
		return i32(x), xok
	case 'u':
		x, xok := r_u32(r)
		return x, xok
	case 'x':
		x, xok := r_u64(r)
		return i64(x), xok
	case 't':
		x, xok := r_u64(r)
		return x, xok
	case 'd':
		x, xok := r_u64(r)
		return transmute(f64)x, xok
	case 'h':
		x, xok := r_u32(r)
		if !xok || x >= r.fd_count do return nil, false
		return Unix_Fd(x), true
	case 's':
		s, sok := r_string(r)
		return s, sok
	case 'o':
		s, sok := r_string(r)
		if !sok || !object_path_valid(s) do return nil, false
		return Object_Path{s}, true
	case 'g':
		s, sok := r_signature(r)
		return Signature{s}, sok
	case 'v':
		vsig, sok := r_signature(r)
		if !sok do return nil, false
		defer delete(vsig, r.allocator) // not kept: a Variant carries its value, the signature is implied
		if !signature_is_single(vsig) do return nil, false
		r.depth += 1
		defer r.depth -= 1
		inner, iok := decode_value(r, vsig)
		if !iok do return nil, false
		box := new(Value, r.allocator)
		box^ = inner
		return Variant{value = box}, true
	case 'a':
		return decode_array(r, sig[1:])
	case '(':
		if len(sig) < 3 || sig[len(sig) - 1] != ')' do return nil, false
		if !r_align(r, 8) do return nil, false
		r.depth += 1
		defer r.depth -= 1
		rest := sig[1:len(sig) - 1]
		fields := make([dynamic]Value, r.allocator)
		for len(rest) > 0 {
			n := signature_first(rest)
			if n == 0 do return nil, false
			f, fok := decode_value(r, rest[:n])
			if !fok do return nil, false
			append(&fields, f)
			rest = rest[n:]
		}
		return Struct{fields = fields[:]}, true
	}
	return nil, false
}

// decode_array reads an array whose element signature is `elem`. Byte arrays
// become []u8, dict entries become a Dict, everything else an Array.
@(private)
decode_array :: proc(r: ^Reader, elem: string) -> (Value, bool) {
	if signature_first(elem, 0, true) != len(elem) do return nil, false
	n, nok := r_u32(r)
	if !nok || n > u32(MAX_ARRAY_LEN) do return nil, false
	if !r_align(r, alignment_of(elem[0])) do return nil, false
	if !r_need(r, int(n)) do return nil, false
	end := r.pos + int(n)
	r.depth += 1
	defer r.depth -= 1

	if elem == "y" {
		out := make([]u8, n, r.allocator)
		copy(out, r.buf[r.pos:end])
		r.pos = end
		return out, true
	}
	if elem[0] == '{' {
		key_sig := elem[1:2]
		value_sig := elem[2:len(elem) - 1]
		entries := make([dynamic]Dict_Entry, r.allocator)
		for r.pos < end {
			if len(entries) >= MAX_ARRAY_ITEMS do return nil, false
			if !r_align(r, 8) do return nil, false
			k, kok := decode_value(r, key_sig)
			if !kok do return nil, false
			v, vok := decode_value(r, value_sig)
			if !vok do return nil, false
			append(&entries, Dict_Entry{key = k, value = v})
		}
		if r.pos != end do return nil, false
		ks := make([]u8, 1, r.allocator)
		ks[0] = key_sig[0]
		vs := make([]u8, len(value_sig), r.allocator)
		copy(vs, value_sig)
		return Dict{key_sig = string(ks), value_sig = string(vs), entries = entries[:]}, true
	}
	items := make([dynamic]Value, r.allocator)
	for r.pos < end {
		if len(items) >= MAX_ARRAY_ITEMS do return nil, false
		it, iok := decode_value(r, elem)
		if !iok do return nil, false
		append(&items, it)
	}
	if r.pos != end do return nil, false
	es := make([]u8, len(elem), r.allocator)
	copy(es, elem)
	return Array{sig = string(es), items = items[:]}, true
}

// ------------------------------------------------------------------ message

// Frame_Status is what frame_length learned from the first bytes of a buffer.
Frame_Status :: enum u8 {
	Incomplete, // fewer than 16 bytes: read more
	Ok,         // `total` is the full message length (may still exceed what is buffered)
	Bad,        // not a D-Bus message (endianness/version/size): protocol violation
}

// frame_length inspects a fixed header and returns the total message length
// (header + padded fields + body). It is how the connection splits the byte
// stream into messages before decoding anything.
frame_length :: proc(buf: []u8) -> (total: int, st: Frame_Status) {
	if len(buf) < 16 do return 0, .Incomplete
	big: bool
	switch buf[0] {
	case 'l': big = false
	case 'B': big = true
	case:     return 0, .Bad
	}
	if buf[3] != PROTOCOL_VERSION do return 0, .Bad
	r := Reader{buf = buf, pos = 4, big = big}
	body_len, _ := r_u32(&r)
	_, _ = r_u32(&r) // serial
	fields_len, _ := r_u32(&r)
	if fields_len > u32(MAX_ARRAY_LEN) || body_len > u32(MAX_MESSAGE_LEN) do return 0, .Bad
	padded := (int(fields_len) + 7) &~ 7
	total = 16 + padded + int(body_len)
	if total > MAX_MESSAGE_LEN do return 0, .Bad
	return total, .Ok
}

// decode_message parses exactly one complete message (buf is precisely
// `frame_length` bytes; the connection guarantees this). Strings and body
// values are allocated from `allocator`. `fds` is the pool of descriptors
// received so far; the UNIX_FDS header field says how many belong to this
// message and `m.fds` becomes that prefix view (`h` values index below it).
// Returns .Protocol for any malformation: unknown header field types,
// missing required fields, more fds claimed than received, body not
// matching its signature, non-zero padding, trailing bytes.
decode_message :: proc(buf: []u8, allocator := context.allocator, fds: []i32 = nil) -> (m: Message, err: Error) {
	total, st := frame_length(buf)
	if st != .Ok || total != len(buf) do return {}, .Protocol
	r := Reader{buf = buf, pos = 1, big = buf[0] == 'B', allocator = allocator}
	t, _ := r_u8(&r)
	flags, _ := r_u8(&r)
	_, _ = r_u8(&r) // version, checked by frame_length
	body_len, _ := r_u32(&r)
	serial, _ := r_u32(&r)
	if serial == 0 do return {}, .Protocol
	m.type = Message_Type(t) if t <= u8(Message_Type.Signal) else .Invalid
	m.flags = transmute(Flags)(flags & 0b111)
	m.serial = serial

	fields, fok := decode_value(&r, "a(yv)")
	if !fok do return {}, .Protocol
	// Walk the header fields, moving the strings we keep into m and freeing
	// the scaffolding (array, structs, variant boxes, unused values) so a
	// heap allocator sees no leak on the success path.
	farr := fields.(Array)
	seen: bit_set[Header_Field]
	ferr: Error
	for f in farr.items {
		s := f.(Struct)
		code := Header_Field(s.fields[0].(u8))
		box := s.fields[1].(Variant).value
		adopted := false
		if ferr == .None {
			switch {
			case code == .Invalid || code > .Unix_Fds: // unknown fields must be ignored
			case code in seen:
				ferr = .Protocol
			case:
				seen += {code}
				adopted, ferr = adopt_field(&m, code, box^, fds)
			}
		}
		if !adopted do value_destroy(box^, allocator)
		free(box, allocator)
		delete(s.fields, allocator)
	}
	delete(farr.items, allocator)
	delete(farr.sig, allocator)
	if ferr == .None {
		switch m.type {
		case .Method_Call:
			if m.path == "" || m.member == "" do ferr = .Protocol
		case .Method_Return:
			if m.reply_serial == 0 do ferr = .Protocol
		case .Error:
			if m.error_name == "" || m.reply_serial == 0 do ferr = .Protocol
		case .Signal:
			if m.path == "" || m.interface == "" || m.member == "" do ferr = .Protocol
		case .Invalid:
		}
	}
	if ferr != .None {
		message_destroy(&m, allocator)
		return {}, ferr
	}
	r.fd_count = u32(len(m.fds))

	body := make([dynamic]Value, allocator)
	m.body = body[:]
	if !r_align(&r, 8) || len(buf) - r.pos != int(body_len) || (body_len > 0 && m.signature == "") {
		message_destroy(&m, allocator)
		return {}, .Protocol
	}
	rest := m.signature
	for len(rest) > 0 {
		n := signature_first(rest)
		v: Value
		vok := n > 0
		if vok do v, vok = decode_value(&r, rest[:n])
		if !vok {
			m.body = body[:]
			message_destroy(&m, allocator)
			return {}, .Protocol
		}
		append(&body, v)
		rest = rest[n:]
	}
	m.body = body[:]
	if r.pos != len(buf) {
		message_destroy(&m, allocator)
		return {}, .Protocol
	}
	return m, .None
}

// adopt_field moves one header field into m. adopted=true means a string
// value now belongs to m (the caller must not free it); err=.Protocol on a
// type mismatch or failed validation (nothing is adopted then).
@(private)
adopt_field :: proc(m: ^Message, code: Header_Field, val: Value, fds: []i32) -> (adopted: bool, err: Error) {
	take :: proc(dst: ^string, val: Value, valid: proc "contextless" (s: string) -> bool) -> (bool, Error) {
		s, ok := val.(string)
		if !ok || !valid(s) do return false, .Protocol
		dst^ = s
		return true, .None
	}
	switch code {
	case .Path:
		p, ok := val.(Object_Path)
		if !ok do return false, .Protocol
		m.path = p.path
		return true, .None
	case .Interface:   return take(&m.interface, val, interface_name_valid)
	case .Member:      return take(&m.member, val, member_name_valid)
	case .Error_Name:  return take(&m.error_name, val, interface_name_valid)
	case .Destination: return take(&m.destination, val, bus_name_valid)
	case .Sender:      return take(&m.sender, val, bus_name_valid)
	case .Reply_Serial:
		rs, ok := val.(u32)
		if !ok || rs == 0 do return false, .Protocol
		m.reply_serial = rs
	case .Signature:
		g, ok := val.(Signature)
		if !ok do return false, .Protocol
		m.signature = g.sig
		return true, .None
	case .Unix_Fds:
		n, ok := val.(u32)
		if !ok || int(n) > len(fds) do return false, .Protocol
		m.fds = fds[:n]
	case .Invalid:
	}
	return false, .None
}
