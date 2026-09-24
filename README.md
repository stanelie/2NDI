# 2NDI

A macOS app that takes one **Syphon** source (a Millumin or QLab output), a **camera**, or
a **generated test pattern**, and publishes it to the network as **NDI** — either SpeedHQ
(full bandwidth) or NDI HX (H.264 / HEVC), switchable while running without dropping the
sender.

It is a measurement instrument, not just a bridge. It exists to work out what a Raspberry
Pi 5 decoder will have to cope with, tested in the meantime against a BirdDog Play. Every
figure it reports is measured at the moment it happens rather than assumed.

**Read [`ARCHITECTURE.md`](ARCHITECTURE.md) before changing anything.** It is long, and
that is the point: it records what was measured, what turned out to be wrong, and why each
non-obvious decision is the way it is. Most of the traps in this codebase are ones that
look like working code.

[`docs/WORKING-NOTES.md`](docs/WORKING-NOTES.md) covers how the project is worked on —
measurement habits, which evidence to trust, and the ways the build has silently lied.

## Requirements

- macOS 11 or later.
- **NDI Advanced SDK for Apple**, installed at `/Library/NDI Advanced SDK for Apple`.
  The build fails immediately without it. Download it from [ndi.video](https://ndi.video).
- **NDI SDK for Apple** at `/Library/NDI SDK for Apple` — optional. Without it the app
  offers the Advanced library only; see *The library follows the codec* in the
  architecture notes for why both ship side by side.
- Xcode **Command Line Tools** are enough. There is no Xcode project and no `.metal`
  shader — the CLT ship no Metal shader compiler, which is why the frame renderer is
  CoreImage.

## Build and run

```bash
./build.sh                    # -> .build/2NDI.app, universal, ad-hoc signed
open .build/2NDI.app
```

```bash
./package.sh                  # -> 2NDI.zip, for transfer to another Mac
```

Use `package.sh` rather than zipping by hand. It uses `ditto` to preserve the framework
symlinks and the code signature; a Finder zip flattens both and the app will not launch on
the far machine.

`build.sh` deletes `.build` and re-copies both NDI dylibs from `/Library` on every run, so
anything modified inside the bundle is discarded each build.

## Diagnostics

The tools under `Tools/` are not part of the app; they exist to check it, and several bugs
here were only ever caught by them rather than by looking at the app. Each is documented in
the architecture notes.

```bash
./Tools/build_probe.sh
./Tools/ndi_probe                        # list NDI sources
./Tools/ndi_probe <name> <seconds>       # program stream: resolution, rate, FourCC, bitrate
./Tools/ndi_probe <name> <seconds> "" low  # the low-bandwidth proxy stream
./Tools/ndi_probe <name> <seconds> out.png # decode and save one frame
```

`ndi_probe` receives in compressed passthrough mode, so the FourCC it prints is the
sender's own format rather than whatever a receiver decoded it into. That is the only way
to confirm what is actually on the wire.

## Licence note

The Advanced SDK's development licence **stops delivering video after 30 minutes**, while
the sender keeps reporting success. The app detects this by receiving its own output and
shows a banner. SpeedHQ runs on the base SDK and is unaffected, which is why it stays an
explicit choice for long runs.
