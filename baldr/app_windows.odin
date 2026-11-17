#+build windows
package baldr

import "baldr:platform"
import "baldr:platform/win32"

default_backend :: proc() -> ^platform.Backend {
	return win32.backend()
}
