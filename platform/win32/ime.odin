#+build windows
package win32

// Input methods on Windows, through IMM32.
//
// IMM32 rather than TSF: TSF is an order of magnitude more code (a COM text
// store serving the document, its selection and layout back), while IMM32
// carries every CJK input method Windows ships, hands the composition over
// as a plain string, and maps almost one-to-one onto `Ev_Ime`. TSF would
// add only the finer reconversion features, which nothing asks for.
//
// The toolkit draws the preedit, not Windows: `WM_IME_SETCONTEXT` has the
// `ISC_SHOWUICOMPOSITIONWINDOW` bit taken out so the OS draws no composition
// string over ours, and the composition messages are swallowed. The OS is
// told where the caret is, so the candidate list appears beside the text
// being typed.

import "core:mem/virtual"
import win "core:sys/windows"
import "baldr:platform"

foreign import imm32 "system:Imm32.lib"

@(default_calling_convention = "system")
foreign imm32 {
	ImmGetContext           :: proc(hwnd: win.HWND) -> HIMC ---
	ImmReleaseContext       :: proc(hwnd: win.HWND, himc: HIMC) -> win.BOOL ---
	ImmGetCompositionStringW :: proc(himc: HIMC, index: win.DWORD, buf: rawptr, len: win.DWORD) -> win.LONG ---
	ImmSetCompositionWindow :: proc(himc: HIMC, form: ^COMPOSITIONFORM) -> win.BOOL ---
	ImmSetCandidateWindow   :: proc(himc: HIMC, form: ^CANDIDATEFORM) -> win.BOOL ---
	ImmAssociateContextEx   :: proc(hwnd: win.HWND, himc: HIMC, flags: win.DWORD) -> win.BOOL ---
	ImmNotifyIME            :: proc(himc: HIMC, action, index, value: win.DWORD) -> win.BOOL ---
}

@(private) HIMC :: distinct rawptr

@(private)
COMPOSITIONFORM :: struct {
	dwStyle:      win.DWORD,
	ptCurrentPos: win.POINT,
	rcArea:       win.RECT,
}

@(private)
CANDIDATEFORM :: struct {
	dwIndex:      win.DWORD,
	dwStyle:      win.DWORD,
	ptCurrentPos: win.POINT,
	rcArea:       win.RECT,
}

@(private) CFS_POINT       :: win.DWORD(0x0002)
@(private) CFS_EXCLUDE     :: win.DWORD(0x0080)
@(private) GCS_COMPSTR     :: win.DWORD(0x0008)
@(private) GCS_CURSORPOS   :: win.DWORD(0x0080)
@(private) GCS_RESULTSTR   :: win.DWORD(0x0800)
@(private) IACE_DEFAULT    :: win.DWORD(0x0010)
@(private) ISC_SHOWUICOMPOSITIONWINDOW :: 0x8000_0000
@(private) NI_COMPOSITIONSTR :: win.DWORD(0x0015)
@(private) CPS_CANCEL        :: win.DWORD(0x0004)

// ime_set is Backend.ime_set: which field has the keyboard, what it is for,
// and where its caret is.
@(private)
ime_set :: proc(b: ^platform.Backend, st: platform.Ime_State) {
	w := data(b)
	s := get_surface(w, st.surface)
	if s == nil || s.hwnd == nil do return

	// A password field composes nothing: an input method that kept a
	// candidate list for it would show what was being typed, which is the
	// one thing a password field exists to prevent.
	on := st.on && st.purpose != .Password && .Sensitive_Data not_in st.hints && .Hidden_Text not_in st.hints
	if s.ime_on != on {
		s.ime_on = on
		// Associating the default context turns composing back on;
		// associating nothing turns it off, which is how IMM32 says it.
		ImmAssociateContextEx(s.hwnd, nil, IACE_DEFAULT if on else 0)
		debugf(w, "ime: %s for surface %d", "on" if on else "off", st.surface)
	}
	if !on do return

	// Where the candidate window should sit: beside the caret, not over it.
	// IMM32 counts in device pixels; the caret arrives in logical pixels.
	himc := ImmGetContext(s.hwnd)
	if himc == nil do return
	defer ImmReleaseContext(s.hwnd, himc)
	scale := scale_of(s)
	x, y := i32(st.caret.x * scale), i32(st.caret.y * scale)
	h := i32(max(st.caret.w, 1) * scale)
	cf := COMPOSITIONFORM{dwStyle = CFS_POINT, ptCurrentPos = {x, y + h}}
	ImmSetCompositionWindow(himc, &cf)
	// CFS_EXCLUDE keeps the list off the caret's own line, so it does not
	// cover the text being composed.
	cand := CANDIDATEFORM{
		dwIndex = 0, dwStyle = CFS_EXCLUDE,
		ptCurrentPos = {x, y + h},
		rcArea = {x, y, x + i32(max(st.caret.z, 1) * scale), y + h},
	}
	ImmSetCandidateWindow(himc, &cand)
}

