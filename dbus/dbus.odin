// Package dbus is Baldr's pure-Odin D-Bus client: the wire format of the
// D-Bus Specification (message header, header fields, all basic and container
// types with their alignment rules) plus a session-bus connection over a Unix
// socket (conn.odin, Linux only) with SASL EXTERNAL authentication, blocking
// and asynchronous method calls, match rules and signal handlers, and a
// non-blocking `dispatch` that plugs into any poll loop through `fd`.
//
// Nothing is linked: no libdbus, no libsystemd. The marshalling half of the
// package (this file, signature.odin, marshal.odin) is portable and has no
// OS dependency, so it can be tested anywhere.
//
// The bus is an attack surface: every offset is bounds-checked, signatures
// are validated before they drive decoding, array and nesting sizes are
// capped, and a malformed message is reported as `Error.Protocol` rather
// than panicking. A malformed message closes the connection, because once
// framing is untrusted nothing after it can be trusted either.
//
// Memory: decoded messages allocate strings and containers with the
// allocator you pass (an arena or `context.temp_allocator` is the natural
// choice); `message_destroy` frees a tree allocated from an ordinary
// allocator. Values handed to callbacks by `dispatch` live in the
// connection's arena and are valid until the next `dispatch` or `call`.
package dbus

import "core:strings"

// PROTOCOL_VERSION is the only major version defined by the specification.
PROTOCOL_VERSION :: u8(1)

// MAX_MESSAGE_LEN is the specification's hard cap on a whole message
// (2^27 bytes). Anything claiming to be larger is a protocol violation.
MAX_MESSAGE_LEN :: 1 << 27
// MAX_ARRAY_LEN is the specification's cap on an array's byte length (2^26).
MAX_ARRAY_LEN :: 1 << 26
// MAX_ARRAY_ITEMS is our own allocation guard: a decoded array or dict may
// hold at most this many elements regardless of its byte length.
MAX_ARRAY_ITEMS :: 1 << 20
// MAX_DEPTH caps container nesting (spec: 32 arrays + 32 structs).
MAX_DEPTH :: 64
// MAX_NAME_LEN is the cap on bus names, interface names and member names.
MAX_NAME_LEN :: 255
// MAX_SIGNATURE_LEN is the cap on a signature string.
MAX_SIGNATURE_LEN :: 255

// Error is every failure the package reports. Errors are values; nothing
// panics on data that came off the socket.
Error :: enum u8 {
	None,
	No_Address,      // DBUS_SESSION_BUS_ADDRESS is unset and $XDG_RUNTIME_DIR/bus does not exist
	Bad_Address,     // the address has no transport this client speaks (unix:path=, unix:abstract=, unix:runtime=yes)
	Socket,          // socket()/connect()/read/write failed at the OS level
	Auth,            // the SASL exchange was rejected (not the same uid as the bus?)
	Protocol,        // the peer sent bytes that violate the wire format; the connection is now closed
	Disconnected,    // the peer closed the socket, or an earlier error already closed it
	Timeout,         // `call` waited past its deadline; the reply, if it ever comes, is dropped
	Remote,          // the reply is an ERROR message: see `Message.error_name` and its body (usually one string)
	Invalid_Message, // our own message cannot be encoded (empty member, bad path, mismatched array element)
	Too_Large,       // encoding exceeded MAX_MESSAGE_LEN / MAX_ARRAY_LEN
	Not_Connected,   // the connection pointer is nil or was disconnected
}

// Message_Type is header byte 2. Unknown values decode as Invalid and are
// ignored by `dispatch`, as the specification requires.
Message_Type :: enum u8 {
	Invalid       = 0,
	Method_Call   = 1,
	Method_Return = 2,
	Error         = 3,
	Signal        = 4,
}

// Flag bits of header byte 3.
Flag :: enum u8 {
	No_Reply_Expected               = 0,
	No_Auto_Start                   = 1,
	Allow_Interactive_Authorization = 2,
}
Flags :: bit_set[Flag; u8]

