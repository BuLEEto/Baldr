// wl_scanner turns Wayland protocol XML into Odin for package wl:
// interface/message tables (static, including the core protocol — libwayland
// compares interfaces by name), typed request procs marshalled through
// wl_proxy_marshal_array_flags with since-version guards, opcode-ordered
// listener structs, and no-op listener defaults (libwayland aborts on a nil
// listener slot). Run via tools/wl_scanner/gen.sh; output is committed.
package wl_scanner

import "core:encoding/xml"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:unicode"

Arg :: struct {
	name, type, iface, enum_ref, summary: string,
	allow_null:                           bool,
}
Msg :: struct {
	name, summary: string,
	args:          [dynamic]Arg,
	since:         int,
	destructor:    bool,
}
Entry :: struct {
	name, summary: string,
	value:         u64,
}
Enum :: struct {
	name, summary: string,
	entries:       [dynamic]Entry,
	bitfield:      bool,
}
Iface :: struct {
	name, summary:    string,
	version:          int,
	requests, events: [dynamic]Msg,
	enums:            [dynamic]Enum,
}
Protocol :: struct {
	name, file: string,
	ifaces:     [dynamic]Iface,
}

main :: proc() {
	if len(os.args) < 3 {
		fmt.eprintln("usage: wl_scanner <out_dir> <protocol.xml>...")
		os.exit(2)
	}
	out_dir := os.args[1]
	protos := make([dynamic]Protocol)
	for path in os.args[2:] {
		p, ok := parse_protocol(path)
		if !ok do os.exit(1)
		append(&protos, p)
	}
	for &p in protos {
		src := emit_protocol(&p)
		out, _ := filepath.join({out_dir, fmt.tprintf("gen_%s.odin", p.name)})
		if werr := os.write_entire_file(out, src); werr != nil {
			fmt.eprintfln("cannot write %s: %v", out, werr)
			os.exit(1)
		}
		fmt.printfln("%-48s <- %s  (%d interfaces)", out, p.file, len(p.ifaces))
	}
	b := strings.builder_make()
	write_header(&b, "every protocol in xml/")
	strings.write_string(&b, "// init_protocols fills every generated interface table. Called by load().\n")
	strings.write_string(&b, "init_protocols :: proc() {\n")
	for p in protos do fmt.sbprintfln(&b, "\tinit_%s()", p.name)
	strings.write_string(&b, "}\n")
	out, _ := filepath.join({out_dir, "gen_protocols.odin"})
	if werr := os.write_entire_file(out, strings.to_string(b)); werr != nil {
		fmt.eprintfln("cannot write %s: %v", out, werr)
		os.exit(1)
	}
}

// ------------------------------------------------------------------- parsing

attr :: proc(doc: ^xml.Document, id: xml.Element_ID, key: string) -> string {
	v, _ := xml.find_attribute_val_by_key(doc, id, key)
	return v
}

child_elems :: proc(doc: ^xml.Document, id: xml.Element_ID) -> []xml.Element_ID {
	out := make([dynamic]xml.Element_ID, context.temp_allocator)
	for v in doc.elements[id].value {
		if cid, ok := v.(xml.Element_ID); ok && doc.elements[cid].kind == .Element {
			append(&out, cid)
		}
	}
	return out[:]
}

summary_of :: proc(doc: ^xml.Document, id: xml.Element_ID) -> string {
	if d, ok := xml.find_child_by_ident(doc, id, "description"); ok {
		return clean(attr(doc, d, "summary"))
	}
	return ""
}

clean :: proc(s: string) -> string {
	r, _ := strings.replace_all(s, "\n", " ")
	return strings.trim_space(r)
}

atoi :: proc(s: string, default: int) -> int {
	if s == "" do return default
	v, ok := strconv.parse_int(s)
	return v if ok else default
}

