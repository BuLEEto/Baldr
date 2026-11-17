// Headless tests for the wire format. Run with:
//   odin test dbus -collection:baldr=.
package dbus

@(require) import "core:fmt"
@(require) import "core:math"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports it would
// type-check them too: they sit behind this `when` (see baldr/canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// roundtrip encodes body as a METHOD_CALL, checks the frame, decodes it back.
@(private = "file")
roundtrip :: proc(t: ^testing.T, body: []Value) -> (msg: Message, ok: bool) {
	call := method_call(":1.1", "/org/example/Obj", "org.example.Iface", "Method", body)
	call.serial = 7
	bytes, eerr := encode_message(&call, context.temp_allocator)
	if !testing.expect_value(t, eerr, Error.None) do return {}, false
	total, st := frame_length(bytes)
	testing.expect_value(t, st, Frame_Status.Ok)
	testing.expect_value(t, total, len(bytes))
	m, derr := decode_message(bytes, context.temp_allocator)
	if !testing.expect_value(t, derr, Error.None) do return {}, false
	testing.expect_value(t, m.signature, call.signature)
	testing.expect_value(t, len(m.body), len(body))
	return m, true
}

@(test)
marshal_roundtrip_string :: proc(t: ^testing.T) {
	body := [1]Value{"héllo, bus"}
	m, ok := roundtrip(t, body[:])
	if !ok do return
	s, sok := as_string(m.body[0])
	testing.expect(t, sok)
	testing.expect_value(t, s, "héllo, bus")
	testing.expect_value(t, m.signature, "s")
}

@(test)
marshal_roundtrip_dict_sv :: proc(t: ^testing.T) {
	ta := context.temp_allocator
	inner := strings_array({"a", "bb"}, ta)
	pairs := [5]Dict_Entry{
		{"name", "baldr"},
		{"count", u32(42)},
		{"flag", true},
		{"ratio", f64(0.25)},
		{"list", inner},
	}
	body := [1]Value{dict_sv(pairs[:], ta)}
	m, ok := roundtrip(t, body[:])
	if !ok do return
	testing.expect_value(t, m.signature, "a{sv}")
	name, _ := as_string(dict_lookup(t, m.body[0], "name"))
	testing.expect_value(t, name, "baldr")
	count, _ := as_u32(dict_lookup(t, m.body[0], "count"))
	testing.expect_value(t, count, u32(42))
	flag, _ := as_bool(dict_lookup(t, m.body[0], "flag"))
	testing.expect_value(t, flag, true)
	ratio, _ := as_f64(dict_lookup(t, m.body[0], "ratio"))
	testing.expect_value(t, ratio, 0.25)
	list, lok := as_strings(dict_lookup(t, m.body[0], "list"), ta)
	testing.expect(t, lok)
	testing.expect_value(t, len(list), 2)
	if len(list) == 2 do testing.expect_value(t, list[1], "bb")
	_, missing := dict_get(m.body[0], "nope")
	testing.expect_value(t, missing, false)
}

@(private = "file")
dict_lookup :: proc(t: ^testing.T, d: Value, key: string) -> Value {
	v, ok := dict_get(d, key)
	testing.expectf(t, ok, "key %q missing", key)
	return v
}

@(test)
marshal_roundtrip_struct_iu :: proc(t: ^testing.T) {
	fields := [2]Value{i32(-5), u32(0xdeadbeef)}
	body := [2]Value{Struct{fields = fields[:]}, u8(9)}
	m, ok := roundtrip(t, body[:])
	if !ok do return
	testing.expect_value(t, m.signature, "(iu)y")
	s, sok := as_struct(m.body[0])
	testing.expect(t, sok)
	if !sok do return
	a, _ := as_i32(s.fields[0])
	b, _ := as_u32(s.fields[1])
	c, _ := as_u8(m.body[1])
	testing.expect_value(t, a, i32(-5))
	testing.expect_value(t, b, u32(0xdeadbeef))
	testing.expect_value(t, c, u8(9))
}

