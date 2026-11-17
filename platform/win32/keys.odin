#+build windows
package win32

// keys.odin — Win32 virtual-key → platform.Key. The VK is the "physical-ish"
// key on Windows (letters/digits follow the layout's engraving, punctuation
// is positional via VK_OEM_*), which is the same compromise the other
// backends make. `extended` is the KF_EXTENDED bit: it separates the
// navigation cluster (extended) from the numpad (not extended) for the VKs
// Windows shares between them, and Enter from KP_Enter.

import win "core:sys/windows"
import "baldr:platform"

vk_to_key :: proc(vk: u32, extended: bool) -> platform.Key {
	K :: platform.Key
	switch vk {
	case 'A' ..= 'Z':                       return K(int(K.A) + int(vk - 'A'))
	case '0' ..= '9':                       return K(int(K.N0) + int(vk - '0'))
	case win.VK_F1 ..= win.VK_F24:          return K(int(K.F1) + int(vk - win.VK_F1))
	case win.VK_NUMPAD0 ..= win.VK_NUMPAD9: return K(int(K.KP_0) + int(vk - win.VK_NUMPAD0))

	case win.VK_ESCAPE: return .Escape
	case win.VK_RETURN: return .KP_Enter if extended else .Enter
	case win.VK_TAB:    return .Tab
	case win.VK_BACK:   return .Backspace
	case win.VK_SPACE:  return .Space

	// Shared VKs: the navigation cluster has the extended bit, the numpad
	// (Num Lock off) does not.
	case win.VK_LEFT:   return .Left      if extended else .KP_4
	case win.VK_RIGHT:  return .Right     if extended else .KP_6
	case win.VK_UP:     return .Up        if extended else .KP_8
	case win.VK_DOWN:   return .Down      if extended else .KP_2
	case win.VK_HOME:   return .Home      if extended else .KP_7
	case win.VK_END:    return .End       if extended else .KP_1
	case win.VK_PRIOR:  return .Page_Up   if extended else .KP_9
	case win.VK_NEXT:   return .Page_Down if extended else .KP_3
	case win.VK_INSERT: return .Insert    if extended else .KP_0
	case win.VK_DELETE: return .Delete    if extended else .KP_Decimal
	case win.VK_CLEAR:  return .KP_5

	case win.VK_LSHIFT:   return .Shift_L
	case win.VK_RSHIFT:   return .Shift_R
	case win.VK_LCONTROL: return .Ctrl_L
	case win.VK_RCONTROL: return .Ctrl_R
	case win.VK_LMENU:    return .Alt_L
	case win.VK_RMENU:    return .Alt_R
	case win.VK_LWIN:     return .Super_L
	case win.VK_RWIN:     return .Super_R

	case win.VK_CAPITAL:  return .Caps_Lock
	case win.VK_NUMLOCK:  return .Num_Lock
	case win.VK_SCROLL:   return .Scroll_Lock
	case win.VK_SNAPSHOT: return .Print
	case win.VK_PAUSE:    return .Pause
	case win.VK_APPS:     return .Menu

	case win.VK_OEM_MINUS:  return .Minus
	case win.VK_OEM_PLUS:   return .Equal
	case win.VK_OEM_4:      return .Bracket_L
	case win.VK_OEM_6:      return .Bracket_R
	case win.VK_OEM_5:      return .Backslash
	case win.VK_OEM_1:      return .Semicolon
	case win.VK_OEM_7:      return .Apostrophe
	case win.VK_OEM_3:      return .Grave
	case win.VK_OEM_COMMA:  return .Comma
	case win.VK_OEM_PERIOD: return .Period
	case win.VK_OEM_2:      return .Slash

	case win.VK_DECIMAL:       return .KP_Decimal
	case win.VK_DIVIDE:        return .KP_Divide
	case win.VK_MULTIPLY:      return .KP_Multiply
	case win.VK_SUBTRACT:      return .KP_Subtract
	case win.VK_ADD:           return .KP_Add
	case win.VK_OEM_NEC_EQUAL: return .KP_Equal
	}
	return .Unknown
}
