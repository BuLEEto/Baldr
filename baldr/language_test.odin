package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: behind this `when`, checking a program costs
// 1.0 GB instead of 9.2 GB. ODIN_TEST is set by `odin test`; BALDR_TESTS
// lets ./build.sh check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
kinds :: proc(lang: ^Language, line: string, state: u32 = 0) -> (out: [dynamic]Token, next: u32) {
	out = make([dynamic]Token, context.temp_allocator)
	next = tokenize_line(lang, line, state, &out)
	return
}

// The Odin tokenizer colours keywords, types, constants, numbers, strings,
// attributes and comments; a block comment carries its state into the next
// line (nesting included); a raw string spans lines.
@(test)
language_tokenizes_odin :: proc(t: ^testing.T) {
	toks, st := kinds(&LANG_ODIN, `x: f32 = 0x1F + 2.5 // hi`)
	testing.expect_value(t, st, u32(0))
	got := make([dynamic]Token_Kind, context.temp_allocator)
	for tk in toks do append(&got, tk.kind)
	testing.expect_value(t, len(toks), 8)
	want := []Token_Kind{.Ident, .Operator, .Type, .Operator, .Number, .Operator, .Number, .Comment}
	for k, i in want do if i < len(got) do testing.expect_value(t, got[i], k)
	testing.expect_value(t, toks[7].start, 20)
	toks, st = kinds(&LANG_ODIN, `@(private = "file") proc(s: string) -> bool { return true /* a /* nested */`)
	testing.expect_value(t, toks[0].kind, Token_Kind.Attribute)
	testing.expect_value(t, toks[0].end, 19)
	testing.expect_value(t, toks[1].kind, Token_Kind.Keyword) // proc
	testing.expect_value(t, toks[len(toks) - 1].kind, Token_Kind.Comment)
	testing.expect_value(t, st, u32(1)) // still one comment deep
	toks, st = kinds(&LANG_ODIN, `still */ x := "q\"q" + 'c'`, st)
	testing.expect_value(t, toks[0].kind, Token_Kind.Comment)
	testing.expect_value(t, toks[0].end, 8)
	testing.expect_value(t, st, u32(0))
	testing.expect_value(t, toks[3].kind, Token_Kind.String)
	testing.expect_value(t, toks[3].end, 20) // the escaped quote stays inside
	toks, st = kinds(&LANG_ODIN, "s := `raw")
	testing.expect_value(t, st, LINE_IN_RAW)
	toks, st = kinds(&LANG_ODIN, "more` + nil", st)
	testing.expect_value(t, toks[0].kind, Token_Kind.String)
	testing.expect_value(t, toks[2].kind, Token_Kind.Constant)
	testing.expect_value(t, st, u32(0))
	// C and JSON share the machine
	toks, _ = kinds(&LANG_C, `#include <stdio.h> int main(void) { return NULL; }`)
	testing.expect_value(t, toks[0].kind, Token_Kind.Attribute)
	testing.expect_value(t, toks[len(toks) - 3].kind, Token_Kind.Constant)
	toks, _ = kinds(&LANG_JSON, `{"a": [1, true, null]}`)
	testing.expect_value(t, toks[1].kind, Token_Kind.String)
	testing.expect_value(t, toks[4].kind, Token_Kind.Number)
	testing.expect_value(t, toks[6].kind, Token_Kind.Constant)
	// bracket matching by nesting
	testing.expect_value(t, bracket_match_in(&LANG_ODIN, "f(a(b), c)", 1), 9)
	testing.expect_value(t, bracket_match_in(&LANG_ODIN, "f(a(b), c)", 9), 1)
	testing.expect_value(t, bracket_match_in(&LANG_ODIN, "f(a(b), c", 1), -1)
}

// A case-insensitive language matches its words in any case, and a
// language with its own tokenizer proc takes over the machine entirely.
@(test)
language_is_extensible :: proc(t: ^testing.T) {
	toks, _ := kinds(&LANG_SQL, `SELECT id, name FROM users WHERE age > 30 -- adults`)
	testing.expect_value(t, toks[0].kind, Token_Kind.Keyword)     // SELECT
	testing.expect_value(t, toks[4].kind, Token_Kind.Keyword)     // FROM
	testing.expect_value(t, toks[len(toks) - 1].kind, Token_Kind.Comment)
	toks, _ = kinds(&LANG_SQL, `select count(*) from t`)
	testing.expect_value(t, toks[0].kind, Token_Kind.Keyword)     // lower case too
	// a custom tokenizer: everything up to the first space is a keyword
	shout :: proc(lang: ^Language, line: string, state: u32, out: ^[dynamic]Token) -> u32 {
		sp := 0
		for sp < len(line) && line[sp] != ' ' do sp += 1
		if sp > 0 do append(out, Token{start = 0, end = sp, kind = .Keyword})
		if sp < len(line) do append(out, Token{start = sp + 1, end = len(line), kind = .String})
		return state + 1 // states are the language's own
	}
	custom := Language{name = "Shout", tokenize = shout, brackets = "()"}
	toks2, st := kinds(&custom, "hello there world", 7)
	testing.expect_value(t, len(toks2), 2)
	testing.expect_value(t, toks2[0].kind, Token_Kind.Keyword)
	testing.expect_value(t, toks2[1].kind, Token_Kind.String)
	testing.expect_value(t, st, u32(8))
}

} // when ODIN_TEST