// Header_Field codes of the `a(yv)` header field array.
Header_Field :: enum u8 {
	Invalid      = 0,
	Path         = 1, // o
	Interface    = 2, // s
	Member       = 3, // s
	Error_Name   = 4, // s
	Reply_Serial = 5, // u
	Destination  = 6, // s
	Sender       = 7, // s
	Signature    = 8, // g
	Unix_Fds     = 9, // u
}

// Object_Path is the `o` type: "/", or "/"-separated non-empty elements of
// [A-Za-z0-9_]. A struct rather than a distinct string so that an untyped
// string literal converts unambiguously to the `string` member of Value.
Object_Path :: struct {
	path: string,
}
// Signature is the `g` type: a (possibly empty) sequence of complete types.
Signature :: struct {
	sig: string,
}
// Unix_Fd is the `h` type: an index into `Message.fds`, never a raw descriptor.
Unix_Fd :: distinct i32

// Value is one D-Bus value, basic or container. `[]u8` is the decoded form
// of `ay` (byte arrays are common and would be wasteful as `[]Value`);
// encoding accepts either `[]u8` or an `Array` with sig "y". A nil Value is
// not encodable.
Value :: union {
	bool,
	u8,
	i16,
	u16,
	i32,
	u32,
	i64,
	u64,
	f64,
	string,
	Object_Path,
	Signature,
	Unix_Fd,
	[]u8,
	Array,
	Dict,
	Struct,
	Variant,
}

// Array is `a<sig>`. `sig` is the element's complete-type signature and is
// required even when `items` is empty (an empty array still has a type).
Array :: struct {
	sig:   string,
	items: []Value,
}

// Dict is `a{<key_sig><value_sig>}`. Keys are basic types only.
Dict :: struct {
	key_sig:   string,
	value_sig: string,
	entries:   []Dict_Entry,
}

Dict_Entry :: struct {
	key:   Value,
	value: Value,
}

// Struct is `(<fields>)`. At least one field (an empty struct is not a valid type).
Struct :: struct {
	fields: []Value,
}

// Variant is `v`: a boxed value that carries its own signature on the wire.
// `value` is a pointer because Odin unions cannot contain themselves by value.
Variant :: struct {
	value: ^Value,
}

// Message is a decoded or to-be-encoded D-Bus message. Zero-valued string
// fields mean "header field absent"; `reply_serial` 0 means absent (serials
// are never 0). `signature` is derived from `body` when encoding and copied
// from the header when decoding. `fds` are descriptors carried alongside
// the message (`h` values index into it); after decoding they belong to
// whoever received the Message.
Message :: struct {
	type:         Message_Type,
	flags:        Flags,
	serial:       u32,
	path:         string,
	interface:    string,
	member:       string,
	error_name:   string,
	destination:  string,
	sender:       string,
	reply_serial: u32,
	signature:    string,
	body:         []Value,
	fds:          []i32,
}

// method_call builds a METHOD_CALL header. Fill `body` afterwards (values,
// not bytes); the signature is derived at send time. Strings are referenced,
// not copied, so keep them alive until the message has been sent.
method_call :: proc(destination, path, interface, member: string, body: []Value = nil) -> Message {
	return Message{
		type        = .Method_Call,
		destination = destination,
		path        = path,
		interface   = interface,
		member      = member,
		body        = body,
	}
}

// signal builds a SIGNAL header (broadcast; no destination).
signal :: proc(path, interface, member: string, body: []Value = nil) -> Message {
	return Message{type = .Signal, path = path, interface = interface, member = member, body = body}
}

// method_return builds a METHOD_RETURN answering `call`.
method_return :: proc(call: ^Message, body: []Value = nil) -> Message {
	return Message{type = .Method_Return, destination = call.sender, reply_serial = call.serial, body = body}
}

// error_reply builds an ERROR answering `call`, with the conventional single
// string body. `text` is referenced, not copied.
error_reply :: proc(call: ^Message, name: string, text: string, allocator := context.allocator) -> Message {
	body := make([]Value, 1, allocator)
	body[0] = text
	return Message{type = .Error, destination = call.sender, reply_serial = call.serial, error_name = name, body = body}
}