@(test)
marshal_roundtrip_av :: proc(t: ^testing.T) {
	ta := context.temp_allocator
	items := [5]Value{
		variant(i16(-2), ta),
		variant("x", ta),
		variant(Object_Path{"/o/p"}, ta),
		variant(Signature{"a{sv}"}, ta),
		variant(variant(u64(1) << 40, ta), ta), // variant in a variant
	}
	body := [1]Value{Array{sig = "v", items = items[:]}}
	m, ok := roundtrip(t, body[:])
	if !ok do return
	testing.expect_value(t, m.signature, "av")
	arr, aok := as_array(m.body[0])
	testing.expect(t, aok)
	if !aok || len(arr.items) != 5 {
		testing.fail(t)
		return
	}
	n, _ := unwrap(arr.items[0]).(i16)
	testing.expect_value(t, n, i16(-2))
	p, _ := as_object_path(arr.items[2])
	testing.expect_value(t, p, "/o/p")
	g, _ := unwrap(arr.items[3]).(Signature)
	testing.expect_value(t, g.sig, "a{sv}")
	big, _ := as_u64(arr.items[4])
	testing.expect_value(t, big, u64(1) << 40)
}

@(test)
marshal_roundtrip_nested_dict :: proc(t: ^testing.T) {
	// The Settings.ReadAll shape: a{sa{sv}}.
	ta := context.temp_allocator
	appearance := [2]Dict_Entry{{"color-scheme", u32(1)}, {"contrast", u32(0)}}
	iface := [2]Dict_Entry{{"enable-animations", true}, {"text-scaling-factor", f64(1.25)}}
	outer := [2]Dict_Entry{
		{"org.freedesktop.appearance", dict_sv(appearance[:], ta)},
		{"org.gnome.desktop.interface", dict_sv(iface[:], ta)},
	}
	body := [1]Value{Dict{key_sig = "s", value_sig = "a{sv}", entries = outer[:]}}
	m, ok := roundtrip(t, body[:])
	if !ok do return
	testing.expect_value(t, m.signature, "a{sa{sv}}")
	ns, nok := dict_get(m.body[0], "org.gnome.desktop.interface")
	testing.expect(t, nok)
	scale, _ := as_f64(dict_lookup(t, ns, "text-scaling-factor"))
	testing.expect_value(t, scale, 1.25)
	scheme, _ := as_u32(dict_lookup(t, dict_lookup(t, m.body[0], "org.freedesktop.appearance"), "color-scheme"))
	testing.expect_value(t, scheme, u32(1))
}

@(test)
marshal_bool_double_alignment :: proc(t: ^testing.T) {
	// y then b then d: the bool must land at offset 4 and the double at 8;
	// padding bytes must be zero and the decoder must insist on that.
	body := [4]Value{u8(1), true, f64(math.PI), i16(-1)}
	bytes, sig, err := encode_body(body[:], context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, sig, "ybdn")
	testing.expect_value(t, len(bytes), 18)
	testing.expect_value(t, bytes[0], u8(1))
	testing.expect_value(t, bytes[1], u8(0)) // pad
	testing.expect_value(t, bytes[4], u8(1)) // bool = 1
	testing.expect_value(t, bytes[5], u8(0))
	r := Reader{buf = bytes, pos = 0, allocator = context.temp_allocator}
	_, _ = decode_value(&r, "y")
	b, bok := decode_value(&r, "b")
	testing.expect(t, bok)
	testing.expect_value(t, b.(bool), true)
	testing.expect_value(t, r.pos, 8)
	d, dok := decode_value(&r, "d")
	testing.expect(t, dok)
	testing.expect_value(t, d.(f64), math.PI)
	n, nok := decode_value(&r, "n")
	testing.expect(t, nok)
	testing.expect_value(t, n.(i16), i16(-1))
	testing.expect_value(t, r.pos, 18)

	// Non-zero padding is a protocol violation.
	bytes[2] = 0xff
	r2 := Reader{buf = bytes, allocator = context.temp_allocator}
	_, _ = decode_value(&r2, "y")
	_, bad := decode_value(&r2, "b")
	testing.expect_value(t, bad, false)
	bytes[2] = 0
	// A bool other than 0/1 is invalid.
	bytes[4] = 2
	r3 := Reader{buf = bytes, allocator = context.temp_allocator}
	_, _ = decode_value(&r3, "y")
	_, bad2 := decode_value(&r3, "b")
	testing.expect_value(t, bad2, false)
}

