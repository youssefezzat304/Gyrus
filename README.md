# Gyrus — particle brain visual prototype

A macOS SwiftUI shell around a Metal/MetalKit scene. The entire experience is a
particle brain, a click on one of eight violet activation regions, and a
2.3-second camera dive ending in empty near-black space. Drag anywhere on the
brain to rotate it. A **Back** button appears at the destination and reverses the
camera journey over 1.5 seconds, restoring the user's previous orientation.
Dragging is distinguished from clicking so rotating across a thought cannot
accidentally enter it. Activation hit testing follows the current rotation and
ignores centers facing away from the camera.

Open `Gyrus.xcodeproj`, select the **Gyrus** scheme, and run on **My Mac**.
The project currently targets macOS 27, matching the original Xcode starter.
Xcode's Metal Toolchain component is required (`xcodebuild -downloadComponent MetalToolchain`
if Xcode reports it missing). The application has no runtime dependencies or network access.

Swift sources live in `Sources/Gyrus/{App,Core,Services,UI}`, bundled assets in
`Resources`, the standalone verification harness in `Tests`, and development
scripts in `Tools`. The existing Xcode target and scheme are unchanged.

Project guidance lives in [AGENTS.md](AGENTS.md), with canonical
[architecture](docs/architecture.md), [visual style](docs/style.md), and
[decisions](docs/decisions.md) documents. The visual direction is futuristic and
sci-fi. The existing `.gitignore` keeps these guidance documents local.

All aesthetic controls are in `Sources/Gyrus/UI/DesignSystem/VisualConfiguration.swift`.
The default is 25,000 particles: 86% cortical surface, 12% beneath the surface,
2% peripheral, plus eight activation centers. Particles are lightly filled, outlined white triangles;
only active regions use the single violet accent. Hover any visible surface triangle
to enlarge it most, with progressively smaller enlargement of nearby particles over
a 52-point radius. Depth filtering keeps the effect on the local surface, and
the sizes ease back when the pointer leaves. Hovering a white triangle preserves its
white color. Size, hover radius and falloff, accent, drag sensitivity, and return
duration are configurable alongside the lighting and camera controls.
An invisible 150,256-triangle MRI-derived bilateral pial mesh preserves the
anatomy. Its signed curvature controls fold brightness. Only particles reach
GPU geometry buffers; the mesh itself is never rendered. A particle-only depth
pass suppresses competing far-side light, followed by additive HDR light,
quarter-resolution bloom, and compositing. Particle positions are generated once.

`Resources/Brain/Brain-Attribution.txt` records the OpenNeuro CC0 source and
derived asset provenance. `python3 Tools/prepare_brain_mesh.py` reproduces the
bundled reference from a pinned, checksum-verified source. Only that development
tool downloads data; building and running Gyrus are offline.

Run `zsh Tools/check-prototype.sh` for the offscreen integration and visual check.
It compiles the production Swift renderer and Metal shaders, checks deterministic
particle generation, all eight projected hit targets, camera crossings and
selection locking, rotated picking, preserved orientation after Back, and repeat
entry. An isolated GPU scene checks triangular silhouettes, white/accent colors, the
central-to-neighbor size falloff, and hover release. Detached native mouse-event
fixtures check hover tracking and drag-versus-click behavior
without posting input to the desktop. It renders minimum/default/wide window sizes, dive and return frames,
checks that the destination renderer contains only the near-black environment, and
reports GPU timings. PNGs are written to `/tmp/GyrusChecks` (override with
`GYRUS_CHECK_OUTPUT`). GPU timings measure renderer work rather than end-to-end
display frame rate; the live view requests 60 FPS.

For a command-line build:

```sh
xcodebuild -project Gyrus.xcodeproj -scheme Gyrus -configuration Release \
  -derivedDataPath /tmp/GyrusDerivedData CODE_SIGNING_ALLOWED=NO build
```
