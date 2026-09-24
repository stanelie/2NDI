# Syphon → NDI — architecture & design notes

A macOS app that takes one Syphon source (a Millumin or QLab output) and publishes it to
the network as NDI, in either **SpeedHQ** (full bandwidth) or **NDI HX** (H.264 / HEVC),
switchable while running.

The point of the app is the *comparison*, not just the bridge: it exists to work out what
a Raspberry Pi 5 decoder will have to cope with, tested in the meantime against a BirdDog
Play (which is known to struggle decoding 4K non-HX). So every figure it reports is
measured at the moment it happens rather than assumed, and the codec can be changed
without dropping the sender, so receivers stay connected across an A/B.

## The pipeline
## Inputs: Syphon or a camera

Everything after the input works on an `MTLTexture`, so a second kind of source only has
to produce one. `VideoInput` is that seam: `newFrameTexture()`, `isValid`, `stop()`.
`SyphonInput` already had exactly that shape and conforms through an empty extension.

`CameraInput` wraps `AVCaptureSession` with a `kCVPixelFormatType_32BGRA`,
Metal-compatible `AVCaptureVideoDataOutput`, and turns each buffer into a texture through a
`CVMetalTextureCache`. AVFoundation pushes frames where Syphon is pulled, so the newest
buffer is held and handed over when the pipeline asks; a frame arriving before the previous
was collected is overwritten and counted as a drop by the same path Syphon uses. Queueing
would inflate the latency this app exists to measure.

A third kind, `TestPatternInput`, is generated in-process and is always present in the
picker. It exists so the app can be exercised with nothing else running, and it is built to
answer four questions at a glance rather than to look like a test card:

| element | what it tells you |
|---|---|
| `TOP` / `BOTTOM` labels, static `2NDI` wordmark | which way up the frame is |
| hand sweeping a dial once per second | whether the stream is stuttering |
| white square blinking at 1 Hz | end-to-end delay: film two displays and count frames between the square lighting on each |
| coloured ground, colour bars | that there is video at all, and that the channels are right |
| size caption | the resolution actually being sent, not the generator's own |

The text deliberately does not rotate. Text at an arbitrary angle says nothing about which
way up a frame is, which is the one thing it is there for; motion is the *hand's* job.
The ground is never black, so "no signal" and "signal showing black" cannot be confused.

Only the hand, the blink and the caption are composited per frame — the background,
wordmark and dial are drawn once — so the generator stays far cheaper than the pipeline it
is meant to measure.

The caption is the one thing the generator cannot work out for itself: the output size is
decided downstream by the resolution setting, so the pipeline calls `describeOutput` with
the size it is about to send and the caption is re-rendered only when that changes. Drawing
it into the static frame instead left it claiming 1920 × 1080 over a downscaled picture —
a caption that is wrong is worse than none, since the whole point of the pattern is to be
believed at a glance.

**A CGImage-sourced frame needs a vertical flip; a texture-sourced one does not.**
`CIImage(cgImage:)` lands in CoreImage's y-up space while the renderer writes texture row 0
as its bottom, so the still frame arrives inverted. The texture-to-texture path used
everywhere else in this app is identity and must not be flipped. Same library, same
context, opposite requirement, decided by where the image came from.

`InputSource` flattens all three into one list for the picker — Syphon servers, then
cameras, then the generator last so it never displaces a real source as the default.

The preview has no on/off control. It was a toggle on the theory that it competed for the
GPU; measured, the pipeline's own copy is 1.2–1.5 ms a frame against a preview that draws
at 30 fps into a small drawable, and the contention that actually matters comes from other
applications. A switch that saves nothing is just another thing to explain.

### Selecting a camera kills a terminal-launched build

TCC terminates a process that touches the camera without a usage description, and it
attributes the request to the **responsible** application, not to the running binary.
Started from a terminal, this app inherits the launching application's
`__CFBundleIdentifier` — the shell's host, whatever that happens to be — and that
application has no reason to declare a camera string, so TCC kills us with
`__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__` even though our own Info.plist carries the key.
Launched by LaunchServices the same build is fine.

It is SIGABRT raised from TCC's own thread, so it cannot be caught. It has to be avoided,
which needs a reliable test for "am I running under my own identity":

- **`getppid() == 1` does not work.** A process backgrounded from a shell is orphaned and
  reparented to launchd, so it reads as 1 either way. This looked right and was measured
  wrong.
- **`__CFBundleIdentifier` does work.** Launched properly it is our own bundle id;
  launched from a terminal it is the host application's. Comparing it against
  `Bundle.main.bundleIdentifier` distinguishes the two exactly, and it is the same identity
  TCC is about to hold responsible — so it is testing the actual condition rather than a
  proxy for it.

Selecting a camera from a terminal-launched build now explains itself instead of dying.

