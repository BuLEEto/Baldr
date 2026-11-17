#+build darwin
package main

// What macOS answers about a locale, for a handful of them.
//
// On a machine set to an English locale, every Locale field but the tag
// matches LOCALE_EN, so a working reader and one that quietly returns the
// fallback print the same line. Asking about locales the machine is not set
// to tells them apart without changing its settings.
//
//   ./build.sh spike locale_check run            # a useful handful
//   ./build.sh spike locale_check run de_DE ja_JP
//
// What to look for: month and day names in the language, a date pattern
// in that locale's order, a comma where a comma belongs, and 12h where
// the locale writes AM/PM. If every line matches the English fallback, the
// reader is not reading.
//
// The first day of the week is left out: it comes from NSCalendar's
// `currentCalendar`, the machine's own setting rather than the named
// locale's (the right source for the backend, since a person can set it
// apart from their locale), so it says nothing about the locale asked.

import "core:fmt"
import "core:os"
import "baldr:platform/cocoa"

DEFAULTS := []string{"en_GB", "en_US", "de_DE", "fr_FR", "ja_JP", "ar_EG"}

main :: proc() {
	tags := DEFAULTS
	if len(os.args) > 1 do tags = os.args[1:]
	for tag in tags {
		l, ok := cocoa.locale_by_tag(tag, context.temp_allocator)
		if !ok {
			fmt.printfln("%-6s  (macOS does not know this one)", tag)
			continue
		}
		fmt.printfln("%-6s  tag %-8s date %-12s %s  am/pm %q/%q  decimal %q  group %q",
			tag, l.tag, l.date_format, "24h" if l.time_24h else "12h",
			l.am, l.pm, l.decimal, l.thousands)
		fmt.printfln("        months  %s … %s", l.months[0], l.months[11])
		fmt.printfln("        days    %s … %s", l.weekdays[0], l.weekdays[6])
	}
}
