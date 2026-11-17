#+build windows
package win32

// The desktop's own open and save dialog on Windows: the common item
// dialog — not the old GetOpenFileName box — through COM, which
// core:sys/windows already declares.
//
// The dialog runs its own message loop, so the app's window would stand
// unpainted behind it: a timer keeps it drawing through
// Backend.redraw_callback, the same way the size / move loop does.

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import win "core:sys/windows"
import "baldr:platform"

// CANCELLED is HRESULT_FROM_WIN32(ERROR_CANCELLED): the person closed the
// dialog, which is an answer, not a fault.
@(private) CANCELLED :: u32(0x800704C7)

@(private) DIALOG_TIMER  :: win.UINT_PTR(0x0D1A) // the paint tick while the dialog is up
@(private) DIALOG_TICK_MS :: win.UINT(16)

// file_dialog shows the open or save dialog for `d` and queues one
// Ev_Files with its token (Backend.file_dialog). It returns once the person
// has chosen or cancelled: a Windows file dialog is modal, as every app
// there has it.
@(private)
file_dialog :: proc(b: ^platform.Backend, d: platform.File_Dialog) -> bool {
	w := (^Win32)(b.data)
	if !w.ole_started { // OLE is what the dialog lives in; drops start it too
		if win.FAILED(OleInitialize(nil)) do return false
		w.ole_started = true
	}
	dialog: ^win.IFileDialog
	clsid := win.CLSID_FileSaveDialog if d.save else win.CLSID_FileOpenDialog
	iid := win.IID_IFileSaveDialog if d.save else win.IID_IFileOpenDialog
	if win.FAILED(win.CoCreateInstance(clsid, nil, win.CLSCTX_INPROC_SERVER, iid, cast(^rawptr)&dialog)) do return false
	defer dialog->Release()

	options: win.FILEOPENDIALOGOPTIONS
	dialog->GetOptions(&options)
	options |= win.FOS_FORCEFILESYSTEM // a file on disk, not a photo inside a phone
	if d.directory do options |= win.FOS_PICKFOLDERS
	if d.multiple && !d.save do options |= win.FOS_ALLOWMULTISELECT
	dialog->SetOptions(options)

	if d.title != "" do dialog->SetTitle(win.utf8_to_wstring(d.title, context.temp_allocator))
	if d.accept_label != "" do dialog->SetOkButtonLabel(win.utf8_to_wstring(d.accept_label, context.temp_allocator))
	if d.current_name != "" do dialog->SetFileName(win.utf8_to_wstring(d.current_name, context.temp_allocator))
	if d.current_folder != "" {
		folder: ^win.IShellItem
		win_path, _ := strings.replace_all(d.current_folder, "/", "\\", context.temp_allocator)
		path := win.utf8_to_wstring(win_path, context.temp_allocator)
		if win.SUCCEEDED(win.SHCreateItemFromParsingName(path, nil, win.IID_IShellItem, cast(^rawptr)&folder)) && folder != nil {
			dialog->SetFolder(folder)
			folder->Release()
		}
	}
	specs := filter_specs(d.filters, context.temp_allocator)
	if len(specs) > 0 do dialog->SetFileTypes(win.UINT(len(specs)), raw_data(specs))

	owner := dialog_owner(w)
	if owner != nil do win.SetTimer(owner, DIALOG_TIMER, DIALOG_TICK_MS, nil) // keep the window painting behind it
	hr := dialog->Show(owner)
	if owner != nil do win.KillTimer(owner, DIALOG_TIMER)
	if win.FAILED(hr) { // cancelled, or it would not open: both are "no files", and only one is a person's choice
		cancelled := u32(hr) == CANCELLED
		if !cancelled do fmt.eprintfln("baldr/win32: the file dialog would not open (0x%x)", u32(hr))
		append(&w.queue, platform.Ev_Files{token = d.token, ok = false, why = .Cancelled if cancelled else .Not_Shown})
		return true
	}
	paths := dialog_paths(w, dialog, d.save && !d.multiple)
	if len(paths) == 0 { // not cancelled, so something was chosen and reading it failed
		fmt.eprintfln("baldr/win32: the file dialog was accepted but gave no path (save=%v, multiple=%v, directory=%v)", d.save, d.multiple, d.directory)
	}
	append(&w.queue, platform.Ev_Files{token = d.token, paths = paths, ok = len(paths) > 0, why = .Chosen if len(paths) > 0 else .Unusable})
	return true
}