// ------------------------------------------------------------------ values

// variant boxes v. The box is allocated from `allocator`; `message_destroy`
// / `value_destroy` free it again.
variant :: proc(v: Value, allocator := context.allocator) -> Value {
	p := new(Value, allocator)
	p^ = v
	return Variant{value = p}
}

// unwrap peels any number of Variant layers off v.
unwrap :: proc(v: Value) -> Value {
	cur := v
	for i := 0; i < MAX_DEPTH; i += 1 {
		vr, is_var := cur.(Variant)
		if !is_var || vr.value == nil do return cur
		cur = vr.value^
	}
	return cur
}

// as_bool / as_u32 / … read a basic value, looking through variants. They
// return ok=false on any other type; no numeric coercion is done.
as_bool :: proc(v: Value) -> (bool, bool) {
	x, ok := unwrap(v).(bool)
	return x, ok
}
as_u8 :: proc(v: Value) -> (u8, bool) {
	x, ok := unwrap(v).(u8)
	return x, ok
}
as_i32 :: proc(v: Value) -> (i32, bool) {
	x, ok := unwrap(v).(i32)
	return x, ok
}
as_u32 :: proc(v: Value) -> (u32, bool) {
	x, ok := unwrap(v).(u32)
	return x, ok
}
as_i64 :: proc(v: Value) -> (i64, bool) {
	x, ok := unwrap(v).(i64)
	return x, ok
}
as_u64 :: proc(v: Value) -> (u64, bool) {
	x, ok := unwrap(v).(u64)
	return x, ok
}
as_f64 :: proc(v: Value) -> (f64, bool) {
	x, ok := unwrap(v).(f64)
	return x, ok
}
as_string :: proc(v: Value) -> (string, bool) {
	x, ok := unwrap(v).(string)
	return x, ok
}
as_object_path :: proc(v: Value) -> (string, bool) {
	x, ok := unwrap(v).(Object_Path)
	return x.path, ok
}
as_array :: proc(v: Value) -> (Array, bool) {
	x, ok := unwrap(v).(Array)
	return x, ok
}
as_dict :: proc(v: Value) -> (Dict, bool) {
	x, ok := unwrap(v).(Dict)
	return x, ok
}
as_struct :: proc(v: Value) -> (Struct, bool) {
	x, ok := unwrap(v).(Struct)
	return x, ok
}
as_bytes :: proc(v: Value) -> ([]u8, bool) {
	x, ok := unwrap(v).([]u8)
	return x, ok
}

// as_strings reads an `as` value into a new slice (the strings themselves
// are not copied). ok=false if v is not an array of strings.
as_strings :: proc(v: Value, allocator := context.allocator) -> ([]string, bool) {
	arr, ok := as_array(v)
	if !ok || arr.sig != "s" do return nil, false
	out := make([]string, len(arr.items), allocator)
	for it, i in arr.items {
		s, sok := it.(string)
		if !sok {
			delete(out, allocator)
			return nil, false
		}
		out[i] = s
	}
	return out, true
}

// dict_get looks up a string key in a dict (or a variant holding one).
// Linear scan; dicts on the bus are small.
dict_get :: proc(v: Value, key: string) -> (Value, bool) {
	d, ok := as_dict(v)
	if !ok do return nil, false
	for e in d.entries {
		if k, kok := e.key.(string); kok && k == key do return e.value, true
	}
	return nil, false
}

// dict_sv builds an `a{sv}` from alternating key/value pairs; each value is
// boxed in a Variant (allocated from `allocator`). Odd-length input drops
// the trailing key.
dict_sv :: proc(pairs: []Dict_Entry, allocator := context.allocator) -> Value {
	entries := make([]Dict_Entry, len(pairs), allocator)
	for p, i in pairs {
		entries[i] = {key = p.key, value = variant(p.value, allocator)}
	}
	return Dict{key_sig = "s", value_sig = "v", entries = entries}
}

// strings_array builds an `as` value; strings are referenced, not copied.
strings_array :: proc(items: []string, allocator := context.allocator) -> Value {
	vals := make([]Value, len(items), allocator)
	for s, i in items do vals[i] = s
	return Array{sig = "s", items = vals}
}

