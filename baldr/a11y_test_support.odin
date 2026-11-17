package baldr

// The bridge's state is thread-local, and the test runner puts several
// tests on a thread. A test that leaves windows or remembered objects
// behind changes what the next one sees — which is how a flaky test is
// made. Every accessibility test starts and ends here instead.

// a11y_test_reset puts the bridge back to knowing nothing at all.
@(private)
a11y_test_reset :: proc() {
	a11y_watch_free(&a11y.watch)
	a11y_forget()
	a11y.windows = nil
	a11y.app_name = ""
	a11y.active_window = 0
	a11y.sweeping = false
	a11y.live = false // a test that watched what we say leaves none of that behind
	a11y.watcher = nil
	a11y.watch_user = nil
}

// a11y_test_watch makes the toolkit answer as if a reader were listening,
// with everything it decides to say appended to `out` instead of delivered.
//
// This is the seam the accessibility tests work at, and it is deliberately
// *above* the platform: what an app says and when is decided once, so these
// tests run on every target and a bridge is only answerable for turning a
// decision into its own protocol.
@(private)
a11y_test_watch :: proc(out: ^[dynamic]A11y_Said) {
	a11y.live = true // no connection anywhere: what we say stops at the watcher
	a11y.watcher = proc(user: rawptr, said: A11y_Said) {
		append((^[dynamic]A11y_Said)(user), said)
	}
	// A conversion, like the tree in a11y_test_window: the watcher holds
	// this until a11y_test_reset, which every test calls.
	a11y.watch_user = rawptr(out)
}

// a11y_test_window points the bridge at one tree, as the run loop does.
@(private)
a11y_test_window :: proc(t: ^Tree, title := "Notes", active := true) {
	a11y_test_reset()
	a11y.app_name = "Test App"
	a11y.windows = make([dynamic]A11y_Window, context.temp_allocator)
	// The tree is a test's own local, and the registry keeps it until
	// `a11y_test_reset`. The explicit conversion keeps the compiler's escape
	// analysis from warning at every call site and burying a real warning.
	append(&a11y.windows, A11y_Window{tree = (^Tree)(rawptr(t)), title = title, active = active})
}