@(test)
marshal_empty_array_padding :: proc(t: ^testing.T) {
	// An empty array of 8-aligned structs still pads to 8 after its length.
	body := [2]Value{u8(7), Array{sig = "(ii)", items = nil}}
	bytes, sig, err := encode_body(body[:], context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, sig, "ya(ii)")
	testing.expect_value(t, len(bytes), 8) // y @0, pad, len u32 @4; 8 is already aligned
	body2 := [2]Value{u32(7), Array{sig = "(ii)", items = nil}}
	bytes2, _, _ := encode_body(body2[:], context.temp_allocator)
	testing.expect_value(t, len(bytes2), 8) // u @0, len @4..8; 8 is already aligned
	body3 := [2]Value{Array{sig = "(ii)", items = nil}, u8(1)}
	bytes3, _, _ := encode_body(body3[:], context.temp_allocator)
	testing.expect_value(t, len(bytes3), 9) // len @0..4, pad to 8, y @8
	m, ok := roundtrip(t, body3[:])
	if !ok do return
	arr, aok := as_array(m.body[0])
	testing.expect(t, aok)
	testing.expect_value(t, len(arr.items), 0)
	testing.expect_value(t, arr.sig, "(ii)")
}

@(test)
marshal_byte_array_and_fd_index :: proc(t: ^testing.T) {
	raw := []u8{1, 2, 3, 4, 5}
	body := [2]Value{raw, Unix_Fd(0)}
	call := method_call(":1.1", "/x", "a.b", "M", body[:])
	call.serial = 1
	call.fds = []i32{42}
	bytes, eerr := encode_message(&call, context.temp_allocator)
	testing.expect_value(t, eerr, Error.None)
	testing.expect_value(t, call.signature, "ayh")
	pool := []i32{42, 43}
	m, derr := decode_message(bytes, context.temp_allocator, pool)
	testing.expect_value(t, derr, Error.None)
	testing.expect_value(t, len(m.fds), 1)
	got, gok := as_bytes(m.body[0])
	testing.expect(t, gok)
	testing.expect_value(t, len(got), 5)
	// Claiming an fd we did not receive is a protocol error.
	_, derr2 := decode_message(bytes, context.temp_allocator, nil)
	testing.expect_value(t, derr2, Error.Protocol)
}

@(test)
marshal_header_roundtrip :: proc(t: ^testing.T) {
	body := [2]Value{"payload", u32(3)}
	m := Message{
		type        = .Signal,
		flags       = {.No_Reply_Expected},
		serial      = 0x01020304,
		path        = "/org/freedesktop/portal/desktop",
		interface   = "org.freedesktop.portal.Settings",
		member      = "SettingChanged",
		destination = ":1.99",
		sender      = ":1.39",
		body        = body[:],
	}
	bytes, eerr := encode_message(&m, context.temp_allocator)
	testing.expect_value(t, eerr, Error.None)
	testing.expect_value(t, bytes[0], u8('l'))
	testing.expect_value(t, bytes[1], u8(Message_Type.Signal))
	testing.expect_value(t, bytes[2], u8(1))
	testing.expect_value(t, bytes[3], u8(1))
	total, st := frame_length(bytes)
	testing.expect_value(t, st, Frame_Status.Ok)
	testing.expect_value(t, total, len(bytes))
	d, derr := decode_message(bytes, context.temp_allocator)
	testing.expect_value(t, derr, Error.None)
	testing.expect_value(t, d.type, Message_Type.Signal)
	testing.expect_value(t, d.flags, Flags{.No_Reply_Expected})
	testing.expect_value(t, d.serial, u32(0x01020304))
	testing.expect_value(t, d.path, m.path)
	testing.expect_value(t, d.interface, m.interface)
	testing.expect_value(t, d.member, m.member)
	testing.expect_value(t, d.destination, m.destination)
	testing.expect_value(t, d.sender, m.sender)
	testing.expect_value(t, d.signature, "su")
	testing.expect_value(t, d.reply_serial, u32(0))

	// Error reply headers.
	e := error_reply(&d, "org.freedesktop.DBus.Error.Failed", "boom", context.temp_allocator)
	e.serial = 9
	ebytes, eerr2 := encode_message(&e, context.temp_allocator)
	testing.expect_value(t, eerr2, Error.None)
	de, derr2 := decode_message(ebytes, context.temp_allocator)
	testing.expect_value(t, derr2, Error.None)
	testing.expect_value(t, de.type, Message_Type.Error)
	testing.expect_value(t, de.reply_serial, u32(0x01020304))
	testing.expect_value(t, de.error_name, "org.freedesktop.DBus.Error.Failed")
	testing.expect_value(t, de.destination, ":1.39")
	text, _ := as_string(de.body[0])
	testing.expect_value(t, text, "boom")
}

