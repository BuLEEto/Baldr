package baldr

@(require) import "core:testing"
@(require) import "baldr:platform"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// An app's appearance setting has three choices (Light, Dark, System):
// `set_theme` pins a theme and `follow_system_theme` un-pins it, so System
// takes effect without a restart.

@(private = "file")
Ft_Msg :: union { int }

// ft_tree is a tree the run loop has told what the desktop's theme is, and
// what the app's last word on any theme is: a type scale of its own.
@(private = "file")
ft_tree :: proc(t: ^Tree, desktop: Theme, adjust: proc(th: ^Theme) = nil) {
	tree_init(t)
	t.adjust_theme = adjust
	tree_desktop_theme(t, desktop, desktop)
	tree_theme(t, desktop)
}

@(private = "file")
bigger_titles :: proc(th: ^Theme) { th.type.title.size = 99 }

// Light, Dark, System, back and forth.
@(test)
a_tree_can_follow_the_desktop_again_after_a_set_theme :: proc(t: ^testing.T) {
	tr: Tree
	dark := theme_dark()
	ft_tree(&tr, dark)
	defer tree_destroy(&tr)
	testing.expect(t, !tr.theme_app, "it starts following")
	testing.expect_value(t, tr.theme.name, dark.name)

	// Someone picks Light in the app's settings.
	set_theme(&tr, theme_light())
	testing.expect(t, tr.theme_app, "pinned")
	testing.expect_value(t, tr.theme.name, theme_light().name)

	// The desktop goes light and dark meanwhile; a pinned tree does not care.
	tree_desktop_theme(&tr, theme_dark(), theme_dark()) // as apply_theme does: finished and unadjusted together
	tree_theme(&tr, tr.theme_asked)
	testing.expect_value(t, tr.theme.name, theme_light().name)

	// …and System gives it back.
	follow_system_theme(&tr)
	testing.expect(t, !tr.theme_app, "following again")
	testing.expect_value(t, tr.theme.name, theme_dark().name)

	// The desktop's next change reaches it now.
	tree_desktop_theme(&tr, theme_light(), theme_light())
	if !tr.theme_app do tree_theme(&tr, tr.theme_desktop) // what apply_theme does
	testing.expect_value(t, tr.theme.name, theme_light().name)

	// And back to a pin, to show it is not one-way either.
	set_theme(&tr, theme_dark())
	testing.expect_value(t, tr.theme.name, theme_dark().name)
	follow_system_theme(&tr)
	testing.expect_value(t, tr.theme.name, theme_light().name)
}

// An app's own last word runs over a theme it set itself, not only over the
// ones the runtime hands it, so an app need not call its adjust proc by hand
// after each pick.
@(test)
a_set_theme_goes_through_the_apps_own_adjustment :: proc(t: ^testing.T) {
	tr: Tree
	ft_tree(&tr, theme_dark(), bigger_titles)
	defer tree_destroy(&tr)

	set_theme(&tr, theme_light())
	testing.expect_value(t, tr.theme.type.title.size, 99) // the app's scale survived the pick
	testing.expect_value(t, tr.theme.name, theme_light().name)

	// It is the app's word, not a copy of one theme: a second pick gets it too.
	set_theme(&tr, theme_dark())
	testing.expect_value(t, tr.theme.type.title.size, 99)
}

// Following again is harmless on a tree that never stopped, and a tree the
// run loop never spoke to falls back to what it started with rather than to
// an empty theme.
@(test)
following_the_desktop_is_safe_to_ask_for_twice :: proc(t: ^testing.T) {
	tr: Tree
	tree_init(&tr) // no run loop: nothing has said what the desktop's theme is
	defer tree_destroy(&tr)
	was := tr.theme.name
	testing.expect(t, was != "", "a tree starts with a theme")

	follow_system_theme(&tr)
	testing.expect_value(t, tr.theme.name, was)
	follow_system_theme(&tr)
	testing.expect_value(t, tr.theme.name, was)
	testing.expect(t, !tr.theme_app)
}

