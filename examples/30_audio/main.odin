// 30_audio — a voice memo: record from the default microphone, watch the
// level, play it back.
//
// The point of the example is the shape of the loop. `baldr:audio` is a
// sibling package, so the app owns the streams and drains them itself:
// one subscription tick drains the capture ring into the app's own buffer
// and tops the playback stream up, and nothing in it ever blocks. There
// are no codecs here and none in the package — this keeps raw f32, which
// a real app would hand to an encoder at the point it sends it.
package main

import "core:fmt"
import "baldr:audio"
import "baldr:baldr"

Msg :: union {
	Tick,
	Record,
	Stop,
	Play,
	Clear,
}
Tick   :: struct {}
Record :: struct {}
Stop   :: struct {}
Play   :: struct {}
Clear  :: struct {}

State :: struct {
	cap:    audio.Capture,
	play:   audio.Playback,
	note:   [dynamic]f32, // the recording, interleaved f32 at cap.format
	format: audio.Format,
	sent:   int,    // how much of `note` has been handed to playback
	peak:   f32,    // the level meter, with a decay so it does not flicker
	lost:   int,
	err:    string, // the last real error, for the person to read
}

// drain moves everything recorded into the app's buffer and keeps the
// playback stream fed. Called once a tick; it never waits for either.
drain :: proc(s: ^State) {
	buf: [4096]f32
	if s.cap.open {
		for {
			n, err := audio.capture_read(&s.cap, buf[:])
			if err != .None {
				s.err = audio.error_text(err)
				audio.capture_close(&s.cap)
				break
			}
			if n == 0 do break
			append(&s.note, ..buf[:n])
			for v in buf[:n] do s.peak = max(s.peak, abs(v))
		}
		s.lost = audio.capture_lost(&s.cap)
	}
	s.peak *= 0.90 // ~17 ticks to fall away: fast enough to follow a voice
	if s.play.open {
		if s.sent < len(s.note) {
			n, err := audio.playback_write(&s.play, s.note[s.sent:])
			if err != .None {
				s.err = audio.error_text(err)
				audio.playback_close(&s.play)
			}
			s.sent += n
		} else if audio.playback_drained(&s.play) {
			audio.playback_close(&s.play) // the note finished: put the button back
		}
	}
}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch _ in m {
	case Tick:
		drain(s)
	case Record:
		audio.playback_close(&s.play)
		clear(&s.note)
		s.sent, s.lost, s.err = 0, 0, ""
		if err := audio.capture_open(&s.cap, audio.Format{48_000, 1}); err != .None {
			s.err = audio.error_text(err)
		}
		s.format = s.cap.format
	case Stop:
		audio.capture_close(&s.cap)
		audio.playback_close(&s.play)
	case Play:
		if len(s.note) == 0 do break
		audio.capture_close(&s.cap)
		s.sent = 0
		if err := audio.playback_open(&s.play, s.format); err != .None {
			s.err = audio.error_text(err)
		}
	case Clear:
		audio.capture_close(&s.cap)
		audio.playback_close(&s.play)
		clear(&s.note)
		s.sent, s.lost, s.err, s.peak = 0, 0, "", 0
	}
	return {}
}

subscriptions :: proc(s: ^State, out: ^[dynamic]baldr.Sub(Msg)) {
	// 60 Hz while anything is open, so the meter looks live and neither
	// ring is left to fill; nothing at all when it is idle.
	if s.cap.open || s.play.open do append(out, baldr.every(Msg, 16, Msg(Tick{})))
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, padding = .lg, gap = .md); defer baldr.end(ui)
	baldr.text(ui, "Voice memo", role = .Title)

	// One thing happens at a time, so while recording or playing the row is
	// only Stop: swapping labels on three buttons would move them under the
	// pointer as the widths changed.
	baldr.row(ui, gap = .sm, align = .Center)
	{
		defer baldr.end(ui)
		switch {
		case s.cap.open:
			baldr.button(ui, "Stop", Msg(Stop{}), variant = .Primary, icon = .Square)
			baldr.text(ui, "recording…", role = .Caption, muted = true)
		case s.play.open:
			baldr.button(ui, "Stop", Msg(Stop{}), variant = .Primary, icon = .Square)
			left := audio.playback_queued(&s.play)
			baldr.text(ui, fmt.tprintf("playing — %.1f s left",
				f64(audio.ms_for_samples(s.play.format, left)) / 1000), role = .Caption, muted = true)
		case:
			baldr.button(ui, "Record", Msg(Record{}), variant = .Primary, icon = .Mic)
			baldr.button(ui, "Play", Msg(Play{}), icon = .Play, disabled = len(s.note) == 0)
			baldr.button(ui, "Clear", Msg(Clear{}), variant = .Ghost, disabled = len(s.note) == 0)
		}
	}

	baldr.row(ui, gap = .sm, align = .Center)
	{
		defer baldr.end(ui)
		baldr.text(ui, "Level", role = .Caption, muted = true)
		// A peak meter, not an average: a voice note that clipped should
		// look like it clipped.
		baldr.progress(ui, min(s.peak, 1), label = "Recording level", flex = 1)
	}

	if s.format.rate > 0 {
		secs := f64(audio.ms_for_samples(s.format, len(s.note))) / 1000
		baldr.text(ui, fmt.tprintf("%.1f s recorded — %d samples at %d Hz", secs, len(s.note), s.format.rate))
	} else {
		baldr.text(ui, "nothing recorded yet", muted = true)
	}
	danger := ui.tree.theme.color.danger
	if s.lost > 0 {
		baldr.text(ui, fmt.tprintf("%d samples lost — the recording has a hole in it", s.lost),
			role = .Caption, color = danger)
	}
	if s.err != "" {
		baldr.text(ui, s.err, role = .Caption, color = danger)
	}
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Voice memo", app_id = "baldr.audio", size = {480, 300},
		update = update, view = view, subscriptions = subscriptions,
	})
}
