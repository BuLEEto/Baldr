package baldr

// Opening a link: an app hands a URL to the desktop, which opens it in the
// person's own browser or mail app. The toolkit never picks the program and
// never runs a command line — the desktop's handler does both (the OpenURI
// portal, else xdg-open, on Linux; ShellExecuteW on Windows).
//
// Only http, https and mailto are opened. Links often come from untrusted
// text, and `file:`, `data:`, `javascript:` or a program's own scheme is how
// such a link does something nobody asked for. An app that wants one of
// those opens it itself, having decided it is safe.

import "core:strings"
import "baldr:platform"

// URL_MAX is the longest URL that is handed on. Browsers stop caring long
// before this; it is here so a runaway string cannot become an argument.
URL_MAX :: 8192

// Url_Opened is what became of `open_url`: the URL as it was asked for, and
// whether the desktop took it. It is false when nothing is registered for
// the link, the desktop refused it, the person dismissed a chooser, or the
// URL was not one Baldr opens — the app then shows the link to copy. The
// string lives only while the message is handled; clone what you keep.
Url_Opened :: struct {
	url: string,
	ok:  bool,
}

// open_url asks the desktop to open `url` with whatever the person uses for
// it: a browser for http and https, a mail app for mailto. Nothing else is
// opened (see url_openable), and a URL that is refused comes back at once
// as `on_done` with `ok = false` rather than silently doing nothing.
//
//	case Link: return baldr.open_url(Msg, e.value, proc(e: baldr.Ev(baldr.Url_Opened)) -> Msg {
//		return Link_Failed{e.value.url} if !e.value.ok else Nothing{}
//	})
open_url :: proc($Msg: typeid, url: string, on_done: Handler(Msg, Url_Opened) = nil) -> Cmd(Msg) {
	return {kind = .Open_Url, url = temp_clone(url), on_url = on_done}
}

// url_openable says whether `open_url` will hand this URL to the desktop:
// http, https or mailto, no control characters or spaces, a host after the
// scheme (an address for mailto), and no longer than URL_MAX. A mailto that
// names a file to attach is refused: some mail apps attach it without
// asking, so a link in a message could send the reader's own files away. A
// link view can ask first and show an unopenable link as plain text.
url_openable :: proc(url: string) -> bool {
	if len(url) == 0 || len(url) > URL_MAX do return false
	for c in transmute([]u8)url {
		if c < 0x21 || c == 0x7F do return false // control characters, spaces (a URL escapes them), DEL
	}
	rest: string
	web: bool
	switch {
	case has_prefix_fold(url, "https://"): rest, web = url[8:], true
	case has_prefix_fold(url, "http://"):  rest, web = url[7:], true
	case has_prefix_fold(url, "mailto:"):  rest, web = url[7:], false
	case:                                  return false
	}
	if len(rest) == 0 do return false
	if !web { // mailto: an address before any query, not a query that carries one
		addr, query := rest, ""
		if q := strings.index_byte(addr, '?'); q >= 0 do addr, query = addr[:q], addr[q + 1:]
		for field in strings.split_iterator(&query, "&") {
			key := field
			if eq := strings.index_byte(key, '='); eq >= 0 do key = key[:eq]
			key = uri_decode(key, context.temp_allocator) // %61ttach is the same key to a mail app
			if strings.equal_fold(key, "attach") || strings.equal_fold(key, "attachment") do return false
		}
		return strings.index_byte(addr, '@') > 0
	}
	host_end := len(rest)
	for c, i in transmute([]u8)rest do if c == '/' || c == '?' || c == '#' {
		host_end = i
		break
	}
	host := rest[:host_end]
	if len(host) == 0 do return false
	if at := strings.last_index_byte(host, '@'); at >= 0 do host = host[at + 1:] // user:pass@host is the desktop's to judge
	return len(host) > 0
}

// has_prefix_fold: `s` starts with `prefix`, ASCII case folded (a scheme is
// case-insensitive, and HTTPS:// is a URL like any other).
@(private)
has_prefix_fold :: proc(s, prefix: string) -> bool {
	if len(s) < len(prefix) do return false
	lower :: proc(c: u8) -> u8 { return c + 32 if c >= 'A' && c <= 'Z' else c }
	for i in 0 ..< len(prefix) do if lower(s[i]) != lower(prefix[i]) do return false
	return true
}

// url_open_start runs the open_url command: the URL is checked here, so no
// backend sees one the toolkit would not open, and an answer always comes
// back — at once when it cannot be asked for, else as Ev_Url.
@(private)
url_open_start :: proc(rt: ^Runtime($State, $Msg), cmd: Cmd(Msg)) {
	b := rt.backend
	if !url_openable(cmd.url) || b == nil || b.open_url == nil {
		handler_deliver(cmd.on_url, Url_Opened{url = cmd.url, ok = false}, 0, &rt.msgs)
		return
	}
	rt.next_token += 1
	token := rt.next_token
	if !b.open_url(b, cmd.url, token) {
		handler_deliver(cmd.on_url, Url_Opened{url = cmd.url, ok = false}, 0, &rt.msgs)
		return
	}
	rt.pending_urls[token] = Url_Ask(Msg){on_done = cmd.on_url, url = strings.clone(cmd.url)}
}

// Url_Ask is an open_url waiting for the desktop's answer; `url` is owned.
@(private)
Url_Ask :: struct($Msg: typeid) {
	on_done: Handler(Msg, Url_Opened),
	url:     string,
}

// url_open_done delivers the desktop's answer (Ev_Url) to the app.
@(private)
url_open_done :: proc(rt: ^Runtime($State, $Msg), e: platform.Ev_Url) {
	ask, waiting := rt.pending_urls[e.token]
	if !waiting do return
	delete_key(&rt.pending_urls, e.token)
	handler_deliver(ask.on_done, Url_Opened{url = ask.url, ok = e.ok}, 0, &rt.msgs)
	// The message carries the string, not a copy, so it is freed only once
	// update has run; freeing it here would hand the app a dangling slice.
	append(&rt.spent_asks, ask.url)
}
