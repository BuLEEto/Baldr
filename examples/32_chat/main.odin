// 32_chat — a chat that rides its newest message: `list` with
// `estimated_height`, `key_of` and `follow_end`, bubbles that are as wide
// as their text, and the per-message actions as small always-visible icons.
//
// It is meant to be scrolled: a chat-shaped list has rows of mixed heights
// and follows the end, so
//
//   - the wheel and the touchpad must move it, from the newest message up;
//   - "↓ Newest" appears the moment you are not at the bottom, lands on the
//     newest message and goes away again;
//   - a message arrives every few seconds: it follows while you are at the
//     bottom and leaves you alone while you are reading further up;
//   - the rows change height after they are measured — a picture decodes
//     out of its placeholder, a link preview's image lands, a reaction
//     appears under a bubble laid out a minute ago — and the message being
//     read must stay where it is.
//
// The row shapes are a messenger's: picture (one of them animated), link
// preview, reply quote, reactions, voice note, file card, code block, group
// senders with avatars, date dividers, a "load more" sentinel that prepends,
// and a pending message that becomes a delivered one.
//
//   ./build.sh example 32_chat run
package main

import "core:fmt"
import "baldr:baldr"

Msg :: union { At, Newest, Act, Arrived, Tick, Play, More }

At      :: struct { at: baldr.List_At }
Newest  :: struct {}
Act     :: struct { what: string, msg: int }
Arrived :: struct {} // the timer: someone sent something
Tick    :: struct {} // …and the quarter-second that moves a voice note along
Play    :: struct { msg: int }
More    :: struct {} // the sentinel at the top: load older messages

Kind :: enum { Text, Picture, Link, Voice, File, Code, Sentinel }

Row :: struct {
	kind:      Kind,
	body:      string,
	sender:    int,  // 0 is me; 1.. are the other people in the group
	quote:     int,  // -1, or the message this is a reply to
	reactions: int,  // chips that appear after the row was measured
	day:       int,  // a date divider is drawn when this differs from the row above
	pending:   bool, // "sending…" until it is delivered
	secs:      int,  // a voice note's length
	img:       baldr.Image,
	ready:     bool, // the placeholder has become the picture (or the og:image landed)
}

State :: struct {
	rows:       [dynamic]Row,
	at:         baldr.List_At,
	did:        string, // what the last action button said (in did_buf: a string kept past this message is the state's own)
	did_buf:    [64]u8,
	next:       int,
	tick:       int,
	playing:    int, // the voice note being played, or -1
	played:     int, // …and how far into it, in quarter-seconds
	oldest:     int, // how many older messages there are still to load
}

SENDERS := []string{"me", "George", "Ada", "Nik"}

BODIES := []string{
	"Morning!",
	"Pushed the fix — the bubble is as wide as its text again.",
	"Two things, in one message:\n- the wheel scrolls this up now\n- and ↓ Newest comes back down when you reach the bottom",
	"Long one, sorry: the list keeps your place while older messages load above you, measures each row once and keeps it by key, and only builds the rows you can see — so this stays the cost of a screenful however long the conversation gets.",
}

msg_key :: proc(user: rawptr, index: int) -> u64 { return u64(index + 1) * 10 }

// ---------------------------------------------------------------- pictures
//
// An app decodes its own pictures; these stand in for that. The point is
// *when* they arrive: a row is a placeholder at one height and the picture
// at another, which is the change the list has to absorb under the reader.

gradient :: proc(w, h: int, warm: bool) -> baldr.Image {
	px := make([]u8, w * h * 4)
	defer delete(px)
	for y in 0 ..< h do for x in 0 ..< w {
		i := (y * w + x) * 4
		u, v := u8(255 * x / max(w - 1, 1)), u8(255 * y / max(h - 1, 1))
		px[i], px[i + 1], px[i + 2], px[i + 3] = (u if warm else v), v / 2 + 60, (v if warm else u), 255
	}
	img, _ := baldr.image_from_rgba(w, h, px)
	return img
}