// value_signature appends v's complete-type signature to sb. Returns false
// for a nil value, an over-deep tree, or an array whose items disagree with
// its declared element signature (checked by encode, not here).
value_signature :: proc(sb: ^strings.Builder, v: Value, depth := 0) -> bool {
	if depth > MAX_DEPTH do return false
	switch x in v {
	case bool:        strings.write_byte(sb, 'b')
	case u8:          strings.write_byte(sb, 'y')
	case i16:         strings.write_byte(sb, 'n')
	case u16:         strings.write_byte(sb, 'q')
	case i32:         strings.write_byte(sb, 'i')
	case u32:         strings.write_byte(sb, 'u')
	case i64:         strings.write_byte(sb, 'x')
	case u64:         strings.write_byte(sb, 't')
	case f64:         strings.write_byte(sb, 'd')
	case string:      strings.write_byte(sb, 's')
	case Object_Path: strings.write_byte(sb, 'o')
	case Signature:   strings.write_byte(sb, 'g')
	case Unix_Fd:     strings.write_byte(sb, 'h')
	case []u8:        strings.write_string(sb, "ay")
	case Array:
		strings.write_byte(sb, 'a')
		strings.write_string(sb, x.sig)
	case Dict:
		strings.write_string(sb, "a{")
		strings.write_string(sb, x.key_sig)
		strings.write_string(sb, x.value_sig)
		strings.write_byte(sb, '}')
	case Struct:
		if len(x.fields) == 0 do return false
		strings.write_byte(sb, '(')
		for f in x.fields {
			if !value_signature(sb, f, depth + 1) do return false
		}
		strings.write_byte(sb, ')')
	case Variant:
		strings.write_byte(sb, 'v')
	case nil:
		return false
	}
	return true
}

// body_signature returns the signature of a body (concatenated complete
// types) allocated from `allocator`; "" for an empty body.
body_signature :: proc(body: []Value, allocator := context.allocator) -> (string, bool) {
	sb := strings.builder_make(allocator)
	for v in body {
		if !value_signature(&sb, v) {
			strings.builder_destroy(&sb)
			return "", false
		}
	}
	return strings.to_string(sb), true
}

// value_destroy frees everything a decoded value allocated from `allocator`
// (strings, slices, variant boxes). Only for values decoded or built with
// a non-arena allocator; never call it on values inside a dispatch callback.
value_destroy :: proc(v: Value, allocator := context.allocator) {
	switch x in v {
	case string:      delete(x, allocator)
	case Object_Path: delete(x.path, allocator)
	case Signature:   delete(x.sig, allocator)
	case []u8:        delete(x, allocator)
	case Array:
		for it in x.items do value_destroy(it, allocator)
		delete(x.items, allocator)
		delete(x.sig, allocator)
	case Dict:
		for e in x.entries {
			value_destroy(e.key, allocator)
			value_destroy(e.value, allocator)
		}
		delete(x.entries, allocator)
		delete(x.key_sig, allocator)
		delete(x.value_sig, allocator)
	case Struct:
		for f in x.fields do value_destroy(f, allocator)
		delete(x.fields, allocator)
	case Variant:
		if x.value != nil {
			value_destroy(x.value^, allocator)
			free(x.value, allocator)
		}
	case bool, u8, i16, u16, i32, u32, i64, u64, f64, Unix_Fd, nil:
	}
}

// message_destroy frees a message decoded with `decode_message` (or
// returned by `call`) from an ordinary allocator. Does not close `fds`.
message_destroy :: proc(m: ^Message, allocator := context.allocator) {
	delete(m.path, allocator)
	delete(m.interface, allocator)
	delete(m.member, allocator)
	delete(m.error_name, allocator)
	delete(m.destination, allocator)
	delete(m.sender, allocator)
	delete(m.signature, allocator)
	for v in m.body do value_destroy(v, allocator)
	delete(m.body, allocator)
	delete(m.fds, allocator)
	m^ = {}
}