Two consequences beyond the camera. Running `Contents/MacOS/2NDI` directly is still
the right way to get a real error out of a bundle Finder refuses to open — but it produces
a process running under someone else's identity, so it is not the right way to *use* the
app. And merely listing cameras is safe; only requesting access trips this.

## Two NDI libraries, chosen by dlopen

HX sending only exists in the Advanced SDK, whose development licence **silently stops
delivering the stream after 30 minutes** — the sender keeps reporting success while
receivers get nothing. So the base SDK is worth keeping available for long runs and for
show use.

Both dylibs export the same C symbols, so they cannot both be linked. `NDISender` binds
the entry points it needs with `dlsym` at launch (`RTLD_LOCAL`), which also makes "is HX
available?" a NULL check on `NDIlib_send_send_video_scatter` rather than a build flag.
Both dylibs ship in the bundle; the app menu picks one and relaunches.

Only one is loaded per process, deliberately: two NDI libraries in one process would mean
two independent discovery stacks.

## The HX wire format

Compressed frames go out through `NDIlib_send_send_video_scatter` as three blocks —
`NDIlib_compressed_packet_t`, then the bitstream, then the parameter set — in that order.
The bitstream is **Annex B** (start-code separated), which is what the SDK's own
`NDIlib_Send_H264` sample data is; VideoToolbox emits length-prefixed AVCC, so `Encoder`
converts, reading the prefix width out of the format description rather than assuming 4.

The parameter set (SPS/PPS, or VPS/SPS/PPS for HEVC) accompanies **every keyframe**: an
NDI receiver can join at any IDR and has no earlier bitstream to have learned it from.

`NDIlib_send_is_keyframe_required` is polled before each encode — that is how a receiver
that has just joined or lost sync asks for an IDR.

## Below 640 pixels wide, VideoToolbox stops using the hardware encoder

This cost the most time to find, and it is invisible: `VTCompressionSessionCreate`
succeeds, `VTCompressionSessionEncodeFrame` returns `noErr`, and then **no callback ever
arrives** in real time. What is actually happening is that VideoToolbox has quietly
substituted a software encoder which buffers heavily.

Measured with `Tools/encoder_test` on this Mac (Intel, macOS 12):

| size | encoder | per-frame latency |
|---|---|---|
| 494 × 340 | software | ~360 ms – 5.9 s |
| 600 × 360 | software | — |
| **640 × 96** | **hardware** | ~6 ms |
| 640 × 240, 640 × 360, 1920 × 1080, 3840 × 2160 | hardware | ~5–8 ms |

So the constraint is **width alone**, at 640. `Pipeline.outputSize` scales small sources
up to 640 wide for HX and says so in the stats panel. Upscaling is not free of meaning,
but a software encoder buffering for hundreds of milliseconds would make every latency
number in the panel worthless, which is worse.