// An animated one, the `image_from_rgba_frames` path: a band that walks
// across. The toolkit runs it while it is on screen and stops when it is
// not, with no message and no view rebuilt per frame — so an animating row
// must not disturb a list that is keeping someone's place.
animation :: proc(w, h: int) -> baldr.Image {
	frames := make([][]u8, 8)
	delays := make([]int, 8)
	defer { for f in frames do delete(f); delete(frames); delete(delays) }
	for f in 0 ..< 8 {
		px := make([]u8, w * h * 4)
		band := f * w / 8
		for y in 0 ..< h do for x in 0 ..< w {
			i := (y * w + x) * 4
			near := abs(x - band) < w / 6
			px[i], px[i + 1], px[i + 2], px[i + 3] = 40, u8(90 if near else 40), u8(220 if near else 90), 255
		}
		frames[f], delays[f] = px, 120
	}
	img, _ := baldr.image_from_rgba_frames(w, h, frames, delays)
	return img
}

// ------------------------------------------------------------- the pieces

// The strip above a reply: who, and one line of what they said. It is part
// of the bubble's height, so it is another row that is not the size
// `estimated_height` guessed.
quote_strip :: proc(s: ^State, ui: ^baldr.Ui(Msg), of: int) {
	if of < 0 || of >= len(s.rows) do return
	th := &ui.tree.theme
	baldr.column(ui, gap = .xxs, padding = .xs, radius = 8, bg = th.color.fill, key = 10); {
		defer baldr.end(ui)
		q := s.rows[of]
		// A voice note or a photo has no text to quote, so the quote says what
		// it is: "replying to" with an empty line under it reads as broken.
		said := q.body
		if said == "" {
			switch q.kind {
			case .Voice:    said = "Voice message"
			case .Picture:  said = "Photo"
			case .File:     said = "File"
			case .Link:     said = "Link"
			case .Code:     said = "Code"
			case .Text, .Sentinel: said = "Message"
			}
		}
		baldr.text(ui, SENDERS[q.sender], role = .Caption, weight = baldr.Font_Weight.Semibold)
		baldr.text(ui, said, role = .Caption, muted = true, nowrap = true, ellipsis = .End)
	}
}

// Reaction chips. These appear *after* the bubble was measured — someone
// reacts to a message you have scrolled past — which is one of the three
// shapes that move a row's height late.
reactions_row :: proc(ui: ^baldr.Ui(Msg), n: int, mine: bool) {
	if n <= 0 do return
	th := &ui.tree.theme
	baldr.row(ui, gap = .xxs, justify = .End if mine else .Start, key = 20); {
		defer baldr.end(ui)
		chips := []string{"👍", "🎉", "❤️"}
		for i in 0 ..< min(n, len(chips)) {
			baldr.row(ui, gap = .xxs, padding = .xxs, radius = 10, bg = th.color.fill, align = .Center, key = u64(i + 1)); {
				defer baldr.end(ui)
				baldr.text(ui, chips[i], role = .Caption)
				baldr.text(ui, "1", role = .Caption, muted = true)
			}
		}
	}
}

