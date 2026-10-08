# Gyrus — particle brain visual prototype

A native macOS SwiftUI and Metal workspace built around a particle brain. Click a
white particle, name its topic, and enter its space through a 2.3-second camera dive. Drag anywhere on the
brain to rotate it. A **Back** button appears at the destination and reverses the
camera journey over 1.5 seconds, restoring the user's previous orientation.

Inside a topic, use **+ Add Keywords**. Return queues each keyword while the
dialog stays open; **Add** places the triangles in 3D, and **Cancel** discards the
draft. Select a keyword for its name, glow and **Connect** action, then search
for or click another keyword to link them. New keywords have no automatic links.
**Control-F** in the brain finds saved topics. Topics, keyword positions and
connections save locally on this Mac.

Open `Gyrus.xcodeproj` and run the `Gyrus` scheme. Verification commands:

```sh
zsh Tools/check-prototype.sh
zsh Tools/check-topics.sh
```
Dragging is distinguished from clicking so rotating across a thought cannot
accidentally enter it. Activation hit testing follows the current rotation and
ignores centers facing away from the camera.
