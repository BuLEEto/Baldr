// locale — what does this platform say the person's regional settings are?
//
// A backend without `Backend.locale` leaves every app on LOCALE_EN — US
// month names, a point for the decimal mark — whatever the person has set.
// This prints what the toolkit ended up with, so platforms can be read side
// by side.
//
// Prints once and quits, to stdout and to `BALDR_LOCALE_LOG` when that is
// set. The file matters on Windows: an SSH process lands in session 0, so
// the real check runs as a scheduled task in the interactive session, where
// stdout goes nowhere.
//
//   ./build.sh spike locale run
//
// On Wayland with glibc and en_GB it reads:
//
//   tag en_GB  dates %d/%m/%y  24h  decimal "."  thousands ","  first day 1 (Monday)
//   am "am"  pm "pm"
//   months  January February March …
//   weekdays (Sunday first)  Sunday Monday Tuesday …
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "baldr:baldr"

State :: struct { said: bool }
Msg :: union { Go }
Go :: struct {}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "locale", app_id = "baldr.locale", size = {360, 120},
		init = proc() -> State { return {} },
		start = proc(s: ^State) -> baldr.Cmd(Msg) { return baldr.delay(Msg, 300, Go{}) },
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) { return baldr.quit(Msg) },
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			if !s.said {
				s.said = true // the locale hangs off the tree, so it is read here
				report(ui.locale)
			}
			baldr.column(ui, flex = 1, padding = .lg); defer baldr.end(ui)
			baldr.text(ui, "reading the locale…", role = .Headline)
		},
	})
}

report :: proc(l: baldr.Locale) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	day := l.weekdays[l.first_weekday] if int(l.first_weekday) < len(l.weekdays) else "?"
	fmt.sbprintfln(&b, "tag %s  dates %s  %s  decimal %q  thousands %q  first day %d (%s)",
		l.tag, l.date_format, "24h" if l.time_24h else "12h", l.decimal, l.thousands, l.first_weekday, day)
	fmt.sbprintfln(&b, "am %q  pm %q", l.am, l.pm)
	fmt.sbprint(&b, "months  ")
	for m in l.months do fmt.sbprintf(&b, "%s ", m)
	fmt.sbprint(&b, "\nshort   ")
	for m in l.months_short do fmt.sbprintf(&b, "%s ", m)
	fmt.sbprint(&b, "\nweekdays (Sunday first)  ")
	for d in l.weekdays do fmt.sbprintf(&b, "%s ", d)
	fmt.sbprint(&b, "\nshort   ")
	for d in l.weekdays_short do fmt.sbprintf(&b, "%s ", d)
	fmt.sbprintln(&b)
	text := strings.to_string(b)
	fmt.print(text)
	os.flush(os.stdout)
	if path := os.get_env("BALDR_LOCALE_LOG", context.temp_allocator); path != "" {
		_ = os.write_entire_file(path, transmute([]u8)text)
	}
}