// dialog_owner is the window the dialog belongs to: the one with the
// keyboard, else the first open. Nil is allowed, and makes it its own.
@(private)
dialog_owner :: proc(w: ^Win32) -> win.HWND {
	for s in w.surfaces do if s != nil && s.hwnd != nil && s.focused do return s.hwnd
	for s in w.surfaces do if s != nil && s.hwnd != nil do return s.hwnd
	return nil
}

// dialog_paths reads what was chosen. The strings and the slice live in the
// arena the pump hands back, as every event's do.
@(private)
dialog_paths :: proc(w: ^Win32, dialog: ^win.IFileDialog, single: bool) -> []string {
	out := make([dynamic]string, 0, 4, virtual.arena_allocator(&w.text))
	if !single {
		open := cast(^win.IFileOpenDialog)dialog
		items: ^win.IShellItemArray
		hr := open->GetResults(&items)
		if win.FAILED(hr) do fmt.eprintfln("baldr/win32: the dialog's GetResults failed (0x%x)", u32(hr))
		if win.SUCCEEDED(hr) && items != nil {
			defer items->Release()
			count: win.DWORD
			items->GetCount(&count)
			for i in 0 ..< count {
				item: ^win.IShellItem
				if win.FAILED(items->GetItemAt(i, &item)) || item == nil do continue
				defer item->Release()
				if p, ok := item_path(w, item); ok do append(&out, p)
			}
			return out[:]
		}
	}
	item: ^win.IShellItem
	hr2 := dialog->GetResult(&item)
	if win.FAILED(hr2) do fmt.eprintfln("baldr/win32: the dialog's GetResult failed (0x%x)", u32(hr2))
	if win.SUCCEEDED(hr2) && item != nil {
		defer item->Release()
		if p, ok := item_path(w, item); ok do append(&out, p)
	}
	return out[:]
}

// item_path is one chosen item's path on disk.
@(private)
item_path :: proc(w: ^Win32, item: ^win.IShellItem) -> (string, bool) {
	wide: win.LPWSTR
	hr := item->GetDisplayName(.FILESYSPATH, &wide)
	if win.FAILED(hr) || wide == nil {
		fmt.eprintfln("baldr/win32: the chosen item has no path on disk (0x%x)", u32(hr))
		return "", false
	}
	defer win.CoTaskMemFree(wide)
	s, err := win.wstring_to_utf8(win.wstring(wide), -1, virtual.arena_allocator(&w.text))
	if err != nil do fmt.eprintfln("baldr/win32: the chosen path would not read as UTF-8 (%v)", err)
	return s, err == nil
}

// filter_specs turns the toolkit's filters into the dialog's: one line each,
// its patterns joined with semicolons. A MIME-type filter has no place in a
// Windows dialog, so it is passed over — an app that gives only those gets
// the dialog's own "all files".
@(private)
filter_specs :: proc(filters: []platform.File_Filter, allocator: mem.Allocator) -> []win.COMDLG_FILTERSPEC {
	out := make([dynamic]win.COMDLG_FILTERSPEC, 0, len(filters), allocator)
	for f in filters {
		globs := make([dynamic]string, 0, len(f.patterns), context.temp_allocator)
		for p in f.patterns {
			if f.mime || strings.index_byte(p, '/') >= 0 do continue // "image/png" is not a pattern Windows knows
			append(&globs, p)
		}
		if len(globs) == 0 do continue
		spec := strings.join(globs[:], ";", context.temp_allocator)
		append(&out, win.COMDLG_FILTERSPEC{
			pszName = win.utf8_to_wstring(f.name if f.name != "" else spec, allocator),
			pszSpec = win.utf8_to_wstring(spec, allocator),
		})
	}
	return out[:]
}
