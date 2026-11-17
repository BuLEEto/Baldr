# baldr:audio — PCM in, PCM out

`import "baldr:audio"`. A **sibling** of the toolkit, not part of it: a
toolkit that draws should not also own a connection to a sound server, and
an app that never makes a noise should not pay for one. Nothing in `audio`
imports `baldr`, and nothing in `baldr` imports `audio`.

Deliberately scoped to **device I/O only** — enough for voice notes and
calls.

## What it is

- Open the default microphone, read interleaved f32, close.
- Open the default output, write interleaved f32, ask how much is still to
  be heard, stop early, close.
- One capture and one playback stream is the tested case.
- Errors are values an app can show a person.

## What it is not

**There are no codecs here and there will not be.** Opus, MP3, WAV headers,
resampling and mixing belong to the app, which already links whatever it
decodes with. The seam is deliberately at raw f32: a chat app decodes a
voice note with libopus and hands the samples over.

No mixing either — one stream at a time. An app that needs two sounds at
once mixes them itself, which is an add and a clamp.

## The shape of it

```odin
c: audio.Capture
if err := audio.capture_open(&c); err != .None {
    show(audio.error_text(err))
    return
}
defer audio.capture_close(&c)
for recording {                       // once a frame is often enough
    n, err := audio.capture_read(&c, buf[:])
    if err != .None do break          // the server went away
    append(&note, ..buf[:n])
}
```

`examples/30_audio` is the whole loop in a window: record, a level meter,
play back, and the play button putting itself away when the note ends.

**Neither `capture_read` nor `playback_write` ever blocks**, and neither
waits on a lock the audio thread could be holding — they meet the server's
thread at a lock-free SPSC ring (`ring.odin`). Only `capture_open` and
`playback_open` block, for as long as the server takes to answer, and they
give up after two seconds rather than hang the app. A write does take the
mainloop lock for a memcpy, uncontended; measured worst case over a
one-second clip was 0.10 ms, and a read was 0.008 ms.

Counts are **samples**, matching `len()` of the `[]f32` you pass, not
frames: for stereo that is two per frame. `samples_for_ms` and
`ms_for_samples` convert.

## Platforms

| | state |
|---|---|
| Linux | **done** — PulseAudio's client library through `core:dynlib` |
| macOS | **done** — CoreAudio's AudioQueue (AudioToolbox) |
| Windows | **done** — WASAPI shared mode, event driven |

Everywhere else `capture_open` and `playback_open` return `.Unsupported`
and an app shows the same message it would on a machine with no sound card.

**What each backend's hardware actually proved.** Each of the three boxes is
missing one half of a sound card, which between them covers both halves —
but it is worth writing down which, because "it compiles on Windows" is not
what this table claims:

| | capture | playback |
|---|---|---|
| Linux (this desktop) | measured, tone analysed | measured, tone analysed |
| macOS (M4 Mac mini) | **no input device exists**: `.No_Device`, correctly | measured |
| Windows (the build box) | measured | **no render endpoint exists**: `.No_Device`, correctly |

So the CoreAudio *input callback* and the WASAPI *render thread* have never
run on real hardware. Each is covered as far as it can be without one: on
macOS `spikes/ca_probe` prints the raw `OSStatus` so that the right answer
cannot be confused with a wrong binding (`AudioQueueNewInput` succeeds;
`AudioQueueStart` returns `kAudioQueueErr_InvalidDevice`), and on Windows
the render thread's bookkeeping is unit-tested in
`audio/wasapi_test_windows.odin`, which `tools/win-sync.sh test` runs.

**This is a job, not just a limitation.** The run to do on the first Mac or
Windows desktop with both halves present is
`./build.sh spike audio_check run`; the numbers it prints are the ones that
answer it.

### Why PulseAudio and not PipeWire

The request named both; one implementation reaches both. Every PipeWire
desktop runs `pipewire-pulse` — without it Firefox, Chromium and every
other existing application would lose sound — so the Pulse client protocol
is the one interface present on a PulseAudio box *and* a PipeWire box.

Against that, `pw_stream_connect` wants its format as an SPA POD, a binary
structure built in C by macro (`spa_format_audio_raw_build`). From Odin
that means hand-assembling the bytes and matching half a dozen more
structs' layouts: several hundred lines of ABI to get exactly right, for a
stream that will not sound different. `pa_sample_spec` is three fields.

If a measurement ever shows the Pulse path costing latency a voice note can
hear, a native PipeWire backend drops in behind the same seam
(`backend.odin`). Until then this is the smaller surface and the wider
reach.

**ALSA was the third candidate and is the wrong one.** `default` goes
through whichever plugin is installed, and on a PipeWire box without
`pipewire-alsa` it takes the card exclusively — the rest of the desktop
goes quiet, or the open fails because PipeWire already holds it.

