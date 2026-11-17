package platform

// cursor_theme_names is the name a cursor theme gives `c`, and the older X
// name to try when a theme lacks it ("xterm" for "text"). They are the
// freedesktop cursor-spec names, which are also the names Wayland's
// cursor-shape protocol uses, so every backend that reads a theme — X11
// through libxcb-cursor, Wayland through libwayland-cursor where the
// compositor has no cursor-shape protocol — asks for the same shape by the
// same name. Hidden has none: a backend hides the pointer instead.
cursor_theme_names :: proc "contextless" (c: Cursor) -> [2]string {
	switch c {
	case .Default:     return {"default", "left_ptr"}
	case .Pointer:     return {"pointer", "hand2"}
	case .Text:        return {"text", "xterm"}
	case .Crosshair:   return {"crosshair", "cross"}
	case .Move:        return {"move", "fleur"}
	case .Not_Allowed: return {"not-allowed", "crossed_circle"}
	case .Grab:        return {"grab", "openhand"}
	case .Grabbing:    return {"grabbing", "closedhand"}
	case .Resize_NS:   return {"ns-resize", "sb_v_double_arrow"}
	case .Resize_EW:   return {"ew-resize", "sb_h_double_arrow"}
	case .Resize_NESW: return {"nesw-resize", "fd_double_arrow"}
	case .Resize_NWSE: return {"nwse-resize", "bd_double_arrow"}
	case .Wait:        return {"wait", "watch"}
	case .Progress:    return {"progress", "left_ptr_watch"}
	case .Help:        return {"help", "question_arrow"}
	case .Hidden:      return {"", ""} // handled by hiding, not by a theme name
	case .Picture:     return {"default", "left_ptr"} // a drawn cursor is its own path
	}
	return {"default", "left_ptr"}
}
