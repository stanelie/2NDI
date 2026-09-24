# Working notes

How this project is worked on, as distinct from how it is built. `ARCHITECTURE.md` records
what the code does and why; this records the habits that produced it, so a fresh session on
another machine starts where the last one left off rather than relearning them.

## Measure; do not assert

Confident performance explanations on this project have a poor record. Several that sounded
entirely reasonable were wrong, and only measurement settled them:

- A rate limiter that "obviously" delivered the configured rate was delivering 24 fps under
  a 30 fps cap, because it compared the gap since the last sent frame and jitter compounded.
- A frame generator was capped at 52 fps regardless of resolution — `Thread.sleep(for:)`
  accumulating scheduler overshoot — which silently limited *every measurement taken against
  it* until it was checked directly.
- A depth-1 in-flight gate was assumed to be the cause of a proxy stream running 15% under
  its declared rate. It was not; the shortfall was connection latency before the first
  keyframe, and the frames were all arriving. The depth change was reverted.
- The wire rate and every on-screen readout disagreed for weeks, because
  `frameRateFraction()` read the unclamped config value. Nothing in the app could show
  this. `ndi_probe` reading real frame metadata was the only thing that could.

State a hypothesis as a hypothesis, run the A/B, report the delta. When a change is a sound
improvement but not demonstrated to be the cause of anything, say exactly that rather than
calling the bug fixed.

## Trust the wire, not the app

The app's own preview and statistics have twice agreed with each other and both been wrong.
An orientation bug survived because the preview applied a second flip that cancelled the
first, making an incorrect setting look correct. Check the far end — `ndi_probe`,
`syphon_dump`, an actual receiver — before concluding anything about what is being sent.

## Verification has an owner

The hardware lives with the person running this project: the Macs, Millumin, QLab, the
BirdDog Play. They test changes themselves. Verify the specific thing that changed, report
it, and stop; chaining further checks on unrelated state is not thoroughness here, it is
delay. When they say something works, that is the end of it.

The exception is *cause*. Reporting a cause still requires having measured it.

## Build scripts fail silently

Several wrong conclusions on this project came from running a stale binary. Helper build
scripts were invoked with output redirected to `/dev/null`, a compile error went unseen,
and the previous binary ran instead — more than once, over weeks. Never redirect a build's
stderr away. Check that a build succeeded before trusting what it produced.

The same shape has appeared in other forms: an edit whose search string matched nothing and
reported nothing, shipping the wrong value for weeks; `grep "OBJC_CLASS_$_Syphon"` where the
`$` inside double quotes became an end-anchor and produced a confident false negative
(`grep -F`); and `cmp` after `codesign`, which is meaningless because signing rewrites the
file.

## Small conventions

- Comments explain *why*, especially where the obvious implementation was tried and failed.
  Much of this codebase looks slightly odd for reasons that cost real time to discover.
- Declared frame rate always matches what is actually sent. To change the rate, change the
  rate limit. A statistic that reports something other than its label is worse than no
  statistic.
- Output resolution is a cap, never an upscale. Frame rate cannot exceed the source.
- Rate-limited frames are counted separately from dropped frames. Conflating them made
  *lowering* the frame rate *raise* the dropped count, which reads as the opposite of what
  is happening.