// The bubble's body, by kind. Each is a different height, and three of them
// change height while the chat is open.
body_of :: proc(s: ^State, ui: ^baldr.Ui(Msg), i: int) {
	r := &s.rows[i]
	th := &ui.tree.theme
	switch r.kind {
	case .Text, .Sentinel:
		baldr.styled_text(ui, r.body, nil, key = 1)

	case .Picture:
		// Placeholder, then picture: 220x140 of nothing until it decodes,
		// then the real thing at its own height, with a caption in the same
		// bubble. This is the row that grows under the reader.
		if r.ready {
			baldr.image(ui, &r.img, width = 220, radius = 10, label = "Photo", key = 1)
		} else {
			baldr.box(ui, width = 220, height = 140, radius = 10, bg = th.color.fill, key = 1)
		}
		if r.body != "" do baldr.text(ui, r.body, role = .Caption, max_width = 220, key = 2)

	case .Link:
		baldr.styled_text(ui, r.body, nil, key = 1)
		{
			// A preview card whose og:image lands later: title and
			// description first, the picture when it arrives.
			baldr.column(ui, gap = .xxs, padding = .xs, radius = 10, bg = th.color.surface, max_width = 280, key = 2); {
				defer baldr.end(ui)
				if r.ready do baldr.image(ui, &r.img, width = 264, height = 120, radius = 8, label = "Preview", key = 1)
				baldr.text(ui, "Baldr — a retained-mode GUI toolkit in Odin", role = .Caption,
					weight = baldr.Font_Weight.Semibold, max_width = 264, key = 2)
				baldr.text(ui, "No SDL, no GLFW, no C: Vulkan on Linux and Windows, Metal on macOS.",
					role = .Caption, muted = true, max_width = 264, key = 3)
			}
		}

	case .Voice:
		baldr.row(ui, gap = .xs, align = .Center, key = 1); {
			defer baldr.end(ui)
			playing := s.playing == i
			baldr.button(ui, "Stop" if playing else "Play", Msg(Play{i}), variant = .Outline, size = .Small,
				icon = .Square if playing else .Play, icon_only = true, key = 1)
			baldr.box(ui, width = 120, height = 4, radius = 2, bg = th.color.fill_strong, key = 2)
			at := s.played / 4 if playing else 0
			baldr.text(ui, fmt.tprintf("%d:%02d / %d:%02d", at / 60, at % 60, r.secs / 60, r.secs % 60),
				role = .Caption, muted = true, key = 3)
		}
	case .File:
		baldr.row(ui, gap = .sm, align = .Center, key = 1); {
			defer baldr.end(ui)
			baldr.text(ui, "📎", key = 1)
			baldr.column(ui, gap = .xxs, key = 2); {
				defer baldr.end(ui)
				baldr.text(ui, r.body, weight = baldr.Font_Weight.Medium, nowrap = true, ellipsis = .Middle, max_width = 220)
				baldr.text(ui, "application/pdf · 1.4 MB", role = .Caption, muted = true)
			}
			baldr.button(ui, "Save as…", Msg(Act{"Save", i}), variant = .Ghost, size = .Small, key = 3)
		}
	case .Code:
		baldr.column(ui, gap = .xxs, key = 1); {
			defer baldr.end(ui)
			baldr.row(ui, align = .Center, key = 1); {
				defer baldr.end(ui)
				baldr.text(ui, "odin", role = .Caption, muted = true, flex = 1)
				baldr.button(ui, "Copy", Msg(Act{"Copy", i}), variant = .Ghost, size = .Small,
					icon = .Copy, icon_only = true, key = 1)
			}
			// One Code run over the whole body: the app says "this is code", the
			// toolkit draws it in the mono family.
			runs := []baldr.Run{{end = len(r.body), attrs = {.Code}}}
			baldr.styled_text(ui, r.body, runs, key = 2)
		}
	}
}

