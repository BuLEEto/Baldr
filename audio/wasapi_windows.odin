#+build windows
// The Windows backend: one WASAPI shared-mode stream per `Capture` or
// `Playback`, each with a thread of its own that waits on the endpoint's
// event and moves samples to or from the `Ring`.
//
// Shared mode, not exclusive: exclusive mode takes the device away from
// everything else on the machine, and shared mode lets Windows convert.
// The endpoint's mix format is whatever the sound settings say (commonly
// 44.1 kHz stereo); with `AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM` and
// `SRC_DEFAULT_QUALITY` the audio engine resamples and re-channels, so
// there is no resampler here.
//
// Thread discipline:
//   - The stream's thread does all COM calls after `*_open` returns. It
//     touches the ring, the two atomic counters and its own accounting,
//     and nothing else.
//   - The app's thread calls nothing COM: `nudge` sets the event, `flush`
//     and `close` set a flag and wait for the thread to notice.
package audio

import "base:runtime"
import "core:sync"
import win "core:sys/windows"
import "core:thread"

// The stream runs on a buffer of this much, and wakes up about twice that
// often. WASAPI rounds it to the device's period anyway.
@(private = "file")
WA_MIN_LATENCY_MS :: 10

// How long the thread waits for the endpoint event before looking again.
// It is a backstop, not the clock: a device that stops signalling must not
// leave the thread unkillable.
@(private = "file")
WA_WAIT_MS :: win.DWORD(200)

// Chunks of frames handed to the renderer, so that `playback_queued` counts
// real samples and not the silence the stream runs on. The device buffer
// holds a handful of periods, so this does not fill; if it did, the oldest
// is retired early and the count is low by that much for one period.
@(private)
WA_CHUNKS :: 64

@(private)
Wa_Chunk :: struct {
	end_frame: u64, // cumulative frames written to the device after this chunk
	real:      i32, // samples of the app's own audio in it (0 for silence)
}

@(private)
Wa_Stream :: struct {
	client:   ^IAudioClient,
	render:   ^IAudioRenderClient,
	capture:  ^IAudioCaptureClient,
	device:   ^IMMDevice,
	event:    win.HANDLE,
	th:       ^thread.Thread,
	cap:      ^Capture,
	play:     ^Playback,
	channels: int,
	frames:   u32, // the device buffer, in frames

	stop:     bool, // atomic-ish: set by the app's thread, read by the stream's
	flush:    bool, // ditto: drop what the device holds at the next pass
	running:  bool,

	// playback accounting, stream thread only except `pending`
	pending:   i32, // atomic: real samples the device still holds
	total:     u64, // cumulative frames written to the device
	chunks:    [WA_CHUNKS]Wa_Chunk,
	head, tail: int,
	gap:       bool,
	had_sound: bool,
}

@(private = "file")
wa_flag :: proc(p: ^bool) -> bool {
	return sync.atomic_load_explicit((^b8)(p), .Acquire) != false
}

@(private = "file")
wa_set :: proc(p: ^bool, v: bool) {
	sync.atomic_store_explicit((^b8)(p), b8(v), .Release)
}

// wa_error names the HRESULTs worth telling a person apart. Anything else
// is `.Failed`.
@(private = "file")
wa_error :: proc(hr: win.HRESULT) -> Error {
	switch hr {
	case 0:                                return .None
	case E_ACCESSDENIED_HR:                return .Permission
	case E_NOTFOUND_HR:                    return .No_Device
	case AUDCLNT_E_DEVICE_INVALIDATED:     return .No_Device
	case AUDCLNT_E_ENDPOINT_CREATE_FAILED: return .No_Device
	case AUDCLNT_E_DEVICE_IN_USE:          return .No_Device
	case AUDCLNT_E_SERVICE_NOT_RUNNING:    return .No_Server
	case AUDCLNT_E_UNSUPPORTED_FORMAT:     return .Bad_Format
	case AUDCLNT_E_WRONG_ENDPOINT_TYPE:    return .Bad_Format
	case AUDCLNT_E_RESOURCES_INVALIDATED:  return .Closed
	}
	return .Failed
}