parse_protocol :: proc(path: string) -> (p: Protocol, ok: bool) {
	doc, err := xml.load_from_file(path)
	if err != .None {
		fmt.eprintfln("%s: xml error %v", path, err)
		return
	}
	root := xml.Element_ID(0)
	if doc.elements[root].ident != "protocol" {
		fmt.eprintfln("%s: root element is <%s>, expected <protocol>", path, doc.elements[root].ident)
		return
	}
	name, _ := strings.replace_all(attr(doc, root, "name"), "-", "_")
	p.name = name
	p.file = filepath.base(path)
	for cid in child_elems(doc, root) {
		if doc.elements[cid].ident != "interface" do continue
		it: Iface
		it.name = attr(doc, cid, "name")
		it.version = atoi(attr(doc, cid, "version"), 1)
		it.summary = summary_of(doc, cid)
		for mid in child_elems(doc, cid) {
			switch doc.elements[mid].ident {
			case "request", "event":
				m: Msg
				m.name = attr(doc, mid, "name")
				m.since = atoi(attr(doc, mid, "since"), 1)
				m.destructor = attr(doc, mid, "type") == "destructor"
				m.summary = summary_of(doc, mid)
				for aid in child_elems(doc, mid) {
					if doc.elements[aid].ident != "arg" do continue
					a := Arg{
						name       = attr(doc, aid, "name"),
						type       = attr(doc, aid, "type"),
						iface      = attr(doc, aid, "interface"),
						enum_ref   = attr(doc, aid, "enum"),
						summary    = clean(attr(doc, aid, "summary")),
						allow_null = attr(doc, aid, "allow-null") == "true",
					}
					append(&m.args, a)
				}
				if doc.elements[mid].ident == "request" {
					append(&it.requests, m)
				} else {
					append(&it.events, m)
				}
			case "enum":
				e: Enum
				e.name = attr(doc, mid, "name")
				e.bitfield = attr(doc, mid, "bitfield") == "true"
				e.summary = summary_of(doc, mid)
				for eid in child_elems(doc, mid) {
					if doc.elements[eid].ident != "entry" do continue
					vs := attr(doc, eid, "value")
					v, vok := strconv.parse_u64_maybe_prefixed(vs)
					if !vok {
						fmt.eprintfln("%s: %s.%s: bad enum value %q", path, it.name, e.name, vs)
						return
					}
					append(&e.entries, Entry{name = attr(doc, eid, "name"), summary = clean(attr(doc, eid, "summary")), value = v})
				}
				append(&it.enums, e)
			}
		}
		append(&p.ifaces, it)
	}
	return p, true
}

// ------------------------------------------------------------------- naming

// ada turns xdg_toplevel into Xdg_Toplevel.
ada :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	first := true
	for part in strings.split(s, "_", context.temp_allocator) {
		if part == "" do continue
		if !first do strings.write_byte(&b, '_')
		first = false
		for r, i in part {
			strings.write_rune(&b, unicode.to_upper(r) if i == 0 else r)
		}
	}
	return strings.to_string(b)
}

upper :: proc(s: string) -> string { return strings.to_upper(s, context.temp_allocator) }

RESERVED :: []string{
	"context", "proc", "struct", "union", "enum", "map", "import", "package", "return", "defer",
	"if", "else", "for", "switch", "case", "break", "continue", "fallthrough", "when", "in", "not_in",
	"using", "transmute", "cast", "auto_cast", "distinct", "dynamic", "bit_set", "matrix", "where",
	"or_else", "or_return", "or_break", "or_continue", "foreign", "asm", "typeid", "string", "cstring",
	"rawptr", "any", "bool", "int", "uint", "byte", "rune", "true", "false", "nil", "type", "len", "cap",
	"size_of", "align_of", "offset_of", "min", "max", "abs", "clamp", "p", "data", "args", "iface", "version",
}

param :: proc(name: string) -> string {
	for r in RESERVED do if r == name do return strings.concatenate({name, "_"}, context.temp_allocator)
	return name
}

entry_ident :: proc(name: string) -> string {
	id := ada(name)
	if len(id) > 0 && id[0] >= '0' && id[0] <= '9' do return strings.concatenate({"_", id}, context.temp_allocator)
	return id
}

enum_type :: proc(ref, iface: string) -> string {
	if i := strings.index_byte(ref, '.'); i >= 0 {
		return fmt.tprintf("%s_%s", ada(ref[:i]), ada(ref[i + 1:]))
	}
	return fmt.tprintf("%s_%s", ada(iface), ada(ref))
}

arg_type :: proc(a: Arg, iface: string) -> string {
	if a.enum_ref != "" && (a.type == "uint" || a.type == "int") do return enum_type(a.enum_ref, iface)
	switch a.type {
	case "int":    return "i32"
	case "uint":   return "u32"
	case "fixed":  return "Fixed"
	case "string": return "cstring"
	case "object": return "Proxy"
	case "new_id": return "Proxy"
	case "array":  return "^Array"
	case "fd":     return "i32"
	}
	return "rawptr"
}

