package baldr

// Language describes a programming language to the code editor: the words
// to colour and the shapes of comments, strings, numbers and attributes.
// A data-driven state machine (`tokenize_line`) is enough for most
// languages — comments and strings carry across lines through `state`.
// Apps add a language by filling a Language (see LANG_SQL for a
// case-insensitive one); a language the table cannot describe supplies
// its own `tokenize` proc and keeps everything else (colours, bracket
// matching, comment toggle). LANG_ODIN, LANG_C, LANG_JSON, LANG_SQL and
// LANG_PLAIN ship.
//
//	LANG_LUA := baldr.Language{name = "Lua", keywords = {"function", "local", "end", …},
//		constants = {"true", "false", "nil"}, line_comment = "--", block_comment = {"--[[", "]]"},
//		quotes = "\"'", brackets = "()[]{}"}
//	baldr.code_editor(ui, &s.doc, &LANG_LUA)

import "core:strings"

// Token_Kind is the class a `Language` gives a run of code, which the code
// editor turns into a colour from the theme rather than one of its own.
Token_Kind :: enum u8 {
	Plain, Keyword, Type, Ident, Number, String, Comment, Operator, Punct, Constant, Attribute,
}

// Token is a coloured run of one line: [start, end) bytes.
Token :: struct {
	start, end: int,
	kind:       Token_Kind,
}

// Language describes a language to `code_editor`: its name, its keyword,
// type and constant lists, and how it delimits comments and strings. The app
// owns it and the slices in it, and they must outlive the view. Without one,
// a `code_editor` offers the identifiers already in the document.
Language :: struct {
	name:           string,
	keywords:       []string,
	types:          []string,
	constants:      []string,   // true, false, nil …
	line_comment:   string,     // "//", "#", "--"; "" = none
	block_comment:  [2]string,  // "/*", "*/"; "" = none. Nesting follows `nested_comments`
	nested_comments: bool,
	quotes:         string,     // each rune opens a string closed by the same rune (escapes with '\\')
	raw_quote:      rune,       // a multi-line raw string delimiter ('`'); 0 = none
	attribute:      string,     // a prefix that starts an attribute / directive: "@" (Odin), "#" (C)
	brackets:       string,     // pairs, opener then closer: "()[]{}"
	case_insensitive: bool,     // keywords match in any case (SQL)
	tokenize:       Tokenizer,  // a custom tokenizer replaces the built-in machine (nil = built-in)
}

// Tokenizer is a custom line tokenizer: append `line`'s tokens to `out`
// and return the state the next line starts in (0 at the top of a file).
Tokenizer :: #type proc(lang: ^Language, line: string, state: u32, out: ^[dynamic]Token) -> u32

// Line state at a block's start: 0 = code, LINE_IN_COMMENT + depth = inside
// a block comment (depth − 1 nested), LINE_IN_RAW = inside a raw string.
LINE_IN_COMMENT :: u32(1)
LINE_IN_RAW     :: u32(0x8000_0000)

LANG_PLAIN := Language{name = "Plain text", brackets = "()[]{}"}

LANG_ODIN := Language{
	name = "Odin",
	keywords = {"package", "import", "foreign", "proc", "struct", "union", "enum", "bit_set", "bit_field", "map", "dynamic", "matrix",
		"if", "else", "when", "for", "in", "not_in", "switch", "case", "break", "continue", "fallthrough", "defer", "return", "do",
		"or_else", "or_return", "or_break", "or_continue", "using", "where", "distinct", "cast", "transmute", "auto_cast",
		"context", "typeid_of", "size_of", "align_of", "offset_of", "type_of", "type_info_of", "asm", "inline", "no_inline"},
	types = {"int", "uint", "uintptr", "i8", "i16", "i32", "i64", "i128", "u8", "u16", "u32", "u64", "u128", "f16", "f32", "f64",
		"bool", "b8", "b16", "b32", "b64", "string", "cstring", "rune", "rawptr", "typeid", "any", "byte", "complex64", "complex128",
		"quaternion128", "quaternion256", "i16le", "i32le", "i64le", "u16le", "u32le", "u64le", "i16be", "i32be", "i64be", "u16be", "u32be", "u64be"},
	constants = {"true", "false", "nil", "---"},
	line_comment = "//", block_comment = {"/*", "*/"}, nested_comments = true,
	quotes = "\"'", raw_quote = '`', attribute = "@#", brackets = "()[]{}",
}