## Two traps, both worth knowing

Both are recorded in the code at the place they bite, and both are the same
lesson: **a stream that opens is not a stream that is working.**

**An enum copied in part is an enum copied wrong.** The format constants
were first derived from a grep that filtered `sample.h` down to the
interesting names — which quietly dropped `PA_SAMPLE_ALAW` and
`PA_SAMPLE_ULAW` and shifted every index after them by two. The package
then asked the server for S16LE (3) while reading the bytes as f32 (5).
Nothing reports that: the stream opens, the server converts happily, and
the samples arrive as NaNs and denormals that read exactly like a
byte-order bug. `Pa_Sample_Format` is now written out whole, and both open
paths **check what was negotiated** rather than assume it, so the same
mistake would be one `.Bad_Format` instead of an afternoon.

**`pa_stream_get_latency` is the wrong number for "how much is left".** It
reports the whole pipeline's latency — the server's buffer *plus* the
sink's — so it never reaches zero while the stream is open: a flushed
stream with nothing left to play still reported 382 samples (7 ms) of it,
and `playback_drained` would have been false for ever. Written-minus-played
from `pa_stream_get_time` is exact, **except that the stream's clock stops
when the server runs dry** — which is the end of every clip. Measured: a
one-second clip tracked down from 1000 ms to 26 ms and then froze there,
1249 samples short, for as long as the stream stayed open. So an underflow
with nothing written since is taken as "the server has handed on
everything", which is the answer the clock cannot give. `playback_drained`
then fires within a few ms of the clip's own length (measured −8 ms: the
sink's own buffer, which no clock here can see past).

## macOS

One `AudioQueue` per stream, from AudioToolbox, linked as a framework.

**Why AudioQueue and not AUHAL.** An AudioUnit render callback is the
lower-latency seam and the one a synthesiser wants. This package exists for
voice notes, where 60 ms is luxurious and *not resampling* matters more:
AudioQueue converts to the device's own rate and channel count itself, so
`capture_open(48 kHz mono)` works on a 44.1 kHz stereo interface without
this package owning a resampler — the same reason the Linux backend leans
on PulseAudio. It also runs its own thread when the callback run loop is
nil, which is exactly the "a backend owns one thread at most" the seam
asks for.

**No clock, and so no clock to stop.** `playback_queued` is counted, not
timed: each buffer records how many real samples went into it, and the
callback subtracts that when the buffer comes back having been played. The
Linux backend had to work around `pa_stream_get_time` freezing at an
underflow — the end of every clip — and there is nothing like it here.
A buffer is enqueued **short** rather than padded with silence, so the
count is the real number of samples still to be heard.

**The queue runs on silence from the moment it is open.** Starting it costs
the device's spin-up — **73 ms, measured on an M4 Mac mini** — and the
first shape of this deferred the start to the first write, which put all
73 ms inside `playback_write`. A write must never block, so the start
moved to `playback_open`, which is documented to. The cost is that the
app's first samples wait behind up to `latency_ms` of already-queued
silence: a clip drains about 70 ms after its own length at the default 60.
A `had_sound` flag keeps that leading silence from being counted as an
underrun.

**`AudioQueueReset` alone looks right and is not.** It discards the
enqueued buffers and calls the output callback for each — but an enqueue
from inside that callback is refused with
`kAudioQueueErr_EnqueueDuringReset`, so the buffers come back to the app's
side, nothing re-enqueues them, and the queue starves for ever. Measured:
**every `playback_write` after a flush returned 0 samples**, because the
callback had latched the stream as failed and the queue was deaf. `flush`
now stops the queue immediately — which is synchronous, so no callback is
in flight — refills the buffers and starts it again. That costs **25 ms**
on the Mac against 0 on Linux, which is the price of a "stop" button
there. The lesson is the Linux one again: **a stream that opens is not a
stream that is working**, and now also *a flush that empties is not a
flush the stream survives* — so `spikes/audio_check` writes a second clip
after the flush, because "queued went to zero" is true of a stream that
will never play again.

Last run on an M4 Mac, macOS 26.3.1:

```
capture_open: No_Device (no audio device)
playback open: 48000 Hz, 1 channel(s)
wrote 48000 of 48000 samples (1.00 s of audio)
worst playback_write: 0.019 ms
drained after 1.071 s — +71 ms against the clip's own length
underruns mid-clip: 0
flush: 48000 samples queued -> 0 (1000 ms -> 0 ms), the call itself took 25.1 ms
after the flush: wrote 12000 samples (0.25 s) and they drained in 0.295 s
```

**The capture path is unverified on hardware.** That machine has two
output devices and *no input device at all*, so `capture_open` correctly
returns `.No_Device` — `AudioQueueNewInput` succeeds and `AudioQueueStart`
returns `kAudioQueueErr_InvalidDevice` (-66680), which `spikes/ca_probe`
prints raw so that the right answer cannot be confused with a wrong
binding. The format, the buffers and the error mapping are therefore
exercised; the input callback itself is not, and will not be until it runs
on a Mac with a microphone attached.