// arg_union renders the wl_argument literal for a request parameter.
arg_union :: proc(a: Arg, pname: string) -> string {
	switch a.type {
	case "int":    return fmt.tprintf("{{i = i32(%s)}}", pname) if a.enum_ref != "" else fmt.tprintf("{{i = %s}}", pname)
	case "uint":   return fmt.tprintf("{{u = u32(%s)}}", pname) if a.enum_ref != "" else fmt.tprintf("{{u = %s}}", pname)
	case "fixed":  return fmt.tprintf("{{f = %s}}", pname)
	case "string": return fmt.tprintf("{{s = %s}}", pname)
	case "object": return fmt.tprintf("{{o = rawptr(%s)}}", pname)
	case "array":  return fmt.tprintf("{{a = %s}}", pname)
	case "fd":     return fmt.tprintf("{{h = %s}}", pname)
	}
	return "{}"
}

signature :: proc(m: Msg) -> string {
	b := strings.builder_make(context.temp_allocator)
	if m.since > 1 do fmt.sbprintf(&b, "%d", m.since)
	for a in m.args {
		switch a.type {
		case "int":    strings.write_string(&b, "i")
		case "uint":   strings.write_string(&b, "u")
		case "fixed":  strings.write_string(&b, "f")
		case "string": strings.write_string(&b, "?s" if a.allow_null else "s")
		case "object": strings.write_string(&b, "?o" if a.allow_null else "o")
		case "new_id": strings.write_string(&b, "n" if a.iface != "" else "sun")
		case "array":  strings.write_string(&b, "a")
		case "fd":     strings.write_string(&b, "h")
		}
	}
	return strings.to_string(b)
}

expanded_count :: proc(m: Msg) -> (n: int) {
	for a in m.args do n += 3 if a.type == "new_id" && a.iface == "" else 1
	return
}

has_typed_ref :: proc(m: Msg) -> bool {
	for a in m.args do if (a.type == "object" || a.type == "new_id") && a.iface != "" do return true
	return false
}

// ------------------------------------------------------------------ emitting

write_header :: proc(b: ^strings.Builder, source: string) {
	strings.write_string(b, "#+build linux\n")
	fmt.sbprintf(b, "// Code generated by tools/wl_scanner from %s. DO NOT EDIT.\n", source)
	strings.write_string(b, "// Regenerate with tools/wl_scanner/gen.sh.\n")
	strings.write_string(b, "package wl\n\n")
}

emit_protocol :: proc(p: ^Protocol) -> string {
	b := strings.builder_make()
	write_header(&b, fmt.tprintf("xml/%s", p.file))
	for &it in p.ifaces do emit_iface(&b, &it)
	emit_tables(&b, p)
	return strings.to_string(b)
}