LANG_C := Language{
	name = "C",
	keywords = {"if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "goto",
		"struct", "union", "enum", "typedef", "sizeof", "static", "extern", "inline", "const", "volatile", "register", "auto",
		"restrict", "_Alignas", "_Alignof", "_Atomic", "_Bool", "_Generic", "_Noreturn", "_Static_assert", "_Thread_local"},
	types = {"void", "char", "short", "int", "long", "float", "double", "signed", "unsigned", "size_t", "ssize_t", "ptrdiff_t",
		"int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t", "intptr_t", "uintptr_t", "bool", "FILE"},
	constants = {"true", "false", "NULL"},
	line_comment = "//", block_comment = {"/*", "*/"},
	quotes = "\"'", attribute = "#", brackets = "()[]{}",
}

LANG_JSON := Language{
	name = "JSON",
	constants = {"true", "false", "null"},
	quotes = "\"", brackets = "[]{}",
}

LANG_SQL := Language{
	name = "SQL",
	keywords = {"select", "from", "where", "and", "or", "not", "in", "is", "null", "as", "on", "join", "inner", "left", "right",
		"full", "outer", "cross", "group", "by", "order", "having", "limit", "offset", "insert", "into", "values", "update", "set",
		"delete", "create", "table", "view", "index", "drop", "alter", "add", "column", "primary", "key", "foreign", "references",
		"unique", "default", "constraint", "distinct", "union", "all", "exists", "between", "like", "case", "when", "then", "else",
		"end", "begin", "commit", "rollback", "transaction", "with", "returning", "asc", "desc", "if", "cascade", "using"},
	types = {"int", "integer", "smallint", "bigint", "serial", "bigserial", "real", "float", "double", "decimal", "numeric",
		"boolean", "bool", "text", "varchar", "char", "date", "time", "timestamp", "timestamptz", "interval", "json", "jsonb", "uuid", "blob", "bytea"},
	constants = {"true", "false"},
	line_comment = "--", block_comment = {"/*", "*/"},
	quotes = "'\"", brackets = "()", case_insensitive = true,
}

@(private)
word_in :: proc(list: []string, w: string, fold: bool) -> bool {
	for k in list {
		if k == w do return true
		if fold && strings.equal_fold(k, w) do return true
	}
	return false
}

@(private)
is_ident_start :: proc "contextless" (c: u8) -> bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c >= 0x80
}

@(private)
is_ident_char :: proc "contextless" (c: u8) -> bool {
	return is_ident_start(c) || (c >= '0' && c <= '9')
}

@(private)
is_digit :: proc "contextless" (c: u8) -> bool { return c >= '0' && c <= '9' }