@(private = "file")
wa_format :: proc(f: Format) -> win.WAVEFORMATEXTENSIBLE {
	block := u16(f.channels * size_of(f32))
	out := win.WAVEFORMATEXTENSIBLE{
		Format = {
			wFormatTag      = WAVE_FORMAT_EXTENSIBLE,
			nChannels       = u16(f.channels),
			nSamplesPerSec  = u32(f.rate),
			nAvgBytesPerSec = u32(f.rate) * u32(block),
			nBlockAlign     = block,
			wBitsPerSample  = 32,
			cbSize          = u16(size_of(win.WAVEFORMATEXTENSIBLE) - size_of(win.WAVEFORMATEX)),
		},
		SubFormat = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT,
	}
	out.Samples.wValidBitsPerSample = 32
	// Mono is the centre speaker's channel; stereo is front left and right.
	// A larger count is left at 0, which tells the engine "whatever the
	// device's own order is".
	switch f.channels {
	case 1: out.dwChannelMask = {.FRONT_CENTER}
	case 2: out.dwChannelMask = {.FRONT_LEFT, .FRONT_RIGHT}
	}
	return out
}

// --- opening the endpoint ---

@(private = "file")
wa_open_client :: proc(ws: ^Wa_Stream, f: Format, latency_ms: int, device: string, capture: bool) -> Error {
	// COM on this thread: what `playback_open` blocks on. S_FALSE (already
	// in an apartment) and RPC_E_CHANGED_MODE (in a different one) are both
	// fine: only the interfaces made here are called.
	if co := win.CoInitializeEx(nil, win.COINIT.MULTITHREADED);
		co < 0 && co != win.HRESULT(-2147417850) do return .Failed

	enumerator: ^IMMDeviceEnumerator
	if hr := win.CoCreateInstance(&CLSID_MMDeviceEnumerator, nil, win.CLSCTX_ALL,
		&IID_IMMDeviceEnumerator, cast(^rawptr)&enumerator); hr < 0 || enumerator == nil {
		return .No_Server
	}
	defer enumerator->Release()

	flow := E_CAPTURE if capture else E_RENDER
	if device != "" {
		// A backend's own name for an endpoint is its WASAPI id string.
		wide := win.utf8_to_wstring(device)
		if hr := enumerator->GetDevice(wide, &ws.device); hr < 0 || ws.device == nil {
			return .No_Device
		}
	} else {
		if hr := enumerator->GetDefaultAudioEndpoint(flow, E_CONSOLE, &ws.device); hr < 0 || ws.device == nil {
			return wa_error(hr)
		}
	}

	if hr := ws.device->Activate(&IID_IAudioClient, win.CLSCTX_ALL, nil, cast(^rawptr)&ws.client);
		hr < 0 || ws.client == nil {
		return wa_error(hr)
	}

	wf := wa_format(f)
	dur := REFERENCE_TIME(max(latency_ms, WA_MIN_LATENCY_MS)) * REF_TIMES_PER_MS
	flags := AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_NOPERSIST |
		AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY
	if hr := ws.client->Initialize(AUDCLNT_SHAREMODE_SHARED, flags, dur, 0, &wf.Format, nil); hr < 0 {
		return wa_error(hr)
	}
	if hr := ws.client->GetBufferSize(&ws.frames); hr < 0 do return wa_error(hr)

	ws.event = win.CreateEventW(nil, false, false, nil)
	if ws.event == nil do return .Failed
	if hr := ws.client->SetEventHandle(ws.event); hr < 0 do return wa_error(hr)

	if capture {
		if hr := ws.client->GetService(&IID_IAudioCaptureClient, cast(^rawptr)&ws.capture);
			hr < 0 || ws.capture == nil {
			return wa_error(hr)
		}
	} else {
		if hr := ws.client->GetService(&IID_IAudioRenderClient, cast(^rawptr)&ws.render);
			hr < 0 || ws.render == nil {
			return wa_error(hr)
		}
	}
	return .None
}

@(private = "file")
wa_teardown :: proc(ws: ^Wa_Stream) {
	if ws.client != nil do ws.client->Stop()
	if ws.render != nil  { ws.render->Release();  ws.render = nil }
	if ws.capture != nil { ws.capture->Release(); ws.capture = nil }
	if ws.client != nil  { ws.client->Release();  ws.client = nil }
	if ws.device != nil  { ws.device->Release();  ws.device = nil }
	if ws.event != nil   { win.CloseHandle(ws.event); ws.event = nil }
}