// One message: avatar, bubble, reactions and the action icons, aligned to
// whoever sent it. A date divider goes above it when the day changes, and a
// group chat names the sender over an incoming bubble.
message :: proc(s: ^State, ui: ^baldr.Ui(Msg), i: int) {
	r := &s.rows[i]
	th := &ui.tree.theme
	mine := r.sender == 0
	// A colour per sender from the syntax palette: the theme's one set of
	// colours guaranteed ≥ 4.5:1 over surface_variant, the incoming bubble's
	// background (`secondary` would be grey on grey).
	tint := []baldr.Color{th.color.code.keyword, th.color.code.string, th.color.code.constant}[r.sender % 3]
	baldr.column(ui, gap = .xxs, key = msg_key(nil, i)); defer baldr.end(ui)

	if i == 0 || s.rows[i - 1].day != r.day {
		baldr.row(ui, justify = .Center, padding = .xxs, key = 1); {
			defer baldr.end(ui)
			baldr.row(ui, radius = 10, bg = th.color.fill, padding = .xxs, key = 1); {
				defer baldr.end(ui)
				baldr.text(ui, "Today" if r.day == 1 else "Yesterday", role = .Caption, muted = true)
			}
		}
	}

	baldr.row(ui, gap = .xs, align = .End, key = 2); {
		defer baldr.end(ui)
		if mine do baldr.spacer(ui, key = 1)
		if !mine {
			// The avatar: one letter on a circle in that sender's colour, the
			// same size for everyone so the bubbles all start on one line.
			baldr.column(ui, width = 28, height = 28, radius = 14, bg = tint, justify = .Center, key = 2); {
				defer baldr.end(ui)
				baldr.text(ui, SENDERS[r.sender][:1], color = th.color.on_primary, align = .Center)
			}
		}
		baldr.column(ui, gap = .xxs, align = .End if mine else .Start, max_width = 520, key = 3); {
			defer baldr.end(ui)
			{
				// The bubble: as wide as its content, capped at max_width, and
				// text wrapping at the width the bubble ends up with.
				bg := th.color.primary_container if mine else th.color.surface_variant
				baldr.column(ui, gap = .xs, padding = .md, radius = 18, bg = bg, key = 2); {
					defer baldr.end(ui)
					// Who said it, inside the bubble: a group chat needs the name,
					// and over the bubble's own background is where the colour was
					// chosen to be readable.
					if !mine {
						baldr.text(ui, SENDERS[r.sender], role = .Caption, color = tint,
							weight = baldr.Font_Weight.Semibold, key = 1)
					}
					quote_strip(s, ui, r.quote)
					body_of(s, ui, i)
				}
			}
			reactions_row(ui, r.reactions, mine)
			baldr.row(ui, gap = .xxs, align = .Center, key = 3); {
				defer baldr.end(ui)
				act :: proc(ui: ^baldr.Ui(Msg), label: string, icon: baldr.Icon, i: int, key: u64) {
					baldr.button(ui, label, Msg(Act{label, i}), variant = .Ghost, icon = icon,
						icon_only = true, size = .Small, key = key)
				}
				act(ui, "React", .Smile, i, 1)
				act(ui, "Reply", .Reply, i, 2)   // not Undo_2, which reads as undo
				act(ui, "Copy", .Copy, i, 3)
				act(ui, "Delete", .Trash, i, 4)
				baldr.text(ui, "09:41", role = .Caption, muted = true, key = 5)
				// sending… becomes ✓ in place: a row changing the way an app
				// changes one, without changing its identity
				if mine do baldr.text(ui, "sending…" if r.pending else "✓", role = .Caption, muted = true, key = 6)
			}
		}
		if !mine do baldr.spacer(ui, key = 4)
	}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, flex = 1); defer baldr.end(ui)
	baldr.row(ui, padding = .sm, gap = .sm, align = .Center); {
		defer baldr.end(ui)
		baldr.text(ui, "Chat", role = .Title)
		baldr.text(ui, fmt.tprintf("%d messages", len(s.rows)), role = .Caption, muted = true, flex = 1)
		if s.did != "" do baldr.text(ui, s.did, role = .Caption, muted = true)
	}
	{
		first, last := baldr.list(ui, len(s.rows), estimated_height = 96, key_of = msg_key,
			follow_end = true, on_at = proc(e: baldr.Ev(baldr.List_At)) -> Msg { return At{e.value} },
			gap = .xs, padding = .sm, gutter = true, label = "Chat", key = 1); {
			defer baldr.end(ui)
			for i in first ..< last {
				if s.rows[i].kind == .Sentinel {
					// The top of what is loaded: a button while there is more,
					// the start of the conversation when there is not. Pressing
					// it prepends, and what you are reading must not move.
					baldr.row(ui, justify = .Center, padding = .sm, key = msg_key(nil, i)); {
						defer baldr.end(ui)
						if s.oldest > 0 {
							baldr.button(ui, "Load more", Msg(More{}), variant = .Outline, size = .Small)
						} else {
							baldr.text(ui, "Beginning of the conversation", role = .Caption, muted = true)
						}
						continue
					}
				}
				message(s, ui, i)
			}
		}
	}
	// Up from the bottom: say so, and offer the way back. Revealing the
	// last row means "to the end, and follow", and stays that even if a
	// message arrives before it lands.
	if !s.at.at_end {
		baldr.row(ui, padding = .sm, justify = .Center); {
			defer baldr.end(ui)
			baldr.button(ui, "↓ Newest", Msg(Newest{}), variant = .Outline, size = .Small)
		}
	}
}

