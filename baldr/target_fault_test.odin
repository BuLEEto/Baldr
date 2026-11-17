package baldr

// A window the GPU cannot present to: which refusals are worth another try,
// and what each one is called when it is written down.

@(require) import "core:strings"
@(require) import "core:testing"
@(require) import "baldr:gpu"

when ODIN_TEST || #config(BALDR_TESTS, false) {

// Only a full slot table clears itself, and a new fault must be classified
// on purpose rather than inherit "try again for ever".
@(test)
only_a_full_target_table_is_worth_asking_again :: proc(t: ^testing.T) {
	for f in gpu.Target_Fault {
		testing.expectf(t, target_retry(f) == (f == .Slots), "%v: asked again %v", f, target_retry(f))
	}
}

// Each refusal reads as its own sentence: a driver that cannot present must
// not read as a full slot table, which sends a reader looking for a leak.
@(test)
a_refused_target_says_which_kind_of_thing_went_wrong :: proc(t: ^testing.T) {
	r: gpu.Renderer
	said: [gpu.Target_Fault]string
	for f in gpu.Target_Fault {
		r.target_fault = f
		said[f] = target_why(&r)
		testing.expectf(t, said[f] != "", "%v: says something", f)
		for g in gpu.Target_Fault {
			if g == f do break
			testing.expectf(t, said[g] != said[f], "%v and %v both say %q", g, f, said[f])
		}
	}

	// The count belongs to the one fault it is about.
	testing.expect(t, strings.contains(said[.Slots], "64"), "a full table says how many")
	for f in gpu.Target_Fault {
		if f == .Slots do continue
		testing.expectf(t, !strings.contains(said[f], "in use"), "%v does not blame the table: %q", f, said[f])
	}
	testing.expect(t, strings.contains(said[.Surface], "present"), "a driver that cannot present says so")
}

// The renderer's side, as far as a headless test reaches: a refusal names a
// fault and nothing is left holding a slot. The paths that need a device (a
// surface with no formats, a lost one) need a real driver; a WSI failure
// cannot be faked.
@(test)
a_renderer_with_nothing_to_draw_into_says_so :: proc(t: ^testing.T) {
	r: gpu.Renderer
	defer gpu.destroy(&r)
	defer delete(r.last_error) // `fail` keeps its message; destroy does not take it

	testing.expect_value(t, gpu.target_fault(nil), gpu.Target_Fault.None)

	target, ok := gpu.target_add(&r, 0, {800, 600}, false)
	testing.expect(t, !ok && target == 0, "no drawable, no target")
	testing.expect_value(t, gpu.target_fault(&r), gpu.Target_Fault.Drawable)
	testing.expect(t, !target_retry(gpu.target_fault(&r)), "and not worth asking again")

	// Letting go of a drawable the renderer never took is safe before init,
	// which is what every headless test does with one.
	gpu.drawable_release(&r, 0)
	gpu.drawable_release(&r, gpu.Drawable(uintptr(0x1234)))
}

}