// The same for the accessibility preferences: an app that offers "use the
// desktop's appearance" pins its own with `set_a11y_prefs` and un-pins them
// with `follow_system_a11y`, after which a change to Large Text, reduce
// motion or reduce transparency reaches the tree again.
@(test)
a_tree_can_follow_the_desktop_a11y_again_after_set_a11y_prefs :: proc(t: ^testing.T) {
	tr: Tree
	light := theme_light()
	ft_tree(&tr, light)
	defer tree_destroy(&tr)
	body := light.type.body.size

	// the desktop says Large Text and reduce-motion
	tree_desktop_a11y(&tr, A11y_Prefs{text_scale = 1.5, reduce_motion = true})
	testing.expect_value(t, a11y_prefs(&tr).text_scale, f32(1.5))
	testing.expectf(t, tr.theme.type.body.size == body * 1.5, "folded in: %v", tr.theme.type.body.size)
	testing.expect(t, tr.theme.motion.reduce, "and reduce-motion with it")

	// the app pins its own (the desktop it is embedded in says so)
	set_a11y_prefs(&tr, A11y_Prefs{text_scale = 1})
	testing.expect_value(t, a11y_prefs(&tr).text_scale, f32(1))
	testing.expect(t, !tr.theme.motion.reduce, "the app's preferences are the ones in force")

	// …and the desktop changing is ignored while they are pinned
	tree_desktop_a11y(&tr, A11y_Prefs{text_scale = 2, reduce_motion = true})
	testing.expect_value(t, a11y_prefs(&tr).text_scale, f32(1))

	// the setting is turned off: the desktop's are back, as they are now
	follow_system_a11y(&tr)
	testing.expect_value(t, a11y_prefs(&tr).text_scale, f32(2))
	testing.expectf(t, tr.theme.type.body.size == body * 2, "and folded in again: %v", tr.theme.type.body.size)
	testing.expect(t, tr.theme.motion.reduce, "including the one it missed while pinned")

	// and a later change reaches it, which is the whole point
	tree_desktop_a11y(&tr, A11y_Prefs{text_scale = 1.25})
	testing.expect_value(t, a11y_prefs(&tr).text_scale, f32(1.25))
	testing.expect(t, !tr.theme.motion.reduce, "reduce-motion turned off reaches it too")
}

// An app's own text size is not the desktop's: `set_text_scale` multiplies,
// and going back to following the desktop must leave the app's own factor
// alone.
@(test)
following_the_desktop_a11y_again_keeps_the_apps_own_text_scale :: proc(t: ^testing.T) {
	tr: Tree
	light := theme_light()
	ft_tree(&tr, light)
	defer tree_destroy(&tr)
	tree_desktop_a11y(&tr, A11y_Prefs{text_scale = 1.5})
	set_text_scale(&tr, 1.25)
	testing.expect_value(t, text_scale(&tr), f32(1.5 * 1.25))
	set_a11y_prefs(&tr, A11y_Prefs{text_scale = 1})
	testing.expect_value(t, text_scale(&tr), f32(1.25))
	follow_system_a11y(&tr)
	testing.expect_value(t, text_scale(&tr), f32(1.5 * 1.25))
}


@(test)
theme_accent_prefers_the_apps_own :: proc(t: ^testing.T) {
	// An app that chose a colour chose it: a desktop set to orange must not
	// repaint someone's brand.
	mine := Color{0.1, 0.4, 0.8, 1}
	sys := platform.Ev_Theme{has_accent = true, accent = {1, 0.4, 0, 1}}
	testing.expect_value(t, theme_accent(mine, sys), mine)
}

@(test)
theme_accent_takes_the_desktops_when_the_app_named_none :: proc(t: ^testing.T) {
	// An app naming no accent takes the desktop's.
	sys := platform.Ev_Theme{has_accent = true, accent = {0.5, 0.5, 0.5, 1}}
	got := theme_accent({}, sys)
	testing.expect(t, got != Color{}, "the desktop's accent is used")
	// …and converted: the desktop states sRGB, Color is linear.
	testing.expect(t, abs(got.r - srgb_to_linear(0.5)) < 0.001,
		"sRGB 0.5 is linear 0.214, not 0.5")
	testing.expect(t, got.r < 0.3, "using the channel as it came would seed a much darker theme")
}