// ime_message handles the composition messages. True when the message was
// ours and must not go on to DefWindowProcW, which would have Windows draw
// its own preedit over the one the app is drawing.
@(private)
ime_message :: proc(s: ^Surface, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> (handled: bool, result: win.LRESULT) {
	w := s.w
	switch msg {
	case win.WM_IME_STARTCOMPOSITION:
		// Swallowed: the app draws the preedit, so the OS must not open its
		// composition window at all.
		return true, 0

	case win.WM_IME_COMPOSITION:
		himc := ImmGetContext(s.hwnd)
		if himc == nil do return true, 0
		defer ImmReleaseContext(s.hwnd, himc)
		ev := platform.Ev_Ime{surface = s.id, cursor_begin = -1, cursor_end = -1}
		// The committed text first: that is what the person settled on, and
		// it is inserted as if typed.
		if win.DWORD(lparam) & GCS_RESULTSTR != 0 {
			ev.commit = ime_string(w, himc, GCS_RESULTSTR)
		}
		// …then whatever is still being composed, shown at the caret.
		if win.DWORD(lparam) & GCS_COMPSTR != 0 {
			ev.preedit = ime_string(w, himc, GCS_COMPSTR)
			// The caret inside the preedit, in bytes of the UTF-8 the
			// toolkit works in, which is not where IMM32 counts it: it
			// answers in UTF-16 code units.
			units := ImmGetCompositionStringW(himc, GCS_CURSORPOS, nil, 0)
			if units >= 0 {
				at := ime_utf8_offset(ev.preedit, int(units))
				ev.cursor_begin, ev.cursor_end = i32(at), i32(at)
			}
		}
		if len(ev.commit) > 0 || len(ev.preedit) > 0 || win.DWORD(lparam) & GCS_COMPSTR != 0 {
			append(&w.queue, ev)
		}
		return true, 0

	case win.WM_IME_ENDCOMPOSITION:
		// Nothing left being composed: the preedit the app is showing has to
		// go, or an abandoned composition stays on screen for ever.
		append(&w.queue, platform.Ev_Ime{surface = s.id, cursor_begin = -1, cursor_end = -1})
		return true, 0

	case win.WM_IME_SETCONTEXT:
		// The message does real work and must reach DefWindowProcW — but
		// with the bit that asks Windows to draw the composition string
		// taken out of it, or the OS draws its preedit over the app's.
		masked := lparam & ~win.LPARAM(ISC_SHOWUICOMPOSITIONWINDOW)
		return true, win.DefWindowProcW(s.hwnd, msg, wparam, masked)

	case win.WM_IME_CHAR:
		// The committed text already came through GCS_RESULTSTR; letting
		// this through as well would type everything twice.
		return true, 0
	}
	return false, 0
}

// ime_cancel drops a composition in flight, for a field losing the keyboard.
@(private)
ime_cancel :: proc(s: ^Surface) {
	if s == nil || s.hwnd == nil || !s.ime_on do return
	himc := ImmGetContext(s.hwnd)
	if himc == nil do return
	defer ImmReleaseContext(s.hwnd, himc)
	ImmNotifyIME(himc, NI_COMPOSITIONSTR, CPS_CANCEL, 0)
}

// ime_string reads one of the composition strings as UTF-8, in the arena
// event strings live in.
@(private)
ime_string :: proc(w: ^Win32, himc: HIMC, which: win.DWORD) -> string {
	n := ImmGetCompositionStringW(himc, which, nil, 0)
	if n <= 0 do return ""
	buf := make([]u16, int(n) / size_of(u16), context.temp_allocator)
	if len(buf) == 0 do return ""
	if ImmGetCompositionStringW(himc, which, raw_data(buf), win.DWORD(n)) <= 0 do return ""
	out, err := win.utf16_to_utf8(buf, virtual.arena_allocator(&w.text))
	return out if err == nil else ""
}

// ime_utf8_offset turns a UTF-16 code-unit offset into a byte offset in the
// UTF-8 that was decoded from it. IMM32 counts the caret in code units and
// `Ev_Ime` counts in bytes, and for anything outside ASCII the two differ.
@(private)
ime_utf8_offset :: proc(s: string, units: int) -> int {
	if units <= 0 do return 0
	seen, i := 0, 0
	for i < len(s) {
		if seen >= units do return i
		c := s[i]
		size := 1
		switch {
		case c >= 0xF0: size = 4
		case c >= 0xE0: size = 3
		case c >= 0xC0: size = 2
		}
		seen += 2 if size == 4 else 1 // a 4-byte rune is a surrogate pair
		i += size
	}
	return len(s)
}