emit_iface :: proc(b: ^strings.Builder, it: ^Iface) {
	fmt.sbprintf(b, "// %s\n// %s\n", strings.repeat("-", 76, context.temp_allocator), it.name)
	if it.summary != "" do fmt.sbprintf(b, "// %s\n", it.summary)
	fmt.sbprintf(b, "\n%s_VERSION :: %d\n", upper(it.name), it.version)
	fmt.sbprintf(b, "%s_interface: Interface\n\n", it.name)

	for e in it.enums {
		tname := fmt.tprintf("%s_%s", ada(it.name), ada(e.name))
		if e.summary != "" do fmt.sbprintf(b, "// %s\n", e.summary)
		if e.bitfield {
			fmt.sbprintf(b, "%s :: distinct u32\n", tname)
			for en in e.entries {
				fmt.sbprintf(b, "%s_%s_%s :: %s(%d)", upper(it.name), upper(e.name), upper(en.name), tname, en.value)
				if en.summary != "" do fmt.sbprintf(b, " // %s", en.summary)
				strings.write_string(b, "\n")
			}
		} else {
			fmt.sbprintf(b, "%s :: enum u32 {{\n", tname)
			for en in e.entries {
				fmt.sbprintf(b, "\t%s = %d,", entry_ident(en.name), en.value)
				if en.summary != "" do fmt.sbprintf(b, " // %s", en.summary)
				strings.write_string(b, "\n")
			}
			strings.write_string(b, "}\n")
		}
		strings.write_string(b, "\n")
	}

	for m, opcode in it.requests do emit_request(b, it, m, opcode)

	if len(it.events) > 0 {
		lname := fmt.tprintf("%s_Listener", ada(it.name))
		fmt.sbprintf(b, "// %s has one proc per event, in opcode order. Every slot must be\n// non-nil (libwayland aborts otherwise) — start from %s_listener_noop().\n", lname, it.name)
		fmt.sbprintf(b, "%s :: struct {{\n", lname)
		for ev in it.events {
			if ev.summary != "" do fmt.sbprintf(b, "\t// %s\n", ev.summary)
			fmt.sbprintf(b, "\t%s: proc \"c\" (%s),\n", param(ev.name), event_params(it, ev))
		}
		strings.write_string(b, "}\n\n")
		fmt.sbprintf(b, "%s_add_listener :: proc \"contextless\" (p: Proxy, l: ^%s, data: rawptr) -> bool {{ return add_listener(p, l, data) }}\n\n", it.name, lname)
		fmt.sbprintf(b, "%s_listener_noop :: proc \"contextless\" () -> %s {{\n\treturn {{\n", it.name, lname)
		for ev in it.events {
			fmt.sbprintf(b, "\t\t%s = proc \"c\" (%s) {{}},\n", param(ev.name), event_params(it, ev))
		}
		strings.write_string(b, "\t}\n}\n\n")
	}
}

event_params :: proc(it: ^Iface, ev: Msg) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "data: rawptr, p: Proxy")
	for a in ev.args {
		fmt.sbprintf(&b, ", %s: %s", param(a.name), arg_type(a, it.name))
	}
	return strings.to_string(b)
}

emit_request :: proc(b: ^strings.Builder, it: ^Iface, m: Msg, opcode: int) {
	// returns a Proxy when it creates one
	ret_iface := ""
	untyped_new_id := false
	for a in m.args {
		if a.type == "new_id" {
			if a.iface != "" { ret_iface = a.iface } else { untyped_new_id = true }
		}
	}
	returns := ret_iface != "" || untyped_new_id

	fmt.sbprintf(b, "// %s", m.name)
	if m.summary != "" do fmt.sbprintf(b, " — %s", m.summary)
	if m.since > 1 do fmt.sbprintf(b, " (since v%d)", m.since)
	if m.destructor do strings.write_string(b, " [destructor]")
	strings.write_string(b, "\n")

	fmt.sbprintf(b, "%s_%s :: proc \"contextless\" (p: Proxy", it.name, m.name)
	for a in m.args {
		if a.type == "new_id" {
			if a.iface == "" do strings.write_string(b, ", iface: ^Interface, version: u32")
			continue
		}
		fmt.sbprintf(b, ", %s: %s", param(a.name), arg_type(a, it.name))
	}
	strings.write_string(b, ")")
	if returns do strings.write_string(b, " -> Proxy")
	strings.write_string(b, " {\n")
	if m.since > 1 {
		fmt.sbprintf(b, "\tif proxy_version(p) < %d do return%s\n", m.since, " nil" if returns else "")
	}
	n := expanded_count(m)
	flags := "MARSHAL_FLAG_DESTROY" if m.destructor else "0"
	if n == 0 {
		fmt.sbprintf(b, "\t%smarshal(p, %d, nil, 0, %s, nil)\n", "return " if returns else "", opcode, flags)
	} else {
		fmt.sbprintf(b, "\targs := [%d]Argument{{", n)
		first := true
		for a in m.args {
			parts: []string
			switch {
			case a.type == "new_id" && a.iface == "":
				parts = {"{s = iface.name}", "{u = version}", "{o = nil}"}
			case a.type == "new_id":
				parts = {"{o = nil}"}
			case:
				parts = {arg_union(a, param(a.name))}
			}
			for part in parts {
				if !first do strings.write_string(b, ", ")
				first = false
				strings.write_string(b, part)
			}
		}
		strings.write_string(b, "}\n")
		ifc, ver := "nil", "0"
		if untyped_new_id {
			ifc, ver = "iface", "version"
		} else if ret_iface != "" {
			ifc = fmt.tprintf("&%s_interface", ret_iface)
			ver = "proxy_version(p)"
		}
		fmt.sbprintf(b, "\t%smarshal(p, %d, %s, %s, %s, &args[0])\n", "return " if returns else "", opcode, ifc, ver, flags)
	}
	strings.write_string(b, "}\n\n")
}

