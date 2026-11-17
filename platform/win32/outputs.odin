#+build windows
package win32

// The screens, for `Backend.outputs` and `Ev_Outputs`.
//
// Windows has no single call for this, so it takes four:
// EnumDisplayMonitors for the monitors, GetMonitorInfoW for each one's
// rectangle in the desktop and its device name, GetDpiForMonitor for the
// scale (per-monitor, which is the whole point of per-monitor-v2
// awareness), and EnumDisplaySettingsW for the mode, the refresh rate and
// the rotation. EnumDisplayDevicesW then names the panel.
//
// `pos` is in device pixels: Windows lays the desktop out in physical
// pixels and has no logical desktop space, so `pos` cannot be logical the
// way Wayland's xdg-output `pos` is. `size` is still the screen's logical
// size (`mode_px` / `scale`). So on Windows a screen's desktop rectangle is
// `pos` + `mode_px`, on Wayland `pos` + `size`; they agree wherever every
// screen is at 100%.
//
// `refresh` is coarser here than on Wayland: Windows reports whole hertz,
// so a 59.94 Hz panel comes back as 59000 or 60000 mHz rather than 59940.
// `primary` is not set — the toolkit decides which screen is first.

import win "core:sys/windows"
import "baldr:platform"

@(private = "file") MAX_SCREENS :: 32

// Rotation, from DEVMODEW.dmDisplayOrientation (wingdi.h). Windows rotates
// clockwise where Wayland's transform is counter-clockwise, so 90 and 270
// swap on the way across.
@(private = "file") DMDO_DEFAULT :: 0
@(private = "file") DMDO_90      :: 1
@(private = "file") DMDO_180     :: 2
@(private = "file") DMDO_270     :: 3

@(private = "file") MONITORINFOF_PRIMARY :: 0x00000001

// outputs is the screens as last read. Owned by the backend, valid until
// the next Ev_Outputs.
@(private)
outputs :: proc(b: ^platform.Backend) -> []platform.Output {
	return data(b).screens[:]
}

// Mon_List collects the handles during the enumeration. The callback is a
// "system" proc with no Odin context, so it does nothing but fill an array
// the caller owns; everything that allocates happens afterwards.
@(private = "file")
Mon_List :: struct {
	n: int,
	h: [MAX_SCREENS]win.HMONITOR,
}

@(private = "file")
collect_monitor :: proc "system" (h: win.HMONITOR, hdc: win.HDC, r: win.LPRECT, lp: win.LPARAM) -> win.BOOL {
	l := (^Mon_List)(uintptr(lp))
	if l.n < MAX_SCREENS {
		l.h[l.n] = h
		l.n += 1
	}
	return true
}

// outputs_refresh re-reads the screens, and says whether anything about
// them changed — so a WM_DISPLAYCHANGE that alters nothing we report (a
// colour-depth change) does not wake the app with an Ev_Outputs.
@(private)
outputs_refresh :: proc(w: ^Win32) -> (changed: bool) {
	list: Mon_List
	win.EnumDisplayMonitors(nil, nil, collect_monitor, win.LPARAM(uintptr(&list)))

	next := make([dynamic]platform.Output, 0, list.n, w.allocator)
	for i in 0 ..< list.n {
		mi: win.MONITORINFOEXW
		mi.cbSize = size_of(mi)
		if !win.GetMonitorInfoW(list.h[i], (win.LPMONITORINFO)(&mi)) do continue

		o := platform.Output{
			pos     = {mi.rcMonitor.left, mi.rcMonitor.top},
			mode_px = {mi.rcMonitor.right - mi.rcMonitor.left, mi.rcMonitor.bottom - mi.rcMonitor.top},
			scale   = 1,
		}

		dx, dy: win.UINT = 96, 96
		if win.GetDpiForMonitor(list.h[i], .MDT_EFFECTIVE_DPI, &dx, &dy) == 0 && dx > 0 {
			o.scale = f32(dx) / 96
		}

		// The mode is the authority on size, rate and rotation; rcMonitor is
		// the fallback, and is already set above.
		dm: win.DEVMODEW
		dm.dmSize = size_of(dm)
		if win.EnumDisplaySettingsW(cstring16(raw_data(mi.szDevice[:])), win.ENUM_CURRENT_SETTINGS, &dm) {
			if dm.dmPelsWidth > 0 && dm.dmPelsHeight > 0 {
				o.mode_px = {i32(dm.dmPelsWidth), i32(dm.dmPelsHeight)}
			}
			o.refresh = i32(dm.dmDisplayFrequency) * 1000 // whole hertz is all Windows keeps
			switch dm.dmDisplayOrientation {
			case DMDO_90:  o.transform = .Rotate_270 // Windows turns it clockwise, Wayland counter-
			case DMDO_180: o.transform = .Rotate_180
			case DMDO_270: o.transform = .Rotate_90
			case DMDO_DEFAULT: o.transform = .Normal
			}
		}

		o.size = {i32(f32(o.mode_px.x) / o.scale), i32(f32(o.mode_px.y) / o.scale)}
		o.name = wide_to_string(mi.szDevice[:], w.allocator)          // `\\.\DISPLAY1`
		o.description = panel_name(mi.szDevice[:], w.allocator)        // the panel's own name
		append(&next, o)
	}

	changed = !outputs_same(w.screens[:], next[:])
	if !changed {
		outputs_free(next[:], w.allocator)
		delete(next)
		return
	}
	outputs_free(w.screens[:], w.allocator)
	delete(w.screens)
	w.screens = next
	return
}

// panel_name asks the display device for the monitor attached to it —
// "Generic PnP Monitor" on a machine with no vendor driver, the model where
// there is one. Empty rather than wrong when nothing answers.
@(private = "file")
panel_name :: proc(device: []win.WCHAR, allocator := context.allocator) -> string {
	dd: win.DISPLAY_DEVICEW
	dd.cb = size_of(dd)
	if !win.EnumDisplayDevicesW(cstring16(raw_data(device)), 0, &dd, 0) do return ""
	return wide_to_string(dd.DeviceString[:], allocator)
}

// wide_to_string reads a NUL-terminated string out of a fixed WCHAR array.
@(private = "file")
wide_to_string :: proc(w: []win.WCHAR, allocator := context.allocator) -> string {
	n := 0
	for n < len(w) && w[n] != 0 do n += 1
	if n == 0 do return ""
	s, err := win.utf16_to_utf8(w[:n], allocator)
	return s if err == nil else ""
}

// outputs_same compares only what the toolkit reports, so a change nobody
// can see does not become an event.
@(private = "file")
outputs_same :: proc(a, b: []platform.Output) -> bool {
	if len(a) != len(b) do return false
	for x, i in a {
		y := b[i]
		if x.name != y.name || x.description != y.description do return false
		if x.pos != y.pos || x.size != y.size || x.mode_px != y.mode_px do return false
		if x.scale != y.scale || x.transform != y.transform || x.refresh != y.refresh do return false
	}
	return true
}

@(private = "file")
outputs_free :: proc(list: []platform.Output, allocator := context.allocator) {
	for o in list {
		delete(o.name, allocator)
		delete(o.description, allocator)
	}
}

// outputs_shutdown drops the list.
@(private)
outputs_shutdown :: proc(w: ^Win32) {
	outputs_free(w.screens[:], w.allocator)
	delete(w.screens)
	w.screens = nil
}

