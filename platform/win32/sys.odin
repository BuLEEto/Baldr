#+build windows
package win32

// sys.odin — Win32 procs and types that core:sys/windows lacks, declared
// against the same import libraries core already links (User32, Dwmapi).
// Nothing here adds a dependency; all are upstream-PR candidates.

import win "core:sys/windows"

foreign import user32 "system:User32.lib"
foreign import dwmapi "system:Dwmapi.lib"

@(default_calling_convention="system")
foreign user32 {
	MsgWaitForMultipleObjectsEx         :: proc(nCount: win.DWORD, pHandles: [^]win.HANDLE, dwMilliseconds: win.DWORD, dwWakeMask: win.DWORD, dwFlags: win.DWORD) -> win.DWORD ---
	GetAwarenessFromDpiAwarenessContext :: proc(value: win.DPI_AWARENESS_CONTEXT) -> Dpi_Awareness ---
	AreDpiAwarenessContextsEqual        :: proc(a, b: win.DPI_AWARENESS_CONTEXT) -> win.BOOL ---
	GetCursor                           :: proc() -> win.HCURSOR ---
	// The time the message being handled was posted, in milliseconds. A
	// double-click has to be timed by when the person clicked, not by when
	// this process got round to a frame, so every pointer event carries it.
	GetMessageTime                      :: proc() -> win.LONG ---
	// What Windows calls a key, for `Backend.key_name`. Not in
	// core:sys/windows, and there is no unlocalised form of it.
	GetKeyNameTextW                     :: proc(lParam: win.LONG, lpString: [^]win.WCHAR, cchSize: win.c_int) -> win.c_int ---
	// The caret's half-period in ms (Settings > Accessibility > Text
	// cursor), INFINITE when it does not blink, 0 on failure.
	GetCaretBlinkTime                   :: proc() -> win.UINT ---
}

// SPI_GETCARETTIMEOUT is how long the caret blinks with no input before it
// stops, in ms (Windows 10 and later; a DWORD).
SPI_GETCARETTIMEOUT :: 0x2022

@(default_calling_convention="system")
foreign dwmapi {
	DwmGetColorizationColor       :: proc(pcrColorization: ^win.DWORD, pfOpaqueBlend: ^win.BOOL) -> win.HRESULT ---
	DwmGetCompositionTimingInfo   :: proc(hwnd: win.HWND, pTimingInfo: ^DWM_TIMING_INFO) -> win.HRESULT ---
}

// DWM_TIMING_INFO (dwmapi.h) is the frame clock on Windows: when the last
// vblank was and how long a refresh lasts, both measured (frames.odin).
//
// Only the head of it is named. `cbSize` must be the size of the *whole*
// struct or the call answers E_INVALIDARG, so the tail is padding and the
// assert below is what keeps it honest: the real struct is 320 bytes, and
// the named fields sit at 0, 4, 16, 24, 32 and 40.
DWM_TIMING_INFO :: struct {
	cbSize:           u32,
	rateRefresh:      UNSIGNED_RATIO, // the monitor's nominal rate
	qpcRefreshPeriod: u64,            // one refresh, in QPC ticks (measured)
	rateCompose:      UNSIGNED_RATIO,
	qpcVBlank:        u64,            // the last vblank, in QPC ticks
	cRefresh:         u64,            // a running count of refreshes: it advancing is the tick
	_:                [320 - 48]u8,   // the rest, which nothing here reads
}
#assert(size_of(DWM_TIMING_INFO) == 320)

UNSIGNED_RATIO :: struct { uiNumerator, uiDenominator: u32 }

// FILE_NOTIFY_INFORMATION, declared here rather than used from
// core:sys/windows because core has spelled its fields both
// `next_entry_offset` and `NextEntryOffset` across nightlies; this one
// compiles against either. The layout is all the call cares about.
FILE_NOTIFY_INFO :: struct {
	next_entry_offset: win.DWORD, // 0 ends the chain
	action:            win.DWORD, // FILE_ACTION_*
	file_name_length:  win.DWORD, // bytes, not characters
	file_name:         [1]win.WCHAR,
}

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention="system")
foreign kernel32 {
	GetUserDefaultLocaleName :: proc(lpLocaleName: win.LPWSTR, cchLocaleName: win.INT) -> win.INT ---
	GlobalSize :: proc(hMem: win.HGLOBAL) -> win.SIZE_T ---
}

// global_text reads the UTF-16 text in clipboard memory, up to its NUL and
// never past the block: another program wrote it, and text with no NUL at
// its end would otherwise be read on into whatever follows.
@(private)
global_text :: proc(h: win.HANDLE, allocator := context.allocator) -> (string, bool) {
	p := win.GlobalLock(win.HGLOBAL(h))
	if p == nil do return "", false
	defer win.GlobalUnlock(win.HGLOBAL(h))
	units := ([^]u16)(p)[:int(GlobalSize(win.HGLOBAL(h))) / size_of(u16)]
	n := 0
	for n < len(units) && units[n] != 0 do n += 1
	s, err := win.utf16_to_utf8(units[:n], allocator)
	return s, err == nil
}

// LCTYPEs for GetLocaleInfoEx (winnls.h); core:sys/windows declares the call
// but none of the constants. The day and month runs are consecutive, so only
// the first of each is named.
LOCALE_SSHORTDATE        :: win.LCTYPE(0x0000001F)
LOCALE_ITIME             :: win.LCTYPE(0x00000023) // "0" = 12-hour with AM/PM, "1" = 24-hour
LOCALE_S1159             :: win.LCTYPE(0x00000028) // AM
LOCALE_S2359             :: win.LCTYPE(0x00000029) // PM
LOCALE_SDAYNAME1         :: win.LCTYPE(0x0000002A) // Monday — not Sunday, unlike the toolkit's order
LOCALE_SABBREVDAYNAME1   :: win.LCTYPE(0x00000031)
LOCALE_SMONTHNAME1       :: win.LCTYPE(0x00000038)
LOCALE_SABBREVMONTHNAME1 :: win.LCTYPE(0x00000044)
LOCALE_SDECIMAL          :: win.LCTYPE(0x0000000E)
LOCALE_STHOUSAND         :: win.LCTYPE(0x0000000F)
LOCALE_IFIRSTDAYOFWEEK   :: win.LCTYPE(0x0000100C) // 0 = Monday … 6 = Sunday

MWMO_INPUTAVAILABLE :: 0x0004

Dpi_Awareness :: enum i32 { INVALID = -1, UNAWARE = 0, SYSTEM_AWARE = 1, PER_MONITOR_AWARE = 2 }

// SystemParametersInfoW(SPI_GETHIGHCONTRAST) payload.
HIGHCONTRASTW :: struct {
	cbSize:            win.UINT,
	dwFlags:           win.DWORD,
	lpszDefaultScheme: win.LPWSTR,
}
HCF_HIGHCONTRASTON :: 0x00000001