emit_tables :: proc(b: ^strings.Builder, p: ^Protocol) {
	// null run: long enough for the largest message without typed refs
	null_run := 1
	for it in p.ifaces {
		for m in it.requests do null_run = max(null_run, expanded_count(m))
		for m in it.events   do null_run = max(null_run, expanded_count(m))
	}
	// assign type runs
	Run :: struct { start: int, refs: [dynamic]string } // refs[i] = "" (nil) or interface name
	runs := make(map[string]Run, context.temp_allocator) // key iface.kind.name
	total := null_run
	assign :: proc(runs: ^map[string]Run, total: ^int, key: string, m: Msg) {
		if !has_typed_ref(m) do return
		r := Run{start = total^}
		for a in m.args {
			switch {
			case a.type == "new_id" && a.iface == "":
				append(&r.refs, "", "", "")
			case (a.type == "new_id" || a.type == "object") && a.iface != "":
				append(&r.refs, a.iface)
			case:
				append(&r.refs, "")
			}
		}
		total^ += len(r.refs)
		runs[key] = r
	}
	for it in p.ifaces {
		for m in it.requests do assign(&runs, &total, fmt.tprintf("%s.r.%s", it.name, m.name), m)
		for m in it.events   do assign(&runs, &total, fmt.tprintf("%s.e.%s", it.name, m.name), m)
	}

	fmt.sbprintf(b, "// %s\n// interface tables for %s\n\n", strings.repeat("-", 76, context.temp_allocator), p.name)
	fmt.sbprintf(b, "@(private = \"file\") %s_types: [%d]^Interface\n", p.name, total)
	for it in p.ifaces {
		if len(it.requests) > 0 do fmt.sbprintf(b, "@(private = \"file\") %s_requests: [%d]Message\n", it.name, len(it.requests))
		if len(it.events) > 0   do fmt.sbprintf(b, "@(private = \"file\") %s_events: [%d]Message\n", it.name, len(it.events))
	}
	fmt.sbprintf(b, "\ninit_%s :: proc() {{\n\tt := &%s_types\n", p.name, p.name)
	for it in p.ifaces {
		emit_run_fills :: proc(b: ^strings.Builder, runs: ^map[string]Run, it: Iface, kind: string, msgs: [dynamic]Msg) {
			for m in msgs {
				r, ok := runs[fmt.tprintf("%s.%s.%s", it.name, kind, m.name)]
				if !ok do continue
				for ref, i in r.refs {
					if ref == "" do continue
					fmt.sbprintf(b, "\tt[%d] = &%s_interface // %s.%s\n", r.start + i, ref, it.name, m.name)
				}
			}
		}
		emit_run_fills(b, &runs, it, "r", it.requests)
		emit_run_fills(b, &runs, it, "e", it.events)
	}
	for it in p.ifaces {
		emit_msgs :: proc(b: ^strings.Builder, runs: ^map[string]Run, it: Iface, kind: string, msgs: [dynamic]Msg, arr: string) {
			if len(msgs) == 0 do return
			fmt.sbprintf(b, "\t%s = {{\n", arr)
			for m in msgs {
				start := 0
				if r, ok := runs[fmt.tprintf("%s.%s.%s", it.name, kind, m.name)]; ok do start = r.start
				fmt.sbprintf(b, "\t\t{{%q, %q, &t[%d]}},\n", m.name, signature(m), start)
			}
			strings.write_string(b, "\t}\n")
		}
		emit_msgs(b, &runs, it, "r", it.requests, fmt.tprintf("%s_requests", it.name))
		emit_msgs(b, &runs, it, "e", it.events, fmt.tprintf("%s_events", it.name))
		req := fmt.tprintf("&%s_requests[0]", it.name) if len(it.requests) > 0 else "nil"
		evs := fmt.tprintf("&%s_events[0]", it.name) if len(it.events) > 0 else "nil"
		fmt.sbprintf(b, "\t%s_interface = {{%q, %d, %d, %s, %d, %s}}\n", it.name, it.name, it.version, len(it.requests), req, len(it.events), evs)
	}
	strings.write_string(b, "}\n")
}