@(test)
marshal_rejects_bad_messages :: proc(t: ^testing.T) {
	body := [1]Value{"x"}
	m := method_call(":1.1", "/x", "a.b", "M", body[:])
	m.serial = 1
	good, _ := encode_message(&m, context.temp_allocator)

	// Truncated: framing says incomplete / total > have.
	_, st := frame_length(good[:10])
	testing.expect_value(t, st, Frame_Status.Incomplete)
	_, derr := decode_message(good[:len(good) - 1], context.temp_allocator)
	testing.expect_value(t, derr, Error.Protocol)

	// Wrong endianness byte / version.
	bad := make([]u8, len(good), context.temp_allocator)
	copy(bad, good)
	bad[0] = 'x'
	_, st2 := frame_length(bad)
	testing.expect_value(t, st2, Frame_Status.Bad)
	copy(bad, good)
	bad[3] = 2
	_, st3 := frame_length(bad)
	testing.expect_value(t, st3, Frame_Status.Bad)

	// Absurd body length.
	copy(bad, good)
	bad[4], bad[5], bad[6], bad[7] = 0xff, 0xff, 0xff, 0x7f
	_, st4 := frame_length(bad)
	testing.expect_value(t, st4, Frame_Status.Bad)

	// Body signature says "s" but the string runs past the end.
	copy(bad, good)
	body_at := len(good) - 6 // u32 len(1) + "x" + NUL
	bad[body_at] = 0x40
	_, derr2 := decode_message(bad, context.temp_allocator)
	testing.expect_value(t, derr2, Error.Protocol)

	// Serial 0 is invalid.
	copy(bad, good)
	bad[8], bad[9], bad[10], bad[11] = 0, 0, 0, 0
	_, derr3 := decode_message(bad, context.temp_allocator)
	testing.expect_value(t, derr3, Error.Protocol)

	// A method call without a member is invalid to encode.
	nm := method_call(":1.1", "/x", "a.b", "", nil)
	nm.serial = 1
	_, eerr := encode_message(&nm, context.temp_allocator)
	testing.expect_value(t, eerr, Error.Invalid_Message)
	// Bad object path.
	bp := method_call(":1.1", "/x/", "a.b", "M", nil)
	bp.serial = 1
	_, eerr2 := encode_message(&bp, context.temp_allocator)
	testing.expect_value(t, eerr2, Error.Invalid_Message)
	// Array whose items disagree with its element signature.
	items := [1]Value{"str"}
	ab := [1]Value{Array{sig = "u", items = items[:]}}
	am := method_call(":1.1", "/x", "a.b", "M", ab[:])
	am.serial = 1
	_, eerr3 := encode_message(&am, context.temp_allocator)
	testing.expect_value(t, eerr3, Error.Invalid_Message)
	// Empty struct.
	sb := [1]Value{Struct{}}
	sm := method_call(":1.1", "/x", "a.b", "M", sb[:])
	sm.serial = 1
	_, eerr4 := encode_message(&sm, context.temp_allocator)
	testing.expect_value(t, eerr4, Error.Invalid_Message)
}

@(test)
marshal_variant_with_bad_signature_is_rejected :: proc(t: ^testing.T) {
	// v whose signature is not a single complete type ("uu"), then "a{" junk.
	bytes := []u8{2, 'u', 'u', 0, 1, 0, 0, 0, 2, 0, 0, 0}
	r := Reader{buf = bytes, allocator = context.temp_allocator}
	_, ok := decode_value(&r, "v")
	testing.expect_value(t, ok, false)
	junk := []u8{2, 'a', '{', 0}
	r2 := Reader{buf = junk, allocator = context.temp_allocator}
	_, ok2 := decode_value(&r2, "v")
	testing.expect_value(t, ok2, false)
	// Array length beyond the buffer.
	arr := []u8{0xff, 0xff, 0, 0, 1, 2}
	r3 := Reader{buf = arr, allocator = context.temp_allocator}
	_, ok3 := decode_value(&r3, "ay")
	testing.expect_value(t, ok3, false)
}

