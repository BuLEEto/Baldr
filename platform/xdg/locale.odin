#+build linux
// The user's locale from libc: setlocale(LC_ALL, "") adopts the
// environment (LANG / LC_TIME / LC_NUMERIC), nl_langinfo hands out the
// names and formats, localeconv the decimal point. glibc's first-weekday
// item is a GNU extension read the same way. Read once at init; every
// string is cloned so the backend owns it.
package xdg

import "base:runtime"
import "core:strings"
import "core:sys/posix"
import "baldr:platform"

locale_read :: proc(allocator := context.allocator) -> (l: platform.Locale) {
	en := platform.LOCALE_EN
	l = en
	posix.setlocale(.ALL, "")
	name := string(posix.setlocale(.TIME, nil))
	if name == "" || name == "C" || name == "POSIX" do return
	own :: proc(s: cstring, fallback: string, allocator: runtime.Allocator) -> string {
		if s == nil || len(s) == 0 do return fallback
		return strings.clone(string(s), allocator)
	}
	l.tag = strings.clone(name, allocator)
	if dot := strings.index_byte(l.tag, '.'); dot >= 0 do l.tag = l.tag[:dot]
	// glibc's item numbers from <langinfo.h>, used directly because
	// core:sys/posix's nl_item enum is off by one to three on Linux (its
	// MON_1 reads February). LC_TIME items are 0x20000 + index.
	nl :: proc(item: int) -> cstring { return posix.nl_langinfo(posix.nl_item(item)) }
	ABDAY_1, DAY_1, ABMON_1, MON_1 :: 0x20000, 0x20007, 0x2000E, 0x2001A
	AM_STR, PM_STR, D_FMT, T_FMT :: 0x20026, 0x20027, 0x20029, 0x2002A
	FIRST_WEEKDAY :: 0x20068 // _NL_TIME_FIRST_WEEKDAY: one byte, 1 = the day of WEEK_1STDAY (19971130, a Sunday)
	for i in 0 ..< 12 {
		l.months[i] = own(nl(MON_1 + i), en.months[i], allocator)
		l.months_short[i] = own(nl(ABMON_1 + i), en.months_short[i], allocator)
	}
	for i in 0 ..< 7 {
		l.weekdays[i] = own(nl(DAY_1 + i), en.weekdays[i], allocator)
		l.weekdays_short[i] = own(nl(ABDAY_1 + i), en.weekdays_short[i], allocator)
	}
	l.date_format = own(nl(D_FMT), en.date_format, allocator)
	l.am = own(nl(AM_STR), "AM", allocator)
	l.pm = own(nl(PM_STR), "PM", allocator)
	tfmt := string(nl(T_FMT))
	l.time_24h = !strings.contains(tfmt, "%p") && !strings.contains(tfmt, "%I") && !strings.contains(tfmt, "%l")
	if lc := posix.localeconv(); lc != nil {
		l.decimal = own(lc.decimal_point, ".", allocator)
		l.thousands = own(lc.thousand_sep, "", allocator)
	}
	if p := nl(FIRST_WEEKDAY); p != nil {
		if b := (^u8)(p)^; b >= 1 && b <= 7 do l.first_weekday = (b - 1) % 7
	}
	posix.setlocale(.ALL, "C") // the rest of the toolkit prints and parses with a point
	return
}

locale_free :: proc(l: ^platform.Locale, allocator := context.allocator) {
	platform.locale_free(l, allocator)
}

