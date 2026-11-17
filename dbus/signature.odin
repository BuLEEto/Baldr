// Signature strings: validation, splitting into complete types, and the
// alignment table. Everything the decoder does is driven by a signature, so
// a signature is validated before it is trusted (whether it came from our
// caller or from the header of an incoming message).
package dbus

// is_basic_code reports whether c is a basic (non-container) type code.
is_basic_code :: proc "contextless" (c: u8) -> bool {
	switch c {
	case 'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 's', 'o', 'g', 'h':
		return true
	}
	return false
}

// alignment_of returns the wire alignment of a type by its first code
// (arrays align to 4 for their length; structs and dict entries to 8;
// variants to 1 for their signature). 0 for an unknown code.
alignment_of :: proc "contextless" (c: u8) -> int {
	switch c {
	case 'y', 'g', 'v':           return 1
	case 'n', 'q':                return 2
	case 'b', 'i', 'u', 's', 'o', 'h', 'a': return 4
	case 'x', 't', 'd', '(', '{': return 8
	}
	return 0
}

// signature_first returns the byte length of the first complete type in
// sig, or 0 when sig is empty or does not start with a valid complete type.
// A dict entry `{kv}` is only valid directly inside an array; a struct must
// have at least one field; nesting deeper than MAX_DEPTH is rejected.
signature_first :: proc "contextless" (sig: string, depth := 0, allow_dict := false) -> int {
	if len(sig) == 0 || depth > MAX_DEPTH do return 0
	switch sig[0] {
	case 'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 's', 'o', 'g', 'h', 'v':
		return 1
	case 'a':
		n := signature_first(sig[1:], depth + 1, true)
		if n == 0 do return 0
		return 1 + n
	case '(':
		i := 1
		for i < len(sig) && sig[i] != ')' {
			n := signature_first(sig[i:], depth + 1)
			if n == 0 do return 0
			i += n
		}
		if i >= len(sig) || i == 1 do return 0
		return i + 1
	case '{':
		if !allow_dict || len(sig) < 4 || !is_basic_code(sig[1]) do return 0
		n := signature_first(sig[2:], depth + 1)
		if n == 0 do return 0
		if 2 + n >= len(sig) || sig[2 + n] != '}' do return 0
		return 3 + n
	}
	return 0
}

// signature_valid reports whether sig is a sequence of zero or more complete
// types no longer than MAX_SIGNATURE_LEN.
signature_valid :: proc "contextless" (sig: string) -> bool {
	if len(sig) > MAX_SIGNATURE_LEN do return false
	i := 0
	for i < len(sig) {
		n := signature_first(sig[i:])
		if n == 0 do return false
		i += n
	}
	return true
}

// signature_is_single reports whether sig is exactly one complete type
// (what a variant's signature and an array's element signature must be).
signature_is_single :: proc "contextless" (sig: string) -> bool {
	n := signature_first(sig)
	return n != 0 && n == len(sig)
}

// object_path_valid checks the `o` grammar: "/" alone, or "/"-separated
// non-empty runs of [A-Za-z0-9_] with no trailing slash.
object_path_valid :: proc "contextless" (p: string) -> bool {
	if len(p) == 0 || p[0] != '/' do return false
	if len(p) == 1 do return true
	if p[len(p) - 1] == '/' do return false
	for i := 1; i < len(p); i += 1 {
		c := p[i]
		switch {
		case c == '/':
			if p[i - 1] == '/' do return false
		case (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_':
		case:
			return false
		}
	}
	return true
}

// member_name_valid checks a member name: 1..255 bytes of [A-Za-z0-9_],
// not starting with a digit.
member_name_valid :: proc "contextless" (s: string) -> bool {
	if len(s) == 0 || len(s) > MAX_NAME_LEN do return false
	if s[0] >= '0' && s[0] <= '9' do return false
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_') do return false
	}
	return true
}

// interface_name_valid checks an interface / error name: two or more
// '.'-separated elements of [A-Za-z0-9_], none starting with a digit, at
// most 255 bytes.
interface_name_valid :: proc "contextless" (s: string) -> bool {
	if len(s) == 0 || len(s) > MAX_NAME_LEN do return false
	dots := 0
	start := 0
	for i := 0; i <= len(s); i += 1 {
		if i == len(s) || s[i] == '.' {
			if i == start do return false
			if s[start] >= '0' && s[start] <= '9' do return false
			if i < len(s) do dots += 1
			start = i + 1
			continue
		}
		c := s[i]
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_') do return false
	}
	return dots >= 1
}

// bus_name_valid checks a destination / sender: a unique name ":x.y"
// (elements may start with digits) or a well-known name with at least one
// '.'; elements of [A-Za-z0-9_-]; at most 255 bytes.
bus_name_valid :: proc "contextless" (s: string) -> bool {
	if len(s) == 0 || len(s) > MAX_NAME_LEN do return false
	unique := s[0] == ':'
	body := s[1:] if unique else s
	if len(body) == 0 do return false
	dots := 0
	start := 0
	for i := 0; i <= len(body); i += 1 {
		if i == len(body) || body[i] == '.' {
			if i == start do return false
			if !unique && body[start] >= '0' && body[start] <= '9' do return false
			if i < len(body) do dots += 1
			start = i + 1
			continue
		}
		c := body[i]
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-') do return false
	}
	return dots >= 1
}