@(test)
marshal_big_endian_decode :: proc(t: ^testing.T) {
	// Hand-assembled 'B' SIGNAL /a a.b M with body u = 0x01020304.
	bytes := []u8{
		'B', 4, 0, 1, // endian, SIGNAL, flags, version
		0, 0, 0, 4, // body length (BE)
		0, 0, 0, 1, // serial
		0, 0, 0, 55, // header fields array length
		1, 1, 'o', 0, 0, 0, 0, 2, '/', 'a', 0, 0, 0, 0, 0, 0, // PATH "/a" (pad to 8)
		2, 1, 's', 0, 0, 0, 0, 3, 'a', '.', 'b', 0, 0, 0, 0, 0, // INTERFACE "a.b"
		3, 1, 's', 0, 0, 0, 0, 1, 'M', 0, 0, 0, 0, 0, 0, 0, // MEMBER "M"
		8, 1, 'g', 0, 1, 'u', 0, // SIGNATURE "u"
		0, // pad to 8
		1, 2, 3, 4, // body
	}
	total, st := frame_length(bytes)
	testing.expect_value(t, st, Frame_Status.Ok)
	testing.expect_value(t, total, len(bytes))
	m, err := decode_message(bytes, context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, m.type, Message_Type.Signal)
	testing.expect_value(t, m.path, "/a")
	testing.expect_value(t, m.interface, "a.b")
	testing.expect_value(t, m.member, "M")
	testing.expect_value(t, m.signature, "u")
	v, _ := as_u32(m.body[0])
	testing.expect_value(t, v, u32(0x01020304))
}

@(test)
signature_validation :: proc(t: ^testing.T) {
	good := []string{"", "s", "a{sv}", "(iu)", "av", "a{sa{sv}}", "a(sa(us))", "ayh", "(y(nq)x)", "aaai"}
	for s in good do testing.expectf(t, signature_valid(s), "%q should be valid", s)
	bad := []string{"a", "{sv}", "a{vs}", "()", "(", ")", "a{s}", "a{sss}", "z", "(s", "s)"}
	for s in bad do testing.expectf(t, !signature_valid(s), "%q should be invalid", s)
	testing.expect(t, signature_is_single("a{sv}"))
	testing.expect(t, !signature_is_single("su"))
	testing.expect(t, object_path_valid("/"))
	testing.expect(t, object_path_valid("/org/freedesktop/portal/desktop/request/1_39/baldr_5"))
	testing.expect(t, !object_path_valid(""))
	testing.expect(t, !object_path_valid("/a//b"))
	testing.expect(t, !object_path_valid("/a-b"))
	testing.expect(t, bus_name_valid(":1.39"))
	testing.expect(t, bus_name_valid("org.freedesktop.portal.Desktop"))
	testing.expect(t, !bus_name_valid("nodots"))
	testing.expect(t, !bus_name_valid("org.1bad"))
	testing.expect(t, interface_name_valid("org.freedesktop.DBus.Error.UnknownMethod"))
	testing.expect(t, !interface_name_valid("single"))
	testing.expect(t, member_name_valid("SettingChanged"))
	testing.expect(t, !member_name_valid("1st"))
	testing.expect(t, !member_name_valid("has-dash"))
}

@(test)
marshal_destroy_frees_tree :: proc(t: ^testing.T) {
	// Decode with the heap allocator and free the tree: odin test's tracking
	// allocator reports anything left behind, and the walk must handle every
	// value kind. (The encode side uses the temp allocator because it holds
	// string literals, which must never be freed.)
	ta := context.temp_allocator
	heap := context.allocator
	inner := strings_array({"a"}, ta)
	pairs := [2]Dict_Entry{{"k", inner}, {"n", i64(-1)}}
	fields := [2]Value{u8(1), Object_Path{"/p"}}
	body := [4]Value{dict_sv(pairs[:], ta), Struct{fields = fields[:]}, []u8{1, 2}, Signature{"s"}}
	m := method_call(":1.1", "/x", "a.b", "M", body[:])
	m.serial = 3
	bytes, eerr := encode_message(&m, ta)
	testing.expect_value(t, eerr, Error.None)
	d, derr := decode_message(bytes, heap)
	testing.expect_value(t, derr, Error.None)
	testing.expect_value(t, d.signature, "a{sv}(yo)ayg")
	message_destroy(&d, heap)
	testing.expect_value(t, len(d.body), 0)
}

