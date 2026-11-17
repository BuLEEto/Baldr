#+build darwin
package cocoa

// The person's locale, from macOS's regional settings (Backend.locale).
// Same job as `platform/win32/locale.odin` and `platform/xdg/locale.odin`.
//
// Foundation's locale classes are not in the Odin bindings, so this goes
// through the objc runtime as clipboard.odin does: NSLocale for the tag,
// NSDateFormatter for names and patterns, NSCalendar for the first day of
// the week, NSNumberFormatter for the separators.
//
// Three things are translated rather than copied:
//
//   - The pattern: macOS writes CLDR ("dd/MM/y"), the contract is strftime
//     ("%d/%m/%Y"), via `platform.date_pattern_to_strftime`.
//   - The first day: NSCalendar counts 1 = Sunday, the contract 0 = Sunday.
//   - The clock: macOS has no 24-hour flag, so it is whether the locale's
//     preferred hour pattern carries an AM/PM field.
//
// Read once at init; every string is cloned so the backend owns it.

import NS "vendor:darwin/AppKit"
import "base:intrinsics"
import "base:runtime"
import "core:strings"
import "baldr:platform"

@(private) NS_NUMBER_STYLE_DECIMAL :: NS.UInteger(1) // NSNumberFormatterDecimalStyle

@(private, objc_class = "NSLocale")          Loc_Locale   :: struct { using _: NS.Object }
@(private, objc_class = "NSDateFormatter")   Loc_DateFmt  :: struct { using _: NS.Object }
@(private, objc_class = "NSNumberFormatter") Loc_NumFmt   :: struct { using _: NS.Object }
@(private, objc_class = "NSCalendar")        Loc_Calendar :: struct { using _: NS.Object }

@(private)
b_locale :: proc(b: ^platform.Backend) -> platform.Locale {
	return self(b).locale
}

// locale_read builds the Locale once. Every failure falls back to the
// matching LOCALE_EN field rather than to an empty string, so a desktop
// that answers nothing still gives a usable date.
@(private)
locale_read :: proc(allocator := context.allocator) -> (l: platform.Locale) {
	l = platform.LOCALE_EN
	loc := intrinsics.objc_send(^Loc_Locale, Loc_Locale, "currentLocale")
	if loc == nil do return // no locale to read: English it is
	return locale_of(loc, allocator)
}

// locale_of reads one NSLocale. Split from `locale_read` so a locale other
// than the machine's can be read: on an English machine a correct reader and
// one that returns the fallback look alike. Strings are from `allocator`;
// free with locale_free.
@(private)
locale_of :: proc(loc: ^Loc_Locale, allocator := context.allocator) -> (l: platform.Locale) {
	en := platform.LOCALE_EN
	l = en
	if loc == nil do return

	l.tag = ns_clone(intrinsics.objc_send(^NS.String, loc, "localeIdentifier"), en.tag, allocator)

	df := intrinsics.objc_send(^Loc_DateFmt, Loc_DateFmt, "alloc")
	df = intrinsics.objc_send(^Loc_DateFmt, df, "init")
	if df == nil {
		return
	}
	defer intrinsics.objc_send(nil, df, "release")
	intrinsics.objc_send(nil, df, "setLocale:", loc)

	// Sunday-first and January-first, the contract's order. objc_send needs
	// the selector as a literal, so each array is fetched at its own call.
	symbols(intrinsics.objc_send(^NS.Array, df, "monthSymbols"),        l.months[:],         en.months[:],         allocator)
	symbols(intrinsics.objc_send(^NS.Array, df, "shortMonthSymbols"),   l.months_short[:],   en.months_short[:],   allocator)
	symbols(intrinsics.objc_send(^NS.Array, df, "weekdaySymbols"),      l.weekdays[:],       en.weekdays[:],       allocator)
	symbols(intrinsics.objc_send(^NS.Array, df, "shortWeekdaySymbols"), l.weekdays_short[:], en.weekdays_short[:], allocator)

	l.am = ns_clone(intrinsics.objc_send(^NS.String, df, "AMSymbol"), en.am, allocator)
	l.pm = ns_clone(intrinsics.objc_send(^NS.String, df, "PMSymbol"), en.pm, allocator)

	// "yMd": a year, month and day as this locale writes them, the short date.
	if pattern := template(loc, "yMd", allocator); pattern != "" {
		defer delete(pattern, allocator)
		if f := platform.date_pattern_to_strftime(pattern, .Cldr, allocator); f != "" {
			l.date_format = f
		}
	}
	// "j" is the hour as this locale prefers it; a 12-hour locale gets an
	// AM/PM field with it.
	if hour := template(loc, "j", allocator); hour != "" {
		defer delete(hour, allocator)
		l.time_24h = !strings.contains(hour, "a")
	}

	nf := intrinsics.objc_send(^Loc_NumFmt, Loc_NumFmt, "alloc")
	nf = intrinsics.objc_send(^Loc_NumFmt, nf, "init")
	if nf != nil {
		defer intrinsics.objc_send(nil, nf, "release")
		intrinsics.objc_send(nil, nf, "setLocale:", loc)
		intrinsics.objc_send(nil, nf, "setNumberStyle:", NS_NUMBER_STYLE_DECIMAL)
		l.decimal = ns_clone(intrinsics.objc_send(^NS.String, nf, "decimalSeparator"), en.decimal, allocator)
		// A locale that groups with nothing is not a failure, so "" stands
		// rather than falling back to a comma.
		l.thousands = ns_clone(intrinsics.objc_send(^NS.String, nf, "groupingSeparator"), "", allocator)
	}

	if cal := intrinsics.objc_send(^Loc_Calendar, Loc_Calendar, "currentCalendar"); cal != nil {
		fw := intrinsics.objc_send(NS.UInteger, cal, "firstWeekday") // 1 = Sunday
		if fw >= 1 && fw <= 7 do l.first_weekday = u8(fw - 1)
	}
	return
}