// --- the playback thread ---

// Wa_Pass is what one wake-up should do: play `take` frames of the app's
// audio, or `take` frames of silence, or nothing because the device is
// full. It is pure so the render thread's arithmetic can be tested without
// speakers.
@(private)
Wa_Pass :: struct {
	take:   u32,
	silent: bool,
	idle:   bool,
}

@(private)
wa_plan :: proc "contextless" (frames, padding: u32, have_frames: int) -> Wa_Pass {
	if padding >= frames do return {idle = true} // the device still holds a full buffer
	avail := frames - padding
	take := min(int(avail), max(have_frames, 0))
	// Nothing of the app's to play: fill the room with explicit silence
	// rather than leave it unwritten, which plays whatever was in it.
	if take <= 0 do return {take = avail, silent = true}
	return {take = u32(take)}
}

// wa_retire drops the chunks the device has finished with, so `pending` is
// the real samples still to be heard.
@(private)
wa_retire :: proc(ws: ^Wa_Stream, padding: u32) {
	// The device holds only frames this thread gave it, so padding should
	// never pass `total`; an underflow would retire every block at once while
	// the sound is still playing, so it is guarded.
	consumed := ws.total - u64(padding) if u64(padding) <= ws.total else 0
	for ws.head != ws.tail {
		c := ws.chunks[ws.head]
		if c.end_frame > consumed do break
		if c.real > 0 do sync.atomic_sub_explicit(&ws.pending, c.real, .Relaxed)
		ws.head = (ws.head + 1) % WA_CHUNKS
	}
}

@(private)
wa_push :: proc(ws: ^Wa_Stream, frames: u32, real: int) {
	ws.total += u64(frames)
	next := (ws.tail + 1) % WA_CHUNKS
	if next == ws.head { // full: retire the oldest rather than lose the count entirely
		c := ws.chunks[ws.head]
		if c.real > 0 do sync.atomic_sub_explicit(&ws.pending, c.real, .Relaxed)
		ws.head = (ws.head + 1) % WA_CHUNKS
		next = (ws.tail + 1) % WA_CHUNKS
	}
	ws.chunks[ws.tail] = {end_frame = ws.total, real = i32(real)}
	ws.tail = next
	if real > 0 do sync.atomic_add_explicit(&ws.pending, i32(real), .Relaxed)
}

@(private = "file")
wa_play_thread :: proc(t: ^thread.Thread) {
	ws := (^Wa_Stream)(t.data)
	win.CoInitializeEx(nil, win.COINIT.MULTITHREADED)
	defer win.CoUninitialize()
	task_index: win.DWORD = 0
	mm := AvSetMmThreadCharacteristicsW(win.utf8_to_wstring("Pro Audio"), &task_index)
	defer if mm != nil do AvRevertMmThreadCharacteristics(mm)

	if hr := ws.client->Start(); hr < 0 {
		set_state(&ws.play.state, wa_error(hr))
		return
	}
	for !wa_flag(&ws.stop) {
		win.WaitForSingleObject(ws.event, WA_WAIT_MS)
		if wa_flag(&ws.stop) do break

		if wa_flag(&ws.flush) {
			// Stop, drop, start: `Reset` refuses while the stream is
			// running, and the app has already cleared the ring.
			ws.client->Stop()
			ws.client->Reset()
			ws.total, ws.head, ws.tail = 0, 0, 0
			ws.chunks = {}
			sync.atomic_store_explicit(&ws.pending, 0, .Relaxed)
			ws.gap, ws.had_sound = false, false
			wa_set(&ws.flush, false)
			if hr := ws.client->Start(); hr < 0 {
				set_state(&ws.play.state, wa_error(hr))
				return
			}
			continue
		}

		padding: u32
		if hr := ws.client->GetCurrentPadding(&padding); hr < 0 {
			set_state(&ws.play.state, wa_error(hr))
			return
		}
		wa_retire(ws, padding)
		pass := wa_plan(ws.frames, padding, ring_available(&ws.play.ring) / ws.channels)
		if pass.idle do continue
		take := int(pass.take)
		ptr: [^]u8
		if !pass.silent {
			if hr := ws.render->GetBuffer(u32(take), &ptr); hr < 0 {
				set_state(&ws.play.state, wa_error(hr))
				return
			}
			got := ring_read(&ws.play.ring, ([^]f32)(ptr)[:take * ws.channels])
			// Only this thread reads, so a short read cannot happen; if it
			// did, the rest of the block must not be stale memory.
			if got < take * ws.channels {
				dst := ([^]f32)(ptr)[:take * ws.channels]
				for i in got ..< len(dst) do dst[i] = 0
			}
			if hr := ws.render->ReleaseBuffer(u32(take), 0); hr < 0 {
				set_state(&ws.play.state, wa_error(hr))
				return
			}
			wa_push(ws, u32(take), got)
			if ws.gap {
				ws.gap = false
				bump_i32(&ws.play.underruns)
			}
			ws.had_sound = true
		} else {
			// The silence the stream runs on between clips: a block left
			// unwritten plays whatever was last in it. `pending` drains
			// either way, since the device consuming frames retires a block.
			if hr := ws.render->GetBuffer(pass.take, &ptr); hr < 0 {
				set_state(&ws.play.state, wa_error(hr))
				return
			}
			if hr := ws.render->ReleaseBuffer(pass.take, AUDCLNT_BUFFERFLAGS_SILENT); hr < 0 {
				set_state(&ws.play.state, wa_error(hr))
				return
			}
			wa_push(ws, pass.take, 0)
			// The silence a stream runs on before the app's first write is
			// not a gap in anything: a clip written in one go reports none.
			if ws.had_sound do ws.gap = true
		}
	}
	ws.client->Stop()
}