// A real session bus's METHOD_RETURN to our Hello (serial 1), giving our
// unique name ":1.551". 91 bytes: 12 fixed + 4 array length + 61 fields +
// 3 pad + 11 body.
@(private = "file")
HELLO_REPLY := [91]u8{
	0x6c, 0x02, 0x01, 0x01, 0x0b, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3d, 0x00, 0x00, 0x00,
	0x06, 0x01, 0x73, 0x00, 0x06, 0x00, 0x00, 0x00, 0x3a, 0x31, 0x2e, 0x35, 0x35, 0x31, 0x00, 0x00,
	0x05, 0x01, 0x75, 0x00, 0x01, 0x00, 0x00, 0x00, 0x08, 0x01, 0x67, 0x00, 0x01, 0x73, 0x00, 0x00,
	0x07, 0x01, 0x73, 0x00, 0x14, 0x00, 0x00, 0x00, 0x6f, 0x72, 0x67, 0x2e, 0x66, 0x72, 0x65, 0x65,
	0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2e, 0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00, 0x00,
	0x06, 0x00, 0x00, 0x00, 0x3a, 0x31, 0x2e, 0x35, 0x35, 0x31, 0x00,
}

@(test)
marshal_decodes_live_hello_reply :: proc(t: ^testing.T) {
	bytes := HELLO_REPLY[:]
	total, st := frame_length(bytes)
	testing.expect_value(t, st, Frame_Status.Ok)
	testing.expect_value(t, total, 91)
	m, err := decode_message(bytes, context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, m.type, Message_Type.Method_Return)
	testing.expect_value(t, m.serial, u32(1))
	testing.expect_value(t, m.reply_serial, u32(1))
	testing.expect_value(t, m.destination, ":1.551")
	testing.expect_value(t, m.sender, "org.freedesktop.DBus")
	testing.expect_value(t, m.signature, "s")
	testing.expect_value(t, len(m.body), 1)
	name, ok := as_string(m.body[0])
	testing.expect(t, ok)
	testing.expect_value(t, name, ":1.551")
	testing.expect_value(t, m.flags, Flags{.No_Reply_Expected})

	// Stream framing: 15 bytes is not enough to know the length, 16 is.
	_, st2 := frame_length(bytes[:15])
	testing.expect_value(t, st2, Frame_Status.Incomplete)
	total3, st3 := frame_length(bytes[:16])
	testing.expect_value(t, st3, Frame_Status.Ok)
	testing.expect_value(t, total3, 91)

	// The bus orders header fields differently from our encoder, so the
	// re-encoded message is compared by meaning, not byte for byte.
	again, eerr := encode_message(&m, context.temp_allocator)
	testing.expect_value(t, eerr, Error.None)
	m2, derr := decode_message(again, context.temp_allocator)
	testing.expect_value(t, derr, Error.None)
	testing.expect_value(t, m2.destination, m.destination)
	testing.expect_value(t, m2.reply_serial, m.reply_serial)
	name2, _ := as_string(m2.body[0])
	testing.expect_value(t, name2, ":1.551")
}

@(test)
marshal_roundtrip_array_of_struct :: proc(t: ^testing.T) {
	// `a(so)` is AT-SPI's list of objects (bus name, path), the shape of
	// every reply that lists children. Struct elements are 8-byte aligned
	// inside an array.
	ta := context.temp_allocator
	items := make([dynamic]Value, ta)
	for i in 0 ..< 4 {
		f := make([]Value, 2, ta)
		f[0] = ":1.2"
		f[1] = Object_Path{fmt.tprintf("/org/a11y/atspi/accessible/%d", i)}
		append(&items, Struct{fields = f})
	}
	body := [1]Value{Array{sig = "(so)", items = items[:]}}
	m, ok := roundtrip(t, body[:])
	if !ok do return
	testing.expect_value(t, m.signature, "a(so)")
	arr, aok := as_array(m.body[0])
	testing.expect(t, aok)
	testing.expect_value(t, len(arr.items), 4)
	if len(arr.items) != 4 do return
	for item, i in arr.items {
		s, is_struct := item.(Struct)
		testing.expect(t, is_struct && len(s.fields) == 2)
		if !is_struct || len(s.fields) != 2 do continue
		name, _ := s.fields[0].(string)
		path, _ := as_object_path(s.fields[1])
		testing.expect_value(t, name, ":1.2")
		testing.expect_value(t, path, fmt.tprintf("/org/a11y/atspi/accessible/%d", i))
	}
}

} // when ODIN_TEST
