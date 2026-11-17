#+build linux
// The user's locale is libc's, not Wayland's, so the reading of it lives in
// platform/xdg; init keeps the result in State and this hands it over.
package wayland

import "baldr:platform"

locale :: proc(b: ^platform.Backend) -> platform.Locale {
	return state(b).locale
}