@(test)
theme_accent_is_nothing_when_neither_says :: proc(t: ^testing.T) {
	// No app accent and a desktop that does not report one: Baldr's own
	// theme.
	testing.expect_value(t, theme_accent({}, platform.Ev_Theme{}), Color{})
}


// An app that names a theme of its own and offers System gets the desktop's
// when it asks: if the run loop handed its trees the app's own theme as "the
// desktop's", follow_system_theme would put that straight back. Driven
// through the procs the run loop calls: pick_theme for the desktop's theme,
// tree_start_theme for a new surface.
@(test)
an_app_that_names_a_theme_can_still_follow_a_light_desktop :: proc(t: ^testing.T) {
	desktop, raw := pick_theme({}, {}, platform.Ev_Theme{dark = false})
	tr: Tree
	tree_init(&tr)
	defer tree_destroy(&tr)
	tree_desktop_theme(&tr, desktop, raw)
	tree_start_theme(&tr, theme_dark()) // App.theme = theme_dark()
	testing.expect(t, tr.theme_app, "the app's own theme is pinned")
	testing.expect_value(t, tr.theme.name, theme_dark().name)
	testing.expect(t, luminance(tr.theme.color.surface) < 0.2, "and it is dark")

	follow_system_theme(&tr) // the picker on System
	testing.expect(t, !tr.theme_app, "following the desktop")
	testing.expectf(t, luminance(tr.theme.color.surface) > 0.5,
		"the desktop is light, so the surface is (luminance %v, theme %q)", luminance(tr.theme.color.surface), tr.theme.name)
}

// An app that names no theme starts on the desktop's, unpinned.
@(test)
an_app_that_names_no_theme_starts_on_the_desktops :: proc(t: ^testing.T) {
	desktop, raw := pick_theme({}, {}, platform.Ev_Theme{dark = true})
	tr: Tree
	tree_init(&tr)
	defer tree_destroy(&tr)
	tree_desktop_theme(&tr, desktop, raw)
	tree_start_theme(&tr, {})
	testing.expect(t, !tr.theme_app, "following")
	testing.expect_value(t, tr.theme.name, desktop.name)
	testing.expect(t, luminance(tr.theme.color.surface) < 0.2, "a dark desktop, a dark surface")
}


// A window's frame follows the theme drawn in it. The backend is told when
// the theme turns dark or light and not on every build, and the first build
// always tells it, because until then it shows the desktop's.
@(private = "file")
Dark_Told :: struct { calls: int, last: bool }
@(private = "file")
dark_told: Dark_Told

@(test)
a_windows_frame_is_told_when_its_theme_turns_dark_or_light :: proc(t: ^testing.T) {
	dark_told = {}
	b := platform.Backend{}
	b.surface_set_dark = proc(b: ^platform.Backend, s: platform.Surface, dark: bool) {
		dark_told.calls += 1
		dark_told.last = dark
	}
	told: Told_Dark
	dark, light := theme_dark(), theme_light()

	frame_dark_sync(&b, 1, &dark, &told) // the first build: said, whatever it is
	testing.expect_value(t, dark_told.calls, 1)
	testing.expect(t, dark_told.last, "a dark theme, a dark frame")
	frame_dark_sync(&b, 1, &dark, &told) // built again, still dark: nothing to say
	testing.expect_value(t, dark_told.calls, 1)
	frame_dark_sync(&b, 1, &light, &told) // the app picked Light
	testing.expect_value(t, dark_told.calls, 2)
	testing.expect(t, !dark_told.last, "and the frame goes light with it")

	b.surface_set_dark = nil // a backend whose frame is not its own (Wayland)
	frame_dark_sync(&b, 1, &dark, &told)
	testing.expect_value(t, dark_told.calls, 2)
}

}