// --- the capture thread ---

@(private = "file")
wa_cap_thread :: proc(t: ^thread.Thread) {
	ws := (^Wa_Stream)(t.data)
	win.CoInitializeEx(nil, win.COINIT.MULTITHREADED)
	defer win.CoUninitialize()
	task_index: win.DWORD = 0
	mm := AvSetMmThreadCharacteristicsW(win.utf8_to_wstring("Pro Audio"), &task_index)
	defer if mm != nil do AvRevertMmThreadCharacteristics(mm)

	if hr := ws.client->Start(); hr < 0 {
		set_state(&ws.cap.state, wa_error(hr))
		return
	}
	silence: [1024]f32
	for !wa_flag(&ws.stop) {
		win.WaitForSingleObject(ws.event, WA_WAIT_MS)
		if wa_flag(&ws.stop) do break
		for {
			packet: u32
			if hr := ws.capture->GetNextPacketSize(&packet); hr < 0 {
				set_state(&ws.cap.state, wa_error(hr))
				return
			}
			if packet == 0 do break
			ptr: [^]u8
			frames, flags: u32
			if hr := ws.capture->GetBuffer(&ptr, &frames, &flags, nil, nil); hr < 0 {
				set_state(&ws.cap.state, wa_error(hr))
				return
			}
			n := int(frames) * ws.channels
			if flags & AUDCLNT_BUFFERFLAGS_SILENT != 0 || ptr == nil {
				// The engine says "this much silence", and hands no memory
				// for it: a recording must still be the right length.
				left := n
				for left > 0 {
					take := min(left, len(silence))
					for i in 0 ..< take do silence[i] = 0
					ring_write_lossy(&ws.cap.ring, silence[:take])
					left -= take
				}
			} else if n > 0 {
				// Lossy on purpose: the thread must move on whether or not
				// the app has been reading; `capture_lost` reports the hole.
				ring_write_lossy(&ws.cap.ring, ([^]f32)(ptr)[:n])
			}
			if hr := ws.capture->ReleaseBuffer(frames); hr < 0 {
				set_state(&ws.cap.state, wa_error(hr))
				return
			}
		}
	}
	ws.client->Stop()
}

// --- the seam ---

@(private = "file")
wa_start :: proc(ws: ^Wa_Stream, fn: proc(^thread.Thread), allocator: runtime.Allocator) -> Error {
	ws.th = thread.create(fn)
	if ws.th == nil do return .Failed
	ws.th.data = ws
	ws.running = true
	thread.start(ws.th)
	return .None
}

