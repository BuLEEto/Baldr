package platform

// Turning a desktop's date pattern into the strftime subset the toolkit's
// date widgets parse.
//
// Windows and macOS both write their short-date pattern in CLDR's token
// vocabulary, where a repeated letter says how wide the field is, so one
// reader serves both.

import "core:strings"

// Date_Pattern_Dialect is whose short-date pattern is being read. The two
// desktops disagree on one field, silently, so the caller says which.
Date_Pattern_Dialect :: enum u8 {
	// A lone "y" is two digits, as "yy" is; only "yyy" or more is the
	// whole year. (Windows: "y" is "the year without the century".)
	Windows,
	// A lone "y" is the whole year, and only exactly "yy" is two digits.
	// macOS gives "dd/MM/y" for en_GB, which the Windows rule would print
	// as "26".
	Cldr,
}

// date_pattern_to_strftime rewrites a short-date pattern as the strftime
// subset `widget_date.odin` understands: %d %e %m %b %B %y %Y and
// separators. Tokens the parser cannot say (a weekday name `ddd`/`E`, an era
// `g`/`G`, a quarter `Q`) are dropped with the separator after them. Quoted
// text is literal, a literal "%" is doubled, and `L` (CLDR's standalone
// month) means `M`. The string is the caller's, from `allocator`.
date_pattern_to_strftime :: proc(pattern: string, dialect: Date_Pattern_Dialect, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	i := 0
	for i < len(pattern) {
		c := pattern[i]
		if c == '\'' { // a quoted literal, '' being one quote
			i += 1
			for i < len(pattern) && pattern[i] != '\'' {
				if pattern[i] == '%' do strings.write_byte(&b, '%')
				strings.write_byte(&b, pattern[i])
				i += 1
			}
			i += 1
			continue
		}
		if !date_token(c) {
			if c == '%' do strings.write_byte(&b, '%')
			strings.write_byte(&b, c)
			i += 1
			continue
		}
		run := 0
		for i + run < len(pattern) && pattern[i + run] == c do run += 1
		switch c {
		case 'd':
			switch {
			case run >= 3: skip_separator(pattern, &i, run) // a weekday name: nothing to say it with
				continue
			case run == 2: strings.write_string(&b, "%d")
			case:          strings.write_string(&b, "%e")
			}
		case 'M', 'L': // CLDR's L is the standalone month, the same field
			switch {
			case run >= 4: strings.write_string(&b, "%B")
			case run == 3: strings.write_string(&b, "%b")
			case:          strings.write_string(&b, "%m")
			}
		case 'y':
			two := run == 2 if dialect == .Cldr else run <= 2
			strings.write_string(&b, "%y" if two else "%Y")
		case 'g', 'G', 'E', 'c', 'Q', 'q': // era, weekday name, quarter: no token for any of them
			skip_separator(pattern, &i, run)
			continue
		}
		i += run
	}
	return strings.to_string(b)
}

@(private = "file")
date_token :: proc "contextless" (c: byte) -> bool {
	switch c {
	case 'd', 'M', 'L', 'y', 'g', 'G', 'E', 'c', 'Q', 'q': return true
	}
	return false
}

// skip_separator steps past a dropped token and the punctuation and spaces
// that were only there to sit beside it.
@(private = "file")
skip_separator :: proc(pattern: string, i: ^int, run: int) {
	i^ += run
	for i^ < len(pattern) {
		switch pattern[i^] {
		case ' ', ',', '.', '-', '/': i^ += 1
		case: return
		}
	}
}

// locale_free frees what a backend's locale reader allocated and resets `l`
// to LOCALE_EN. A string is the reader's when it is not one of the LOCALE_EN
// literals it fell back to — told by where it lives, not what it says, since
// English read from an English desktop is the reader's copy all the same.
locale_free :: proc(l: ^Locale, allocator := context.allocator) {
	en := LOCALE_EN
	owned :: proc(s, fallback: string) -> bool { return len(s) > 0 && raw_data(s) != raw_data(fallback) }
	if owned(l.tag, en.tag) do delete(l.tag, allocator)
	for i in 0 ..< 12 {
		if owned(l.months[i], en.months[i]) do delete(l.months[i], allocator)
		if owned(l.months_short[i], en.months_short[i]) do delete(l.months_short[i], allocator)
	}
	for i in 0 ..< 7 {
		if owned(l.weekdays[i], en.weekdays[i]) do delete(l.weekdays[i], allocator)
		if owned(l.weekdays_short[i], en.weekdays_short[i]) do delete(l.weekdays_short[i], allocator)
	}
	if owned(l.date_format, en.date_format) do delete(l.date_format, allocator)
	if owned(l.am, en.am) do delete(l.am, allocator)
	if owned(l.pm, en.pm) do delete(l.pm, allocator)
	if owned(l.decimal, en.decimal) do delete(l.decimal, allocator)
	if owned(l.thousands, en.thousands) do delete(l.thousands, allocator)
	l^ = en
}