// what a new message looks like: the kinds cycle, so the heights do too
arrive :: proc(s: ^State) {
	n := s.next
	r := Row{quote = -1, day = 1, sender = n % len(SENDERS), pending = true}
	switch n % 5 {
	case 0: r.kind, r.body = .Text, fmt.aprintf("%s (%d)", BODIES[n % len(BODIES)], n)
	case 1: r.kind, r.body = .Picture, "from the beach"
	case 2: r.kind, r.body, r.quote = .Text, fmt.aprintf("Replying to that (%d)", n), max(len(s.rows) - 2, 1)
	case 3: r.kind, r.secs = .Voice, 12
	case 4: r.kind, r.body = .Link, "worth a read: https://example.invalid/baldr"
	}
	append(&s.rows, r)
	s.next += 1
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Chat", app_id = "baldr.chat", size = {560, 680},
		init = proc() -> State {
			s := State{playing = -1, oldest = 60}
			append(&s.rows, Row{kind = .Sentinel, quote = -1, day = 0})
			for i in 0 ..< 60 {
				r := Row{quote = -1, day = 0 if i < 40 else 1, sender = i % len(SENDERS)}
				switch i % 7 {
				case 0, 1, 4: r.kind, r.body = .Text, BODIES[i % len(BODIES)]
				case 2:       r.kind, r.body = .Picture, "last summer"
				case 3:       r.kind, r.body = .Link, "worth a read: https://example.invalid/baldr"
				case 5:       r.kind, r.secs = .Voice, 12
				case 6:       r.kind, r.body = .File, "the-design-document.pdf"
				}
				if i % 11 == 0 && i > 0 do r.quote = i
				append(&s.rows, r)
			}
			s.rows[len(s.rows) - 4] = Row{kind = .Code, quote = -1, day = 1, sender = 1,
				body = "list(ui, len(msgs),\n\testimated_height = 96,\n\tfollow_end = true)"}
			s.next = 60
			return s
		},
		subscriptions = proc(s: ^State, out: ^[dynamic]baldr.Sub(Msg)) {
			append(out, baldr.every(Msg, 3000, Msg(Arrived{})))
			append(out, baldr.every(Msg, 250, Msg(Tick{})))
		},
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			switch v in m {
			case At:
				s.at = v.at
			case Newest:
				// The list's own key is 1, in the view below. Pressing this
				// twice with no new message in between asks twice, which is
				// what it means — there is no generation to keep in step.
				return baldr.reveal_key(Msg, 1, msg_key(nil, len(s.rows) - 1))
			case Act:
				s.did = fmt.bprintf(s.did_buf[:], "%s on message %d", v.what, v.msg + 1)
			case Play:
				s.playing, s.played = (-1 if s.playing == v.msg else v.msg), 0
			case More:
				// older messages arrive above what is on screen
				older := make([dynamic]Row)
				defer delete(older)
				for i in 0 ..< 20 {
					append(&older, Row{kind = .Text, quote = -1, day = 0, sender = i % len(SENDERS),
						body = fmt.aprintf("Older message %d", s.oldest - 20 + i)})
				}
				inject_at_elems(&s.rows, 1, ..older[:])
				s.oldest = max(s.oldest - 20, 0)
			case Arrived:
				arrive(s)
			case Tick:
				s.tick += 1
				if s.playing >= 0 {
					s.played += 1
					if s.played / 4 >= s.rows[s.playing].secs do s.playing, s.played = -1, 0
				}
				// The three that change a row's height after it has been
				// measured, on a timer so they land while you are reading
				// somewhere else: a picture decodes, a preview's image
				// arrives, a reaction appears. And a pending message is
				// delivered, which changes a row without changing its size.
				if s.tick % 4 == 0 {
					for i := len(s.rows) - 1; i >= 0; i -= 1 {
						r := &s.rows[i]
						if r.pending {
							r.pending = false
							break
						}
						if (r.kind == .Picture || r.kind == .Link) && !r.ready {
							if r.kind == .Link {
								r.img = gradient(264, 120, false)
							} else {
								r.img = gradient(220, 150, i % 2 == 0) if i % 3 != 0 else animation(220, 150)
							}
							r.ready = true
							break
						}
					}
				}
				if s.tick % 7 == 0 && len(s.rows) > 3 {
					at := len(s.rows) - 3
					s.rows[at].reactions = min(s.rows[at].reactions + 1, 3)
				}
			}
			return {}
		},
		view = view,
	})
}