@(private = "file")
wa_stop :: proc(ws: ^Wa_Stream) {
	if !ws.running do return
	wa_set(&ws.stop, true)
	if ws.event != nil do win.SetEvent(ws.event) // do not wait out the backstop
	thread.join(ws.th)
	thread.destroy(ws.th)
	ws.th = nil
	ws.running = false
}

@(private)
backend_capture_open :: proc(c_: ^Capture, latency_ms: int, device: string, allocator := context.allocator) -> Error {
	ws := new(Wa_Stream, allocator)
	if ws == nil do return .Failed
	ws.cap = c_
	ws.channels = c_.format.channels
	if err := wa_open_client(ws, c_.format, latency_ms, device, true); err != .None {
		wa_teardown(ws)
		free(ws, allocator)
		return err
	}
	if err := wa_start(ws, wa_cap_thread, allocator); err != .None {
		wa_teardown(ws)
		free(ws, allocator)
		return err
	}
	c_.be = ws
	return .None
}

@(private)
backend_capture_close :: proc(c_: ^Capture, allocator := context.allocator) {
	ws := (^Wa_Stream)(c_.be)
	if ws == nil do return
	wa_stop(ws)
	wa_teardown(ws)
	c_.be = nil
	free(ws, allocator)
}

@(private)
backend_playback_open :: proc(p: ^Playback, latency_ms: int, device: string, allocator := context.allocator) -> Error {
	ws := new(Wa_Stream, allocator)
	if ws == nil do return .Failed
	ws.play = p
	ws.channels = p.format.channels
	if err := wa_open_client(ws, p.format, latency_ms, device, false); err != .None {
		wa_teardown(ws)
		free(ws, allocator)
		return err
	}
	// Started here, on silence: starting the endpoint is the slow part, and
	// `playback_open` may block where `playback_write` must not.
	if err := wa_start(ws, wa_play_thread, allocator); err != .None {
		wa_teardown(ws)
		free(ws, allocator)
		return err
	}
	p.be = ws
	return .None
}

@(private)
backend_playback_close :: proc(p: ^Playback, allocator := context.allocator) {
	ws := (^Wa_Stream)(p.be)
	if ws == nil do return
	wa_stop(ws)
	wa_teardown(ws)
	p.be = nil
	free(ws, allocator)
}

// backend_playback_nudge wakes the stream's thread so a write is picked up
// within a pass rather than at the next endpoint event.
@(private)
backend_playback_nudge :: proc(p: ^Playback) {
	ws := (^Wa_Stream)(p.be)
	if ws == nil || ws.event == nil do return
	win.SetEvent(ws.event)
}

// backend_playback_flush asks the stream's thread to drop what the device
// holds. It is done there rather than here because `IAudioClient::Reset`
// must not race the thread's own GetBuffer/ReleaseBuffer pair.
@(private)
backend_playback_flush :: proc(p: ^Playback) {
	ws := (^Wa_Stream)(p.be)
	if ws == nil || !ws.running do return
	wa_set(&ws.flush, true)
	if ws.event != nil do win.SetEvent(ws.event)
	// Wait briefly for the thread to act, so `playback_queued` right after
	// a flush reads 0 as it does on the other two backends.
	for _ in 0 ..< 200 {
		if !wa_flag(&ws.flush) do break
		win.Sleep(1)
	}
}

@(private)
backend_playback_server_queued :: proc(p: ^Playback) -> int {
	ws := (^Wa_Stream)(p.be)
	if ws == nil do return 0
	return int(max(sync.atomic_load_explicit(&ws.pending, .Relaxed), 0))
}

// --- probes ---

probe_clock_ok :: proc(p: ^Playback) -> bool {
	ws := (^Wa_Stream)(p.be)
	return ws != nil && ws.running
}

probe_written :: proc(p: ^Playback) -> int {
	ws := (^Wa_Stream)(p.be)
	if ws == nil do return 0
	return int(sync.atomic_load_explicit(&ws.pending, .Relaxed))
}

probe_played :: proc(p: ^Playback) -> int {
	return 0 // the device reports what it still holds, not what it has played
}

probe_last_status :: proc() -> (call: string, status: int) {
	return "", 0 // WASAPI's failures are already named by `Error`
}

