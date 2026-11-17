#+build windows
package win32

// The user's locale, from the Windows regional settings (Backend.locale).
//
// Same job as platform/xdg's libc reading, and the same promise: dates,
// times, numbers and day names follow the desktop, not the toolkit.
//
// Three things have to be translated rather than copied across:
//
//   - Day order. LOCALE_SDAYNAME1 is Monday; platform.Locale.weekdays
//     starts at Sunday. LOCALE_IFIRSTDAYOFWEEK counts 0 = Monday, the
//     contract 0 = Sunday.
//   - The date pattern. Windows writes "dd/MM/yyyy"; the contract is
//     strftime ("%d/%m/%Y"), which is what widget_date.odin parses. An
//     unknown %X there is printed literally, so nothing may be emitted that
//     it does not know: %d %e %m %b %B %y %Y.
//   - The tag. Windows gives "en-GB", glibc "en_GB". The underscore
//     wins, so an app comparing tags sees one spelling on both.
//
// Read once at init; every string is cloned so the backend owns it.

import "base:runtime"
import "core:strconv"
import "core:strings"
import win "core:sys/windows"
import "baldr:platform"

// locale is Backend.locale: the regional settings as read at init. The
// strings are the backend's.
locale :: proc(b: ^platform.Backend) -> platform.Locale {
	return data(b).locale
}

@(private)
locale_read :: proc(allocator := context.allocator) -> (l: platform.Locale) {
	en := platform.LOCALE_EN
	l = en

	name_buf: [win.LOCALE_NAME_MAX_LENGTH]win.WCHAR
	n := GetUserDefaultLocaleName(raw_data(name_buf[:]), len(name_buf))
	if n <= 1 do return // no locale to read: English it is
	name := win.wstring(raw_data(name_buf[:]))

	tag, terr := win.utf16_to_utf8(name_buf[:n - 1], allocator) // n counts the NUL
	if terr == nil && tag != "" {
		// replace_all hands back the original when there is nothing to
		// replace, so the old string is only freed when a new one was made.
		swapped, allocated := strings.replace_all(tag, "-", "_", allocator)
		l.tag = swapped
		if allocated do delete(tag, allocator)
	}

	for i in 0 ..< 12 {
		l.months[i] = info(name, LOCALE_SMONTHNAME1 + win.LCTYPE(i), en.months[i], allocator)
		l.months_short[i] = info(name, LOCALE_SABBREVMONTHNAME1 + win.LCTYPE(i), en.months_short[i], allocator)
	}
	// Windows counts from Monday, the contract from Sunday.
	for i in 0 ..< 7 {
		w := 6 if i == 0 else i - 1 // contract index -> Windows offset
		l.weekdays[i] = info(name, LOCALE_SDAYNAME1 + win.LCTYPE(w), en.weekdays[i], allocator)
		l.weekdays_short[i] = info(name, LOCALE_SABBREVDAYNAME1 + win.LCTYPE(w), en.weekdays_short[i], allocator)
	}

	if pattern := info(name, LOCALE_SSHORTDATE, "", allocator); pattern != "" {
		defer delete(pattern, allocator)
		if f := platform.date_pattern_to_strftime(pattern, .Windows, allocator); f != "" {
			l.date_format = f
		}
	}

	l.am = info(name, LOCALE_S1159, "AM", allocator)
	l.pm = info(name, LOCALE_S2359, "PM", allocator)
	l.decimal = info(name, LOCALE_SDECIMAL, ".", allocator)
	l.thousands = info(name, LOCALE_STHOUSAND, "", allocator)
	l.time_24h = info_int(name, LOCALE_ITIME, 1) == 1
	if d := info_int(name, LOCALE_IFIRSTDAYOFWEEK, -1); d >= 0 && d <= 6 {
		l.first_weekday = u8((d + 1) % 7) // 0 = Monday there, 0 = Sunday here
	}
	return
}

@(private)
locale_free :: proc(l: ^platform.Locale, allocator := context.allocator) {
	platform.locale_free(l, allocator)
}

// info reads one string setting, or hands back `fallback` (a LOCALE_EN
// literal, which locale_free knows not to free) when there is none.
@(private = "file")
info :: proc(name: win.wstring, lctype: win.LCTYPE, fallback: string, allocator: runtime.Allocator) -> string {
	buf: [128]win.WCHAR
	n := win.GetLocaleInfoEx(win.LPCWSTR(name), lctype, raw_data(buf[:]), len(buf))
	if n <= 1 do return fallback // 0 is failure, 1 is the NUL alone
	s, err := win.utf16_to_utf8(buf[:n - 1], allocator)
	if err != nil {
		delete(s, allocator)
		return fallback
	}
	if s == "" {
		delete(s, allocator)
		return fallback
	}
	return s
}

// info_int reads a setting Windows stores as digits.
@(private = "file")
info_int :: proc(name: win.wstring, lctype: win.LCTYPE, fallback: int) -> int {
	buf: [16]win.WCHAR
	n := win.GetLocaleInfoEx(win.LPCWSTR(name), lctype, raw_data(buf[:]), len(buf))
	if n <= 1 do return fallback
	s, err := win.utf16_to_utf8(buf[:n - 1], context.temp_allocator)
	if err != nil do return fallback
	v, ok := strconv.parse_int(s)
	return v if ok else fallback
}
