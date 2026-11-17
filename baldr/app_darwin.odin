package baldr

import "baldr:platform"
import "baldr:platform/cocoa"

// default_backend is the Cocoa backend (platform/cocoa): an NSApplication, a
// window per surface, and the event pump translated into platform.Event. The
// renderer it feeds is Metal (gpu/metal.odin), not MoltenVK: the dependency
// rule allows `vendor:darwin/*` and no C compiled into the tree, and Metal is
// what the platform itself ships.
default_backend :: proc() -> ^platform.Backend {
	return cocoa.backend()
}
