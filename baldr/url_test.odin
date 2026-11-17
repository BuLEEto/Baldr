package baldr

@(require) import "core:strings"
@(require) import "core:testing"
@(require) import "baldr:platform"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Opening a link with the desktop's own handler. What the toolkit
// will hand over, and that an app always hears how it went.


@(private = "file")
Url_Msg :: union { int }

@(test)
only_a_link_the_desktop_should_open_is_handed_over :: proc(t: ^testing.T) {
	for url in ([]string{
		"https://auth.openai.com/authorize?client_id=x&state=y", // a sign-in
		"http://localhost:1455/callback",                        // …and its callback
		"HTTPS://Example.COM/Path",                              // a scheme is case-insensitive
		"https://user:pass@example.com/x",                       // the desktop's to judge, not ours
		"https://example.com",
		"mailto:someone@example.com?subject=Hello",
	}) {
		testing.expectf(t, url_openable(url), "%q opens", url)
	}
	for url in ([]string{
		"",
		"file:///etc/shadow",                    // not a link: a file
		"javascript:alert(1)",                   // nor a program
		"data:text/html;base64,PHNjcmlwdD4=",
		"vbscript:msgbox",
		"acme://run?cmd=rm",                  // nor another app's scheme
		"//example.com/x",                       // no scheme at all
		"example.com",
		"https://",                              // no host
		"http:///no-host/path",
		"mailto:",
		"mailto:?to=someone@example.com",        // an address, not a query
		"mailto:a@example.com?attach=~/.ssh/id_rsa",
		"mailto:a@example.com?subject=x&Attachment=/etc/passwd",
		"mailto:a@example.com?%61ttach=/home",
		"https://example.com/a b",               // a space: a URL escapes it
		"https://example.com/\nx",               // a newline
		"https://example.com/\x00x",
	}) {
		testing.expectf(t, !url_openable(url), "%q does not open", url)
	}
	long := strings.repeat("a", URL_MAX, context.temp_allocator)
	testing.expect(t, !url_openable(concat_url("https://example.com/", long)), "a runaway URL does not open")
}

@(private = "file")
concat_url :: proc(a, b: string) -> string {
	return strings.concatenate({a, b}, context.temp_allocator)
}

// Url_Log is the fake backend: the links it was asked to open.
@(private = "file")
Url_Log :: struct {
	asked: [8]string,
	n:     int,
	token: u64,
	take:  bool, // whether it accepts the ask
}

@(test)
an_app_always_hears_how_the_link_went :: proc(t: ^testing.T) {
	log := Url_Log{take = true}
	b := platform.Backend{data = &log}
	b.open_url = proc(b: ^platform.Backend, url: string, token: u64) -> bool {
		lg := (^Url_Log)(b.data)
		if !lg.take do return false
		lg.asked[lg.n] = url
		lg.n += 1
		lg.token = token
		return true
	}
	rt: Runtime(int, Url_Msg)
	rt.backend = &b
	defer {
		for _, ask in rt.pending_urls do delete(ask.url)
		delete(rt.pending_urls)
		// An answered ask's string is handed to the app inside the message, so
		// the runtime frees it after update has run (app.odin); nothing runs
		// update here, so the test drains it or the leak report fills with noise.
		for str in rt.spent_asks do delete(str)
		delete(rt.spent_asks)
		delete(rt.msgs)
	}
	heard :: proc(e: Ev(Url_Opened)) -> Url_Msg { return Url_Msg(1 if e.value.ok else 0) }

	run_cmd(&rt, open_url(Url_Msg, "https://example.com/a", heard))
	testing.expect(t, log.n == 1 && log.asked[0] == "https://example.com/a", "the desktop was asked")
	testing.expect(t, len(rt.msgs) == 0 && len(rt.pending_urls) == 1, "nothing said yet: the desktop answers later")
	url_open_done(&rt, {token = log.token, ok = true})
	testing.expect(t, len(rt.msgs) == 1 && rt.msgs[0] == 1 && len(rt.pending_urls) == 0, "opened")
	clear(&rt.msgs)

	// the desktop had nothing to open it with
	run_cmd(&rt, open_url(Url_Msg, "https://example.com/b", heard))
	url_open_done(&rt, {token = log.token, ok = false})
	testing.expect(t, len(rt.msgs) == 1 && rt.msgs[0] == 0, "not opened: the app can offer the link to copy")
	clear(&rt.msgs)
	url_open_done(&rt, {token = log.token, ok = true}) // an answer twice over is not heard twice
	testing.expect_value(t, len(rt.msgs), 0)

	// a link the toolkit will not open never reaches the backend
	run_cmd(&rt, open_url(Url_Msg, "file:///etc/shadow", heard))
	testing.expect(t, log.n == 2 && len(rt.msgs) == 1 && rt.msgs[0] == 0, "refused here, and the app hears so")
	clear(&rt.msgs)

	// the backend could not even ask
	log.take = false
	run_cmd(&rt, open_url(Url_Msg, "https://example.com/c", heard))
	testing.expect(t, len(rt.msgs) == 1 && rt.msgs[0] == 0 && len(rt.pending_urls) == 0)
	clear(&rt.msgs)

	// a desktop with no way to open links at all
	b.open_url = nil
	run_cmd(&rt, open_url(Url_Msg, "https://example.com/d", heard))
	testing.expect(t, len(rt.msgs) == 1 && rt.msgs[0] == 0, "still an answer")
}

} // when ODIN_TEST