The general lesson matches the one this project already learned elsewhere: don't trust an
API's success return as evidence the fast path was taken. `kVTCompressionPropertyKey_
UsingHardwareAcceleratedVideoEncoder` is read back at session creation and reported in the
stats panel as `hardware` / `SOFTWARE`, so a silent fallback is visible rather than
mysterious.

## The frame rate setting is a cap, clamped by the source

Asking for more frames than the source produces cannot conjure them. Left unclamped, the
setting reintroduced the exact mismatch that removing the old "declared frame rate" field
was meant to end: a 30 fps source with the setting at 60 sent 30 while telling receivers
60, because nothing was ever dropped — frames already arrived slower than the cap, so the
pacing check never fired.

`nominalFPS` is therefore the setting clamped by the measured source rate, and the popup
greys out rates the source cannot supply, since offering them only invites the question of
why choosing 60 yields 30.

**The clamp has to be applied where the value leaves the process.** The first attempt
updated `nominalFPS` correctly but `frameRateFraction` still read `config.fpsCap`, so every
internal readout — including the profiler's own column — showed the clamped rate while the
wire carried the unclamped one. It looked right in every easy place to check and was wrong
in the only place that mattered. `Tools/ndi_probe` reading the actual frame metadata is
what caught it, which is the same lesson as the preview: verify on the wire.

## Keyframe interval: what NDI actually asks for

Two independent mechanisms, and only one of them is the setting.

**On demand, and mandatory.** `NDIlib_send_is_keyframe_required` is polled before every
encode. The SDK documentation is unambiguous that this is not optional:

> when this function returns true then you should issue an I-Frame at the next possible
> time. This is required functionality for a good user experience and a compliant NDI HX
> source. The stream validation will verify that this practice is followed.

It returns true when a receiver connects, and when one has dropped a packet and can no
longer decode the rest of the GOP. Measured, a joining receiver gets its keyframe within
0.03 s regardless of the interval setting — so recovery does not depend on the periodic
timer at all.

**Periodic, and advisory.** NDI recommends *one to two seconds* for both H.264 and H.265,
and this is fixed at **1 s**, the responsive end of that. It used to be adjustable; the
control was removed because its whole useful range made no observable difference to
anything except bandwidth — recovery never ran through it.

Measured at 720p30, the cost of the choice is small because the on-demand path does the
real work:

| interval | keyframes/s | payload |
|---|---|---|
| 0.5 s | 2.12 | 3.68 Mbps |
| 1 s | 1.12 | 3.45 Mbps |
| 2 s | 0.62 | 3.38 Mbps |
| 5 s | 0.25 | 3.30 Mbps |

Going from 1 s to 5 s saves about 4% of bandwidth and leaves the stream outside NDI's
recommendation. That is not a trade worth exposing as a setting, so it is not one.

Two other pieces of the same guidance the encoder already follows: B-frames are disabled
(`AllowFrameReordering = false`), which the SDK recommends "with caution" against because
they add decoder latency; and the bit rate defaults to `NDIlib_send_get_target_bit_rate`,
which the SDK suggests users be allowed to scale between 0.1× and 2.0×.

## Keyframes, and a hypothesis that measurement killed

Reported symptom: switching SpeedHQ → H.264 mid-stream corrupted the receiver with garbage
lines that never recovered, and the keyframe interval seemed to do nothing. Measured, all
three parts of that are wrong about this sender.

`Tools/ndi_probe` now decodes NAL unit types out of the Annex B payload, so a keyframe can
be checked rather than counted:

```
keyframe 1 at 0.03 s: data 33193 B [6(SEI) 5(IDR)], extra 38 B [7(SPS) 8(PPS)]
```

Every flagged keyframe carries a real IDR and the parameter sets a decoder needs to start
from cold, and a joining receiver gets one within 0.03 s. The interval setting works too:
0.5 s → 2.12 keyframes/s, 1 s → 1.12, 5 s → 0.25, 10 s → 0.12.

For the codec switch, the probe reports when the FourCC changes at the receiver as well as
when keyframes arrive. Both happen at **the same instant** — 6.15 s in the run below — so
the first H.264 frame an established receiver is given is already an IDR with its parameter
sets. There is no window of undecodable frames.

An earlier reading of this claimed a 2.3 s corruption window and led to "fix" it by
bouncing the sender on every codec change. That was comparing the keyframe time against an
*estimated* switch time instead of against the measured format change. The bounce cost
about 3 s of reconnect downtime and 24 dropped frames, fixed nothing, and was reverted.
Switching codecs is this app's main job and stays instant.

What is left is receiver-side: a decoder that does not reinitialise when the FourCC changes
under an established connection will produce garbage no matter how correct the stream is.
Stopping and starting the stream forces it to renegotiate, which is the manual version of
the bounce, available when a particular receiver needs it without taxing every switch.

## Output resolution is built from the source, and only reduces

The list used to be fixed sizes — 3840 × 2160, 1920 × 1080 and so on — which did two
unwanted things. It could *upscale*, spending GPU time and bandwidth inventing detail that
is not in the source. And a fixed size whose aspect ratio differed from the source burned
letterbox bars into the stream: a 4:3 canvas sent at "1920 × 1080" went out with black down
both sides, permanently, in the encoded video.

It is now generated from whatever is actually connected. The top entry is the source's own
resolution, and below it only heights smaller than the source, each labelled with the size
it will really produce — a 1920 × 1080 source offers `720p — 1280 × 720`, a 4:3 source
offers `720p — 960 × 720`. Aspect is preserved, so nothing is ever upscaled and no bars
appear. Verified on the wire: native gives 1920 × 1080, 720 gives 1280 × 720, 540 gives
960 × 540.

The setting is stored as a height rather than a menu index, because the menu is rebuilt
whenever the source changes and an index would silently come to mean something else. The
chosen height is also held outside the popup, so a rebuild restores the same choice — or
the nearest one still offered, when the new source is too small for it.

The minimum-width clamp for the hardware encoder still applies on top: below 640 wide,
VideoToolbox silently drops to a software encoder, so a heavily reduced small source is
scaled back up to 640 and the stats panel says so.

## Diagnostics without controls

Two buttons were removed from the window. "Copy report" is gone entirely. "Save sent
frame" is gone as a button but not as a capability: `SYPHONNDI_SNAPSHOT=<path>` writes the
first frame that reaches the wire to that file. It is the tool for answering "what is
actually being sent" when the preview is in doubt — which has happened — and that is
something to reach for while diagnosing, not a control to carry in the interface.

## The icon is generated, not drawn

`Tools/icon` renders the wordmark at all ten sizes an `.icns` needs and folds them in with
`iconutil`. Generated rather than hand-made so the artwork is defined once and every size
stays consistent.

## One frame rate, derived rather than declared

There used to be two rate controls: a "declared frame rate" written into every NDI frame's
`frame_rate_N/D`, and a separate send-rate limit. Nothing kept them honest, so the app
could tell receivers 60 while delivering 44 — which is not a cosmetic lie. The declared
rate feeds three things: what receivers use to time playback, the encoder's
`ExpectedFrameRate` (and therefore its per-frame bit budget), and `MaxKeyFrameInterval`,
which is computed in *frames*. Declare 60 while sending 30 and a "1 second" keyframe
interval silently becomes two.

There is now one control, **Frame rate**, and the declaration is derived from it:

- Set to a rate → that is both the cap and what receivers are told.
- Set to None → the rate is measured from the source and declared, so it always matches
  what is actually being sent.

Two details that measurement forced:

**The snap list holds no fractional rates.** A measured rate is snapped to the nearest of
24, 25, 30, 48, 50, 60, 120. The broadcast fractions — 23.976, 29.97, 59.94 — sit 0.1% from
their integer neighbours, which is far inside the noise; including them meant a 27.4 fps
measurement declaring 29.97 on nothing but jitter. They are still available, but only by
choosing them explicitly, where they produce the exact `30000/1001` fraction rather than a
rounded one.

**A candidate must hold for 20 consecutive frames** before it is adopted, so a momentary
stall does not re-declare the stream. Adoption only rebuilds the encoder when the rate
moves by more than 25%, since the NDI declaration is per-frame metadata and free to change
while the encoder is not.

The stats panel prints the declaration next to the real output rate, and says so when the
two diverge — the same principle as everywhere else here: if the app knows something is
wrong, it should say so rather than let it be discovered downstream.

### Matching a stored rate needs a tolerance

Selecting the saved rate in the popup used `firstIndex(of:)` on a `Double`. A value that
has been through a 32-bit float comes back as 29.969999…, the exact match fails, and the
control silently falls back to "None" — changing both the send rate and the declaration
without a word. It now picks the nearest entry.

## The receiver count includes us

`NDIlib_send_get_no_connections` counts every receiver on the stream, and the delivery
monitor is one of them — it exists precisely by being a receiver of this app's own output.
Reporting the raw figure made a single attached Millumin read as two. Measured with nothing
else connected, the count sits at exactly 1, which is the monitor alone, so the panel now
subtracts it and says that it has.

## Rate limiting is not dropping

Lowering the frame rate setting used to *raise* the dropped counter, which reads as the
exact opposite of what is happening. Both paths called `noteDrop`, so frames skipped
deliberately to honour the cap were reported alongside frames the machine could not keep
up with. They are opposite conditions — one means it is struggling, the other means it is
obeying — and the panel now counts them separately: **dropped** and **rate limited**.

**The limiter also has to pace against a deadline, not against the last frame sent.**
Comparing the gap since the previous accepted frame means any scheduling jitter that puts
a frame a fraction under the interval costs a whole source frame, and the error compounds:
a 60 fps source capped to 30 delivered **24**. Running a deadline forward by the interval,
and accepting the frame nearest each deadline (tolerance of half a source interval), makes
it exact — measured 30.0, 25.0 and 15.0 fps out of a 60 fps source, with zero drops.

This is the same mistake the pattern generator made with `Thread.sleep`: pacing by "time
since the last one" accumulates error, pacing to an absolute deadline does not.

## An edit that silently did not apply

The capture depth was measured and set to 1. It shipped as 2 for weeks. A test loop had
left the file at `>= 2`, and the follow-up edit searched for `>= 1` — it matched nothing,
changed nothing, and reported nothing. Every build since carried the configuration the
measurement had rejected: 36 ms of latency became 56 ms.

A string substitution that finds no match is indistinguishable from one that was not needed
unless the result is checked. Verifying the *file* after editing it is not optional, and
neither is re-running the measurement that justified the change.

## The GPU copy is handed off, not waited on

`FramePool.copy` used to block on `waitUntilCompleted`, holding the capture queue for the
whole render. That is invisible on an idle machine — the render is 2.3 ms at 1080p — but
measured against a live Millumin output on the same GPU it was **14 ms**, against a 16.7 ms
budget at 60 fps, so most arriving frames were dropped while the thread sat waiting.

It now commits with `addCompletedHandler` and continues from there. The closure retains the
pooled frame, so the pool cannot recycle it early, and command buffers on one queue
complete in order, so frames stay in order.

**Still only one capture in flight.** Allowing two was measured, and it is worse:

| depth | H.264 out | H.264 latency | SpeedHQ out | SpeedHQ latency |
|---|---|---|---|---|
| 1 | 43.6 fps | 35.8 ms | 39.8 fps | 20.9 ms |
| 2 | 41.2 fps | 55.9 ms | 46.8 fps | 32.0 ms |

Two in flight buys SpeedHQ throughput and costs everything else, because the second frame
simply waits its turn. Against the original blocking code (44.2 fps, 44.0 ms) depth 1 keeps
the throughput and takes about 19% off the latency.

**GPU contention is the real limit, not the code.** The same copy costs 4.5 ms on the
SpeedHQ path and 14 ms on the H.264 path, because Quick Sync is using the same GPU. Add
Millumin decoding video to that and 1080p60 is simply not available on an Iris Plus. The
levers left are the ones outside the app: fewer things sharing the GPU, a lower output
resolution, or an honest 30 fps.

The delivery monitor is *not* one of those levers — measured with it on and off, throughput
was the same or slightly better with it on.

## Encoder measurements, and two traps

All measured on this machine's Intel Iris Plus by submitting frames as fast as
VideoToolbox will take them, with `UsingHardwareAcceleratedVideoEncoder` reported per run.

| codec | resolution | encoder | throughput |
|---|---|---|---|
| H.264 | 1920 × 1080 | hardware | 55.3 fps |
| H.264 | 3840 × 2160 | hardware | 26.6 fps |
| H.264 | 3840 × 2160 | **software** | **3.9 fps** |
| HEVC | 1920 × 1080 | hardware | 85.7 fps |
| HEVC | 3840 × 2160 | hardware | 37.4 fps |

Three things follow.

**4K60 is out of reach for H.264 on this class of GPU**, whatever the rest of the pipeline
does. The GPU copy is a second, independent limit — 6.2 ms per 4K frame here, ~25 ms on an
older machine, which alone caps that one near 40 fps. The pipeline drops rather than
queues, so this shows as a clean halving to 30 fps instead of growing latency.

**An idle CPU during encoding is correct, not a symptom.** The hardware encoder is a
fixed-function block; the CPU has nothing to do. Handing the work to the CPU instead is
seven times *slower* at 4K, which is why the software option exists only for diagnosis.
Conversely, an encode that pins the CPU means VideoToolbox has silently fallen back to
software — the stats panel prints `hardware` or `SOFTWARE` for exactly this.

**HEVC is faster than H.264 here at 4K** (37.4 vs 26.6 fps), because Intel's HEVC block is
the newer one. That is hardware-specific and will not hold everywhere.

### Latency

`kVTCompressionPropertyKey_MaxFrameDelayCount = 0` stops the encoder holding a lookahead
window. Measured at 1080p, mean encode latency **21.5 ms → 14.6 ms**.

The trap: setting `MaximizePowerEfficiency = false` alongside it, which sounds like it
should help latency, **tripled it to 45 ms**. Both properties were accepted without error,
so only an A/B revealed which one was responsible. `VTSessionSetProperty` now logs any
rejected property, because a silently ignored setting is the same failure shape this
project keeps running into.

## The source frame counter must not sit behind the drop check

`noteSourcePublished` is called the moment Syphon hands over a frame, before any decision
to process or drop it. It used to be called after, which meant the panel reported this
app's own throughput under the heading "source": a 60 fps Millumin output at 4K showed as
`source 30 fps` with `dropped 30/s`, and the two only added up to the truth if you thought
to add them. A statistic that silently reports something other than its label is worse than
no statistic.

## Aspect ratio is fitted, never stretched

A 4:3 composition sent at a 16:9 output size is letterboxed, and the source is composited
over opaque black so the bars are real pixels rather than transparency a receiver might
key through.

This was originally MPS, and it was wrong in a way worth recording, because the symptom
did not look like an off-by-one: **`MPSImageScale` places the image at
`clipRect.origin + scaleTransform.translate`**, so setting both — which looks like the
obvious thing to do — offsets it twice. Measured with `Tools/fit`, a 1024×768 source into
a 1920×1080 destination landed at column 480 instead of 240, and the `clipRect` then
clipped the right quarter of the picture away. On screen that reads as a black band down
the left and the right of the image missing, which is what it looked like from Millumin
(whose canvas is 1024×768). The offset belongs on the `clipRect` alone, which also stops
MPS writing transparent pixels over the bars.

## Orientation: Syphon cannot say which way up a source is

Millumin arrives vertically flipped; a camera and the built-in generator do not. This is
not a bug in any of them, and it cannot be detected.

The pattern is the publisher's graphics API. An OpenGL Syphon server stores its surface
bottom-up, which is OpenGL's convention; `SyphonMetalClient` hands back a texture sampled
top-down. Measured across three publishers:

| source | published via | arrives |
|---|---|---|
| `TestPatternInput` / `Tools/pattern` | Metal | correct |
| Camera | AVFoundation | correct |
| Millumin, Syphon "Simple Server" | OpenGL | **flipped** |

**There is nothing in the protocol to key off.** Dumping the complete server description
dictionary from an OpenGL publisher and a Metal one gives structurally identical results —
both advertise only `SyphonSurfaceType = SyphonSurfaceTypeIOSurface`, and the only
differences are the app name, the UUID and an icon. A consumer cannot know.

So it stays a setting, but not one to be set repeatedly: the choice is **remembered per
source**, keyed on the publishing *application* rather than the Syphon server UUID, because
those UUIDs are regenerated every run while the application's behaviour is what stays
constant. Set it once for Millumin and once for a camera, and switching between them is
automatic afterwards.

The remembered value has to be applied **when the selection changes, before anything can
start streaming**. Applying it after `refreshSources` looked equivalent and was not:
autostart had already begun with the previous source's orientation and recorded it against
the new source, corrupting the very memory it was meant to restore.

## NDI is top-down

Established from the SDK's own code rather than recollection, and kept in `Tools/sdkref`:
`NDIlib_Send_PNG` decodes a PNG with lodepng and assigns the buffer straight to `p_data`,
and `NDIlib_Recv_PNG` hands `p_data` straight back to `lodepng_encode_file`. Neither flips
anything, and PNG scanlines are unambiguously top-first, so **`p_data` row 0 is the top of
the picture**. That receiver is the tiebreaker whenever something downstream disagrees
about which way up a frame is.

Verified against this app, with Millumin (a vertically flipped source) as input:

| Image orientation | what NDIlib_Recv_PNG sees on the wire |
|---|---|
| As received | upside down |
| Flip vertical | correct |

## A preview is not evidence

Millumin's NDI input was briefly, and wrongly, blamed for a flip. The real cause was in
this app, and the way it hid is worth recording because it defeats the obvious check.

**CoreImage renders into a `CAMetalLayer` drawable vertically flipped, but into an
ordinary or IOSurface-backed texture the right way up.** Measured across all four
backing combinations: plain→plain, plain→IOSurface, IOSurface→plain and
IOSurface→IOSurface are all identity; only the drawable flips. The preview therefore
inverted every frame, which exactly cancelled the source's own flip — so with the
*wrong* orientation setting the picture on screen looked right while the wire went out
upside down, and with the *right* setting the preview would have looked wrong.

That also made the earlier diagnosis wrong in a specific, avoidable way: the wire was
checked with the flip enabled while the running app had it disabled, so two different
states were compared and a receiver got the blame.

Two things follow:

- The preview renders into an offscreen texture and is then **blitted** to the drawable.
  A blit is a memory copy and cannot reorder rows, so it does not matter whether
  CoreImage's drawable behaviour is stable or version-specific.
- **Save sent frame** writes the exact texture NDI reads to a PNG. When orientation or
  framing is in question, that file is the evidence and the preview is not.

## The frame renderer is CoreImage, not MPS

Two constraints forced this, both measured rather than assumed:

- **MPS cannot flip.** `MPSScaleTransform` with a negative scale does not mirror, it
  produces an all-zero image.
- **There is no Metal compiler here.** `xcrun -sdk macosx metal` does not exist under
  Command Line Tools, so writing a shader to do it was not an option.

CoreImage does orientation, scale and letterbox composite in one pass, and benchmarked at
the same cost as the MPS path it replaced — 1.5 ms vs 1.9 ms at 1024×768, 1.8 vs 1.7 at
HD, 4.3 vs 4.1 at 4K — because both are dominated by the command-buffer round trip rather
than the filter. It also removed a real footgun: `MPSImageScale.scaleTransform` keeps the
pointer it is given rather than copying it, so the transform had to be kept alive in a
manual allocation or it dangled.

The working colour space is disabled (`.workingColorSpace: NSNull()`), because this is a
passthrough and any conversion would shift the pixels being measured. `Tools/fit` checks
that the marker colours come out bit-exact.

## The library follows the codec

Both dylibs export the same C symbols, so only one can be loaded per process and changing
library means a new process. That is hidden rather than exposed: selecting an HX codec
switches to the Advanced SDK by itself, carrying the settings and the running stream across
a relaunch. `resumeOnLaunch` is a one-shot flag the old instance leaves behind, read into
memory at launch and spent only once the source has actually been found — the first source
refresh happens before the Syphon directory has populated, so clearing it there loses the
resume entirely.

**Selecting SpeedHQ deliberately does not switch back to base.** The Advanced library sends
SpeedHQ perfectly well, and forcing a relaunch on the way back would mean restarting the
app at every step of an A/B comparison, which is the main thing this tool exists for. Base
stays an explicit choice in the menu, for long SpeedHQ runs that must outlast the trial.

The backend is also derived from the *saved codec* at launch, not only from the saved
library preference. A session saved on HX with base preferred would otherwise come back on
the base library, where `NDIlib_send_send_video_scatter` does not exist and every
compressed send silently does nothing. Verified: codec HX with base preferred still puts
`H264` on the wire; SpeedHQ puts `SHQ2` on either library.

## Nothing inside the sender reveals that the stream has died

The Advanced SDK's development licence stops delivering after 30 minutes. The dylib
contains a sentence saying so, so the obvious design is to watch the library's output for
it, and the first version of this feature did. **Every sender-side signal was measured and
every one of them is useless.**

Measured with `Tools/soak` sending H.264 HX and `Tools/ndi_watch` holding a receiver open,
first against the stock library over a full 30 minutes and again against a library patched
to expire in seconds:

| signal | at expiry |
|---|---|
| frames delivered to a receiver | ~1610/min, then **0** — dead on the mark |
| the notice on stdout/stderr | never printed |
| the notice in the unified log | never printed |
| `NDIlib_send_get_no_connections` | **still reports 1 receiver**, for minutes afterwards |
| return values from the send calls | unchanged, no error |

So a sender cannot know. The failure is completely silent from inside the process, and any
warning built on elapsed time is a guess about the library's timeout — wrong the moment the
timeout differs, which is exactly what a patched or differently-licensed library does.

**The app therefore receives its own output.** `NDIDeliveryMonitor` finds this app's own
source, attaches a receiver in compressed passthrough mode — frames counted, never decoded,
so the cost is a loopback copy rather than a second codec — and counts what actually
arrives. When the app is sending and its own receiver has been given nothing for five
seconds, the stream is certainly dead, and the banner says so. Five seconds is well past
the gap a codec change or a startup produces, and still fast enough to catch live.

The banner states only what is known: nothing is being delivered. It names the trial as the
*likely* cause when the Advanced backend is loaded, rather than asserting it.

This has a cost worth being honest about: the monitor is itself a receiver, so it keeps the
trial clock running even when nobody else is watching. **Verify delivery** turns it off for
anyone who would rather have the idle time.

Two further things that run measured this way and are easy to get wrong:

- **The clock only runs when a receiver is attached.** A 35-minute run with `0 receiver(s)`
  never expired at all. A source nobody is watching is not a stream, so a soak without a
  receiver "passes" while proving nothing.
- **The codec matters.** The limit is on compressed passthrough, so a soak sending
  uncompressed frames tests the wrong path.

Verified both ways: against a library patched to expire early the banner appears seconds
after delivery stops; against the stock library it stays silent for the whole run. A
detector that only ever fires is no better than one that never does, so both halves matter.

## The banner must not be a stack view

Worth recording because it was introduced and caught twice. Putting the banner and the
rest of the window in a vertical `NSStackView` sized the body by its fitting height
instead of the window's, the preview collapsed to zero height, and `MTKView` then logged
`nextDrawable returning nil because allocation failed` thirty times a second — with the
controls shoved sideways and no preview at all. Raising the body's hugging priority did
not fix it.

The banner is now an ordinary subview pinned to the top with a zero-height constraint that
is deactivated when it appears. `grep -c nextDrawable` on the app's log is the quick check
that the layout is still sound.

## The vendored Syphon.framework

`Frameworks/Syphon.framework` is **Syphon 5 with Metal support, taken from Millumin 5**
(Syphon is BSD-licensed). This matters because several Syphon 5 builds on this machine —
including the one vendored in the EpocCam-receiver project — ship the Syphon 5 *headers*,
which declare `SyphonMetalClient`, while the binary contains **only the OpenGL classes**.
The header is not evidence the class exists; check with
`nm -arch x86_64 … | grep -F 'OBJC_CLASS_$_SyphonMetal'` (and note that `$` inside double
quotes makes grep treat it as an end-anchor, which produces a convincing false negative).

Two consequences for the build:

- `Versions/A/Resources/default.metallib` must come across too, or `SyphonMetalServer`
  fails at runtime with `vertexFunction must not be nil`.
- The binary came out of another app's signed bundle, so its signature no longer matches
  this one and dyld refuses to load it until re-signed. `build.sh` ad-hoc signs it.

Building Syphon from source would be tidier, but needs Xcode; this machine has Command
Line Tools only, which is also why the whole project builds with `clang` + `swiftc` from
a shell script rather than an Xcode project.

## Copying the app to another Mac

The bundle is ad-hoc signed and its signature seals everything under `Contents/`. Two
things break that in transit, and Gatekeeper reports both the same useless way — *"the
application can't be opened"* — with no indication of the cause:

- **`.DS_Store` inside the bundle.** The vendored Syphon framework arrived with three of
  them and codesign sealed one into `CodeResources`. Finder rewrites `.DS_Store` as soon as
  anyone browses the folder on the other machine, and the seal is then broken. `build.sh`
  deletes them before signing.
- **Lost symlinks.** `Syphon.framework` is held together by four (`Versions/Current`, and
  `Headers`/`Resources`/`Syphon` pointing through it). Finder's Compress and most cloud
  syncs flatten or drop them, which invalidates the signature. `package.sh` uses
  `ditto -c -k --sequesterRsrc --keepParent`, which preserves them, and verifies the
  archive round-trips.

On the receiving Mac the app also carries the quarantine flag, so `xattr -cr` on it before
first launch. When it still refuses, run `Contents/MacOS/2NDI` from a terminal: dyld
and the app print the actual reason, which Finder never shows.

Note for a machine without Metal — an old one under OpenCore Legacy Patcher, say — the app
does start and then reports "No Metal device is available on this Mac" and quits. That is a
different failure from "can't be opened", and tells you the hardware, not the bundle, is
the problem.

## Running it as a service

Closing the window leaves the app running as a menu-bar item (the activation policy drops
to `.accessory`), so it can sit on a show machine once configured. **Start automatically
on launch** reconnects to the saved source as soon as it appears, which also covers the
host app being launched after this one. `SYPHONNDI_SOURCE=<substring>` overrides the saved
source by name for a scripted or login-item launch — Syphon UUIDs are per-run, so a saved
UUID does not survive the source app restarting.

## Tools

None of these are part of the app; they exist to check it.

- `Tools/ndi_probe` — lists NDI sources, then receives from one and reports resolution,
  rate, FourCC and the true payload bitrate. It receives in **compressed passthrough**
  mode, so the FourCC reported is the sender's own format rather than whatever the
  receiver decoded it into. Given a PNG path it instead decodes and saves the first frame,
  which is how orientation and framing are checked at the far end of the chain rather than
  in the app's own preview. Timing is wall-clock; an earlier version counted a fixed
  interval per capture call and understated the frame rate by 5×.
- `Tools/fit/fit_test` — pushes a frame with coloured edge markers (red left, blue right,
  green top, yellow bottom) through the real `FramePool`, then reports the exact column
  and row span of the result against the expected one, which edge each marker landed on,
  and how many pixels came out non-opaque. This is what caught the double offset and what
  verifies each orientation does what its name says.
- `Tools/dump/syphon_dump` — writes one frame straight off a Syphon source to PNG, before
  the app touches it, which is the only way to establish which way up a given server
  publishes.
- `Tools/encoder_test` — drives `Encoder` with synthetic frames, in `cpu` mode (plain
  CVPixelBuffers) or `metal` mode (the app's real `FramePool` path), which is what
  separated "the encoder is broken" from "the encoder is in software".
- `Tools/pattern/syphon_pattern` — a steady Syphon source. It sleeps to an **absolute
  deadline**; sleeping for "whatever is left of this frame" accumulates the scheduler's
  overshoot and pinned the tool at 52 fps whatever the resolution, which silently capped
  every measurement taken against it. It also cycles pre-built frames rather than
  regenerating one per frame, for the same reason. The
  stock **Simple Server publishes only when its window redraws** — two frames in eight
  seconds here — which is useless for measuring a sustained rate. Two things about it are
  easy to get wrong: the publish loop must run off the main thread with `RunLoop.main.run()`
  live, because Syphon announces and answers directory queries through distributed
  notifications (without a run loop the server exists but no client can ever discover it);
  and the pattern is generated once and scrolled, because regenerating it per frame in
  Swift could not keep up with 60 fps at HD and made the tool the bottleneck.
- `Tools/soak [minutes] [h264|speedhq]` — holds an Advanced SDK stream open past 30
  minutes. Must be run as `h264`, and needs `Tools/ndi_watch` attached, or the clock never
  starts. Still uses `LibraryLog`, which the app itself no longer does.
- `Tools/ndi_watch <name> [minutes]` — stays connected and reports frames per minute,
  flagging the minute delivery dies. This is what actually measures the expiry, since the
  library says nothing.
- `Tools/list/syphon_list` — prints the Syphon server directory, to separate "the app
  can't see it" from "nothing is publishing".
- `Tools/sdkref` — the NDI SDK's own PNG sender and receiver, built as shipped. They are
  the tiebreaker on row order, because they carry no assumption of this project's. The
  receiver differs by one line, looping until a video frame arrives rather than giving up
  when the first capture returns a status change; the `lodepng_encode_file` call that
  defines row order is untouched.

## Measured end to end

Against `syphon_pattern` at 1280 × 720 / ~46 fps, receiving with `ndi_probe`:

| codec | received | wire bitrate |
|---|---|---|
| SpeedHQ | 45.9 fps | 30.67 Mbps |
| H.264 HX | 44.7 fps | 1.95 Mbps |
| HEVC HX | 46.1 fps | 2.23 Mbps |

No frames lost against the source rate in any mode. SpeedHQ's bitrate is measured at the
receiver; the sender cannot observe it, because NDI does that encode internally — which is
why the stats panel reports the SDK's target figure for SpeedHQ and a measured one for HX.