## Windows

One WASAPI shared-mode stream per `Capture` or `Playback`, each with a
thread of its own waiting on the endpoint's event.

**Shared mode, not exclusive.** Exclusive mode is lower latency and takes
the device away from everything else on the machine, including the
notification that just arrived. A voice note is not worth that.

**`AUTOCONVERTPCM` is why there is no resampler here either.** The
endpoint's mix format is whatever the person's sound settings say —
commonly 44.1 kHz stereo — and this package promises the rate it was asked
for. `AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM` with `SRC_DEFAULT_QUALITY` has
the audio engine resample and re-channel, as PulseAudio and AudioQueue do
on the other two.

**`playback_queued` is counted, not timed.** WASAPI offers
`GetCurrentPadding`, which is *frames* in the device buffer — and a
playback stream runs on silence between clips, so padding alone would have
`playback_queued` reporting sound that is not there and
`playback_drained` never turning true. The thread records each block it
hands over (the cumulative frame it ends at, and how many of the app's own
samples were in it) and retires them as the device consumes frames. A
block half played is still counted, so the number is high by at most one
block. That bookkeeping is the one part of this backend that needs no
device, and since no build box has a render endpoint it is where the
testing goes: nine tests in `audio/wasapi_test_windows.odin`, run by
`tools/win-sync.sh test`. The per-pass decision is a pure `wa_plan`, so the
last of them plays a whole clip out against a simulated device and asserts
what an app actually depends on — the count is never zero while there is
audio left, and reaches exactly zero within a buffer of the end. A chat app
puts its "note finished, put the Play button back" straight on
`playback_queued == 0`, and counting a silent block as sound (the mutation
that models getting this wrong) leaves 1440 samples queued for ever, which
is a play button that never comes back.

The silence those blocks carry is for the *sound*, not the count: a block
left unwritten is played as whatever was last in it. `pending` drains
either way, because it is the device consuming frames that retires a block,
not the thread writing more.

**The thread does every COM call after open.** `nudge` sets the endpoint
event, and `flush` sets a flag and waits for the thread to act, because
`IAudioClient::Reset` must not race the thread's own
`GetBuffer`/`ReleaseBuffer` pair — and refuses outright unless the stream
is stopped first.

`AvSetMmThreadCharacteristicsW("Pro Audio")` puts the thread on the
Multimedia Class Scheduler. Without it a busy desktop glitches a stream
that is otherwise perfectly fed.

Last run on the Windows box (its only endpoint is a microphone):

```
capture  open: 48000 Hz, 1 channel(s)
silence floor: 18240 samples, rms 0.14824, worst read 0.010 ms (must not block)
floor range: -0.7444 .. +0.2642
playback_open: No_Device (no audio device)
captured 18240 samples with no output to play through; 0 lost
```

The floor is not quiet because that machine's line input is unconnected and
picking up hum; what matters is that it is **in [-1, 1]**, which is the
check that catches a format being read as something it is not. The spike
prints that range for exactly that reason — it is the mistake that cost the
Linux backend an afternoon, and a sample rate or a channel count cannot
hide it.

## Testing it

`./build.sh test` runs the ring's tests, including one that crosses two
real threads with 200 000 samples and checks every one arrives exactly once
and in order. A ring only ever exercised from one thread proves nothing
about the memory ordering, and that kind of mistake works fine on a quiet
machine for a month.

**The backend needs a device, so it cannot be gated headlessly.** Its gate
is `./build.sh spike audio_check run`, which plays a 440 Hz tone and
records it back — a real loop through the sound server on any box whose
default source is the default sink's monitor — and measures rather than
asserting "no error": the silence floor before anything plays, the energy
at 440 Hz against 220 and 880 once it does, what a read costs, how long
`playback_queued` says is left against a clock, and what a flush drops.

Last run on this box (PipeWire 1.4.2 through `pipewire-pulse`):

```
silence floor: 19200 samples, rms 0.03909, worst read 0.008 ms
wrote 48000 of 48000 samples (1.00 s of audio)
worst playback_write: 0.103 ms
drained after 0.992 s — -8 ms against the clip's own length
underruns mid-clip: 0
captured 48960 samples (1.02 s), 0 lost while it was being read
energy at 440 Hz: 0.124972   220 Hz: 0.001107   880 Hz: 0.000133
flush: 49246 samples queued -> 0 (1025 ms -> 0 ms)
```

`probe_clock_ok`, `probe_written` and `probe_played` are there for the
spike and for a bug report — an app has `playback_queued` and
`playback_drained`. One line of them found the clock-stops-at-underflow
behaviour above.