// tokenize_line appends the tokens of `line` to `out` and returns the state
// the next line starts in. Whitespace is left out (it is Plain).
tokenize_line :: proc(lang: ^Language, line: string, state: u32, out: ^[dynamic]Token) -> u32 {
	lang := lang if lang != nil else &LANG_PLAIN
	if lang.tokenize != nil do return lang.tokenize(lang, line, state, out)
	n := len(line)
	i := 0
	st := state
	emit :: proc(out: ^[dynamic]Token, a, b: int, k: Token_Kind) { if b > a do append(out, Token{start = a, end = b, kind = k}) }
	for i < n {
		// inside a block comment
		if st >= LINE_IN_COMMENT && st < LINE_IN_RAW {
			depth := int(st)
			a := i
			open, close := lang.block_comment[0], lang.block_comment[1]
			for i < n {
				if len(close) > 0 && strings.has_prefix(line[i:], close) {
					i += len(close)
					depth -= 1
					if depth == 0 do break
					continue
				}
				if lang.nested_comments && len(open) > 0 && strings.has_prefix(line[i:], open) {
					i += len(open)
					depth += 1
					continue
				}
				i += 1
			}
			emit(out, a, i, .Comment)
			st = u32(depth) if depth > 0 else 0
			continue
		}
		// inside a raw string
		if st == LINE_IN_RAW {
			a := i
			closed := false
			for i < n {
				if rune(line[i]) == lang.raw_quote {
					i += 1
					closed = true
					break
				}
				i += 1
			}
			emit(out, a, i, .String)
			if closed do st = 0
			continue
		}
		c := line[i]
		switch {
		case c == ' ' || c == '\t' || c == '\r':
			i += 1
		case len(lang.line_comment) > 0 && strings.has_prefix(line[i:], lang.line_comment):
			emit(out, i, n, .Comment)
			i = n
		case len(lang.block_comment[0]) > 0 && strings.has_prefix(line[i:], lang.block_comment[0]):
			i += len(lang.block_comment[0])
			st = LINE_IN_COMMENT
			// the loop's comment branch takes it from here, joining the opener
			a := i - len(lang.block_comment[0])
			depth := 1
			open, close := lang.block_comment[0], lang.block_comment[1]
			for i < n {
				if strings.has_prefix(line[i:], close) {
					i += len(close)
					depth -= 1
					if depth == 0 do break
					continue
				}
				if lang.nested_comments && strings.has_prefix(line[i:], open) {
					i += len(open)
					depth += 1
					continue
				}
				i += 1
			}
			emit(out, a, i, .Comment)
			st = u32(depth) if depth > 0 else 0
		case lang.raw_quote != 0 && rune(c) == lang.raw_quote:
			a := i
			i += 1
			closed := false
			for i < n {
				if rune(line[i]) == lang.raw_quote {
					i += 1
					closed = true
					break
				}
				i += 1
			}
			emit(out, a, i, .String)
			st = 0 if closed else LINE_IN_RAW
		case strings.index_byte(lang.quotes, c) >= 0:
			a := i
			q := c
			i += 1
			for i < n {
				if line[i] == '\\' && i + 1 < n {
					i += 2
					continue
				}
				if line[i] == q {
					i += 1
					break
				}
				i += 1
			}
			emit(out, a, i, .String)
		case is_digit(c) || (c == '.' && i + 1 < n && is_digit(line[i + 1])):
			a := i
			i += 1
			if c == '0' && i < n && (line[i] == 'x' || line[i] == 'X' || line[i] == 'b' || line[i] == 'B' || line[i] == 'o' || line[i] == 'O') {
				i += 1
				for i < n && (is_ident_char(line[i]) || line[i] == '_') do i += 1
			} else {
				for i < n {
					ch := line[i]
					sign := (ch == '+' || ch == '-') && (line[i - 1] == 'e' || line[i - 1] == 'E')
					if !(is_digit(ch) || ch == '_' || ch == '.' || ch == 'e' || ch == 'E' || sign) do break
					i += 1
				}
				for i < n && is_ident_char(line[i]) do i += 1 // suffixes: 1.5f, 10u
			}
			emit(out, a, i, .Number)
		case len(lang.attribute) > 0 && strings.index_byte(lang.attribute, c) >= 0:
			a := i
			i += 1
			if i < n && line[i] == '(' { // @(private = "file")
				depth := 0
				for i < n {
					if line[i] == '(' do depth += 1
					if line[i] == ')' {
						depth -= 1
						if depth == 0 {
							i += 1
							break
						}
					}
					i += 1
				}
			} else {
				for i < n && is_ident_char(line[i]) do i += 1
			}
			emit(out, a, i, .Attribute)
		case is_ident_start(c):
			a := i
			for i < n && is_ident_char(line[i]) do i += 1
			w := line[a:i]
			k := Token_Kind.Ident
			switch {
			case word_in(lang.keywords, w, lang.case_insensitive):  k = .Keyword
			case word_in(lang.types, w, lang.case_insensitive):     k = .Type
			case word_in(lang.constants, w, lang.case_insensitive): k = .Constant
			}
			emit(out, a, i, k)
		case strings.index_byte(lang.brackets, c) >= 0 || c == ',' || c == ';' || c == '.':
			emit(out, i, i + 1, .Punct)
			i += 1
		case strings.index_byte("+-*/%=<>!&|^~?:$", c) >= 0:
			a := i
			for i < n && strings.index_byte("+-*/%=<>!&|^~?:$", line[i]) >= 0 do i += 1
			if lang.name == "Odin" && line[a:i] == "---" { // Odin's "no value" — a constant
				emit(out, a, i, .Constant)
			} else {
				emit(out, a, i, .Operator)
			}
		case:
			i += 1
		}
	}
	return st
}

// bracket_match_in finds the bracket paired with the one at `off` in `text`
// (a single block), by nesting; -1 when there is none.
bracket_match_in :: proc(lang: ^Language, text: string, off: int) -> int {
	lang := lang if lang != nil else &LANG_PLAIN
	if off < 0 || off >= len(text) do return -1
	c := text[off]
	k := strings.index_byte(lang.brackets, c)
	if k < 0 do return -1
	opener := k % 2 == 0
	mate := lang.brackets[k + 1] if opener else lang.brackets[k - 1]
	depth := 0
	if opener {
		for i := off; i < len(text); i += 1 {
			if text[i] == c do depth += 1
			if text[i] == mate {
				depth -= 1
				if depth == 0 do return i
			}
		}
	} else {
		for i := off; i >= 0; i -= 1 {
			if text[i] == c do depth += 1
			if text[i] == mate {
				depth -= 1
				if depth == 0 do return i
			}
		}
	}
	return -1
}