@(private)
locale_free :: proc(l: ^platform.Locale, allocator := context.allocator) {
	platform.locale_free(l, allocator)
}

// symbols fills `out` from one of NSDateFormatter's name arrays, leaving a
// name as its English fallback where the array is short or holds nothing.
@(private = "file")
symbols :: proc(arr: ^NS.Array, out: []string, fallback: []string, allocator: runtime.Allocator) {
	if arr == nil do return
	n := int(intrinsics.objc_send(NS.UInteger, arr, "count"))
	for i in 0 ..< len(out) {
		if i >= n do return
		s := intrinsics.objc_send(^NS.String, arr, "objectAtIndex:", NS.UInteger(i))
		out[i] = ns_clone(s, fallback[i], allocator)
	}
}

// template asks the locale how it likes to write the fields in `skeleton`
// ("yMd" is a short date, "j" the hour). The caller owns the result.
@(private = "file")
template :: proc(loc: ^Loc_Locale, skeleton: string, allocator: runtime.Allocator) -> string {
	sk := ns_str(skeleton)
	defer sk->release()
	got := intrinsics.objc_send(^NS.String, Loc_DateFmt, "dateFormatFromTemplate:options:locale:",
		sk, NS.UInteger(0), loc)
	if got == nil do return ""
	out, err := strings.clone(string(got->odinString()), allocator)
	if err != nil do return ""
	return out
}

// ns_clone copies an NSString the caller then owns, or hands back the
// fallback (a LOCALE_EN literal, which locale_free knows not to free).
@(private = "file")
ns_clone :: proc(s: ^NS.String, fallback: string, allocator: runtime.Allocator) -> string {
	if s == nil do return fallback
	got := string(s->odinString())
	if got == "" do return fallback
	out, err := strings.clone(got, allocator)
	if err != nil do return fallback
	return out
}

// locale_by_tag reads a named locale ("de_DE") rather than this machine's,
// for `spikes/locale_check`; nothing in the backend calls it. Strings are
// from `allocator`; false and LOCALE_EN when NSLocale gives no locale.
locale_by_tag :: proc(tag: string, allocator := context.allocator) -> (platform.Locale, bool) {
	id := ns_str(tag)
	defer id->release()
	loc := intrinsics.objc_send(^Loc_Locale, Loc_Locale, "localeWithLocaleIdentifier:", id)
	if loc == nil do return platform.LOCALE_EN, false
	return locale_of(loc, allocator), true
}
