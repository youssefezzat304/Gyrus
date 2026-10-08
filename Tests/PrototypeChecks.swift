import AppKit
import CoreImage
import MetalKit
import simd

/// Runs the actual renderer offscreen, including the production shaders and camera.
@main
struct PrototypeChecks {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GYRUS_CHECK_OUTPUT"] ?? "/tmp/GyrusChecks")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal is required") }
        let start = CACurrentMediaTime()
        let geometry = try BrainParticleGenerator.generate(meshURL: root.appendingPathComponent("Resources/Brain/Cortex.brainmesh"))
        let generationTime = CACurrentMediaTime() - start
        precondition(geometry.particles.count == VisualConfiguration.particleCount + VisualConfiguration.activeRegionCount)
        precondition(geometry.regions.count == 8)
        precondition(geometry.particles.allSatisfy { p in
            p.position.x.isFinite && p.position.y.isFinite && p.position.z.isFinite && p.appearance.x > 0
        })
        let again = try BrainParticleGenerator.generate(meshURL: root.appendingPathComponent("Resources/Brain/Cortex.brainmesh"))
        precondition(zip(geometry.particles, again.particles).allSatisfy { $0.position == $1.position && $0.appearance == $1.appearance })
        let populations = Dictionary(grouping: geometry.particles, by: { Int($0.position.w) }).mapValues(\.count)
        print("Particles: \(populations); generated in \(String(format: "%.1f", generationTime * 1000)) ms")

        let shaders = try String(contentsOf: root.appendingPathComponent("Sources/Gyrus/Services/Rendering/BrainShaders.metal"), encoding: .utf8)
        let library = try device.makeLibrary(source: shaders, options: nil)
        let renderer = try BrainRenderer(device: device, geometry: geometry, library: library)
        var backAvailability = [Bool]()
        renderer.onCanGoBackChanged = { backAvailability.append($0) }
        precondition(!renderer.returnToBrain(time: 0), "Back must be ignored in the opening scene")
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CIContext(mtlDevice: device)
        func render(_ name: String?, _ time: Double, width: Int = 2400, height: Int = 1600) throws -> Double {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .shared
            let texture = device.makeTexture(descriptor: desc)!
            let command = renderer.queue.makeCommandBuffer()!
            try renderer.encodeFrame(to: texture, commandBuffer: command, time: time, pixelScale: 2)
            command.commit()
            command.waitUntilCompleted()
            precondition(command.status == .completed, "GPU failed: \(String(describing: command.error))")
            if let name {
                let image = CIImage(mtlTexture: texture, options: [.colorSpace: colorSpace])!.oriented(.downMirrored)
                try context.writePNGRepresentation(of: image, to: output.appendingPathComponent(name + ".png"), format: .RGBA8, colorSpace: colorSpace)
            }
            if renderer.camera.phase == .empty {
                var bytes = [UInt8](repeating: 0, count: width * height * 4)
                texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
                precondition(stride(from: 0, to: bytes.count, by: 4).allSatisfy {
                    bytes[$0] == 4 && bytes[$0 + 1] == 2 && bytes[$0 + 2] == 2 && bytes[$0 + 3] == 255
                }, "Empty destination must contain only its near-black environment")
            }
            return (command.gpuEndTime - command.gpuStartTime) * 1000
        }

        _ = try render("01-brain", 0)
        let size = SIMD2<Float>(1200, 800)
        let frame = renderer.camera.frame(time: 0, aspect: 1.5)
        var centers: [String] = []
        for (index, region) in geometry.regions.enumerated() {
            let point = InteractionController.project(region.position, frame: frame, size: size)!
            precondition(InteractionController.hitTest(point: point, regions: geometry.regions, frame: frame, size: size) == index)
            centers.append("\(index): \(Int(point.x)), \(Int(point.y))")
            let camera = CameraController()
            camera.beginDive(region: index, regions: geometry.regions, time: 0, aspect: 1.5)
            let ignored = camera.phase
            camera.beginDive(region: (index + 1) % 8, regions: geometry.regions, time: 0.1, aspect: 1.5)
            precondition(camera.phase == ignored, "Clicks during a dive must be ignored")
            var crossed = false
            let entry = (frame.model * SIMD4(region.position, 1)).xyz
            let direction = simd_normalize(entry - frame.eye)
            var previousDistance: Float = 0
            for step in 0...240 {
                let f = camera.frame(time: Double(step) / 240 * VisualConfiguration.diveDuration, aspect: 1.5)
                let distance = simd_dot(f.eye - frame.eye, direction)
                precondition(distance >= previousDistance - 0.00001)
                previousDistance = distance
                precondition(f.view.columns.0.x.isFinite && f.eye.x.isFinite)
                if simd_dot(f.eye - entry, direction) > 0 { crossed = true }
            }
            precondition(crossed && camera.phase == .empty, "Camera must pass through every selected thought")
        }
        precondition(InteractionController.hitTest(point: SIMD2(0, 0), regions: geometry.regions, frame: frame, size: size) == nil)
        print("Projected centers at 1200 × 800: " + centers.joined(separator: "; "))
        renderer.pointerPosition = InteractionController.project(geometry.regions[0].position, frame: frame, size: size)
        _ = try render("02-hover", 0.3)
        precondition(renderer.hoveredRegion == 0)
        precondition(renderer.hoveredParticle != nil && renderer.particleHoverAmount > 0)
        renderer.pointerPosition = nil
        _ = try render("03-minimum-window", 0.4, width: 1800, height: 1200)
        _ = try render("04-wide-window", 0.5, width: 2880, height: 1500)
        var times: [Double] = []
        for index in 0..<90 { times.append(try render(nil, 1 + Double(index) / 60)) }
        print("Idle GPU at 2400 × 1600: mean \(String(format: "%.2f", times.reduce(0, +) / Double(times.count))) ms; max \(String(format: "%.2f", times.max()!)) ms")
        renderer.camera.beginDive(region: 0, regions: geometry.regions, time: 3, aspect: 1.5)
        for (index, offset) in [0.15, 0.65, 1.2, 1.65, 1.85, 2.05, 2.3].enumerated() {
            let milliseconds = try render(String(format: "%02d-dive-%.2f", index + 5, offset), 3 + offset)
            print("Dive \(offset)s GPU: \(String(format: "%.2f", milliseconds)) ms")
        }
        _ = try render("12-empty-after-wait", 20)
        precondition(backAvailability == [true])
        precondition(renderer.returnToBrain(time: 20))
        precondition(!renderer.returnToBrain(time: 20), "A second back action must not restart the return")
        for (index, offset) in [0.3, 0.75, 1.2, 1.5].enumerated() {
            _ = try render("\(13 + index)-return", 20 + offset)
        }
        precondition(renderer.camera.phase == .brain && backAvailability == [true, false])

        let orbit = CameraController()
        let before = orbit.frame(time: 0, aspect: 1.5)
        orbit.rotate(by: SIMD2(80, -35))
        let rotated = orbit.frame(time: 0, aspect: 1.5)
        precondition(simd_distance(before.model.columns.0, rotated.model.columns.0) > 0.1,
                     "Dragging must change the 3D orientation")
        let visible = geometry.regions.indices.filter {
            InteractionController.isFacingCamera(geometry.regions[$0], frame: rotated)
                && InteractionController.project(geometry.regions[$0].position, frame: rotated, size: size) != nil
        }
        precondition(!visible.isEmpty)
        for i in visible {
            let point = InteractionController.project(geometry.regions[i].position, frame: rotated, size: size)!
            precondition(InteractionController.hitTest(point: point, regions: geometry.regions, frame: rotated, size: size) == i,
                         "Picking must track the rotated brain")
        }
        orbit.beginDive(region: visible[0], regions: geometry.regions, time: 0, aspect: 1.5)
        orbit.rotate(by: SIMD2(500, 500))
        precondition(orbit.frame(time: 0, aspect: 1.5).model == rotated.model, "Dragging must be locked during a dive")
        _ = orbit.frame(time: VisualConfiguration.diveDuration, aspect: 1.5)
        orbit.beginReturn(time: 10)
        let returned = orbit.frame(time: 10 + VisualConfiguration.returnDuration, aspect: 1.5)
        precondition(orbit.phase == .brain && returned.model == rotated.model,
                     "Back must restore the exact user rotation")
        let resumed = orbit.frame(time: 10 + VisualConfiguration.returnDuration + 0.016, aspect: 1.5)
        precondition(simd_distance(returned.model.columns.0, resumed.model.columns.0) < 0.001,
                     "Idle animation must resume without a jump")
        renderer.camera.rotate(by: SIMD2(140, -45))
        _ = try render("17-rotated-brain", 21.6)
        let visibleAfterReturn = geometry.regions.indices.first {
            InteractionController.isFacingCamera(geometry.regions[$0], frame: renderer.lastFrame!)
        }!
        renderer.camera.beginDive(region: visibleAfterReturn, regions: geometry.regions, time: 22, aspect: 1.5)
        _ = try render("18-second-dive-empty", 22 + VisualConfiguration.diveDuration)
        precondition(backAvailability == [true, false, true], "The experience must work repeatedly after Back")

        // Measure actual production-shader output in a sparse scene so overlapping
        // brain particles cannot hide shape, color, or the distance falloff.
        let fixtureFrame = CameraController().frame(time: 0, aspect: 1.5)
        let fixtureNormal = simd_normalize((fixtureFrame.model.inverse * SIMD4<Float>(0, 0, 1, 0)).xyz)
        let fixturePoints: [SIMD2<Float>] = [SIMD2(600, 400), SIMD2(616, 400), SIMD2(632, 400),
                                            SIMD2(675, 400), SIMD2(500, 400)]
        func localPosition(_ point: SIMD2<Float>) -> SIMD3<Float> {
            let ndc = SIMD2(point.x / size.x * 2 - 1, 1 - point.y / size.y * 2)
            let view = SIMD4(ndc.x * 5.6 / fixtureFrame.projection.columns.0.x,
                             ndc.y * 5.6 / fixtureFrame.projection.columns.1.y, -5.6, 1)
            return (fixtureFrame.model.inverse * fixtureFrame.view.inverse * view).xyz
        }
        let fixtureParticles = fixturePoints.enumerated().map { i, point in
            BrainParticle(position: SIMD4(localPosition(point), i == 4 ? 3 : 0),
                normal: SIMD4(fixtureNormal, 1), appearance: SIMD4(1.7, 1, 0, 0))
        }
        let fixtureGeometry = BrainGeometry(particles: fixtureParticles,
            regions: [ActiveRegion(position: fixtureParticles[4].position.xyz, normal: fixtureNormal, phase: 0)])
        let fixture = try BrainRenderer(device: device, geometry: fixtureGeometry, library: library)
        func fixturePixels(_ time: Double, name: String? = nil) throws -> [UInt8] {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: 2400, height: 1600, mipmapped: false)
            desc.storageMode = .shared
            desc.usage = [.renderTarget, .shaderRead]
            let texture = device.makeTexture(descriptor: desc)!
            let command = fixture.queue.makeCommandBuffer()!
            try fixture.encodeFrame(to: texture, commandBuffer: command, time: time, pixelScale: 2)
            command.commit()
            command.waitUntilCompleted()
            precondition(command.status == .completed)
            var pixels = [UInt8](repeating: 0, count: 2400 * 1600 * 4)
            texture.getBytes(&pixels, bytesPerRow: 2400 * 4, from: MTLRegionMake2D(0, 0, 2400, 1600), mipmapLevel: 0)
            if let name {
                let image = CIImage(mtlTexture: texture, options: [.colorSpace: colorSpace])!.oriented(.downMirrored)
                try context.writePNGRepresentation(of: image, to: output.appendingPathComponent(name + ".png"),
                    format: .RGBA8, colorSpace: colorSpace)
            }
            return pixels
        }
        func particleBounds(_ pixels: [UInt8], index: Int) -> SIMD2<Int> {
            let point = InteractionController.project(fixtureParticles[index].position.xyz,
                frame: fixture.lastFrame!, size: size)! * 2
            var minX = 2400, maxX = -1, minY = 1600, maxY = -1
            for y in (Int(point.y) - 24)...(Int(point.y) + 24) {
                for x in (Int(point.x) - 24)...(Int(point.x) + 24) {
                    let offset = (y * 2400 + x) * 4
                    if pixels[offset + 1] > 75 {
                        minX = min(minX, x); maxX = max(maxX, x)
                        minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
            }
            return SIMD2(maxX - minX + 1, maxY - minY + 1)
        }
        func particleExtent(_ pixels: [UInt8], index: Int) -> Int {
            let point = InteractionController.project(fixtureParticles[index].position.xyz,
                frame: fixture.lastFrame!, size: size)! * 2
            // A narrow vertical slice avoids including the neighboring particle in this measurement.
            var minY = 1600, maxY = -1
            for y in (Int(point.y) - 24)...(Int(point.y) + 24) {
                for x in (Int(point.x) - 1)...(Int(point.x) + 1) {
                    if pixels[(y * 2400 + x) * 4 + 1] > 75 {
                        minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
            }
            return maxY - minY + 1
        }
        let baselinePixels = try fixturePixels(0)
        let baseline = (0..<4).map { particleBounds(baselinePixels, index: $0) }
        precondition(baseline.allSatisfy { $0.x > 0 && $0.y > 0 }, "Particles must remain visible")
        let whitePoint = fixturePoints[0] * 2
        let whiteOffset = (Int(whitePoint.y) * 2400 + Int(whitePoint.x)) * 4
        precondition(abs(Int(baselinePixels[whiteOffset]) - Int(baselinePixels[whiteOffset + 2])) <= 3,
                     "Inactive particles must be neutral white")
        let activePoint = fixturePoints[4] * 2
        let activeOffset = (Int(activePoint.y) * 2400 + Int(activePoint.x)) * 4
        precondition(Int(baselinePixels[activeOffset]) > Int(baselinePixels[activeOffset + 2]) + 40,
                     "Only active particles should use the primary violet accent")
        fixture.pointerPosition = fixturePoints[0]
        var enlargedPixels = baselinePixels
        for step in 1...12 { enlargedPixels = try fixturePixels(Double(step) / 10, name: step == 12 ? "19-hover-falloff-fixture" : nil) }
        precondition(fixture.hoveredParticle == 0 && fixture.hoveredRegion == nil,
                     "Ordinary white particles must support hover independently of active regions")
        let enlarged = (0..<4).map { particleExtent(enlargedPixels, index: $0) }
        precondition(enlarged[0] > enlarged[1] && enlarged[1] > enlarged[2] && enlarged[2] > enlarged[3],
                     "The hovered particle must be largest, with progressively smaller neighbors: \(enlarged)")
        precondition(enlarged[3] <= baseline[3].y + 1, "Distant particles must retain their normal size")
        let enlargedCenter = InteractionController.project(fixtureParticles[0].position.xyz,
            frame: fixture.lastFrame!, size: size)! * 2
        let enlargedOffset = (Int(enlargedCenter.y) * 2400 + Int(enlargedCenter.x)) * 4
        precondition(abs(Int(enlargedPixels[enlargedOffset]) - Int(enlargedPixels[enlargedOffset + 2])) <= 3,
                     "Hovering an inactive particle must preserve its white color")
        func centerGreen(dx: Int, dy: Int) -> UInt8 {
            enlargedPixels[((Int(enlargedCenter.y) + dy) * 2400 + Int(enlargedCenter.x) + dx) * 4 + 1]
        }
        precondition(centerGreen(dx: 14, dy: -12) < 40 && centerGreen(dx: 0, dy: 10) > 100,
                     "The enlarged glyph must have a triangular outline rather than a circular silhouette")
        fixture.pointerPosition = nil
        var releasedPixels = enlargedPixels
        for step in 13...24 { releasedPixels = try fixturePixels(Double(step) / 10) }
        precondition(fixture.hoveredParticle == nil && fixture.particleHoverAmount < 0.001)
        precondition(particleBounds(releasedPixels, index: 0).x <= baseline[0].x + 1,
                     "Particles must ease back to their original size on pointer exit")
        // A buried particle directly behind a visible particle must not steal its hit.
        var occlusionParticles = fixtureParticles
        var buried = fixtureParticles[0]
        buried.position = SIMD4(buried.position.xyz - fixtureNormal * 0.4, 0)
        occlusionParticles.append(buried)
        precondition(InteractionController.pickParticle(point: fixturePoints[0], particles: occlusionParticles,
            frame: fixtureFrame, size: size) == 0)
        print("Triangle GPU checks: baseline extents \(baseline.map(\.y)); hovered center/near/far/outside \(enlarged) pixels")

        // Exercise the native view's actual event handlers with detached event fixtures.
        // These events are never posted to the system or another application.
        let inputRenderer = try BrainRenderer(device: device, geometry: geometry, library: library)
        var inputAnchor: BrainAnchor?
        inputRenderer.onParticleClicked = { inputAnchor = $0 }
        let inputView = ParticleMetalView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), device: device)
        inputView.isPaused = true
        inputView.renderer = inputRenderer
        func event(_ type: NSEvent.EventType, at point: SIMD2<Float>) -> NSEvent {
            let location = NSPoint(x: CGFloat(point.x), y: CGFloat(800 - point.y))
            if type == .mouseEntered || type == .mouseExited {
                return NSEvent.enterExitEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
            }
            return NSEvent.mouseEvent(with: type, location: location,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let inputFrame = inputRenderer.camera.frame(time: 0, aspect: 1.5)
        let inputPoint = InteractionController.project(geometry.regions[0].position, frame: inputFrame, size: size)!
        inputView.mouseMoved(with: event(.mouseMoved, at: inputPoint))
        precondition(inputRenderer.pointerPosition == inputPoint)
        inputView.mouseExited(with: event(.mouseExited, at: inputPoint))
        precondition(inputRenderer.pointerPosition == nil)
        inputView.mouseDown(with: event(.leftMouseDown, at: inputPoint))
        precondition(inputRenderer.camera.phase == .brain, "Mouse-down alone must not enter a thought")
        inputView.mouseDragged(with: event(.leftMouseDragged, at: inputPoint + SIMD2(40, -20)))
        inputView.mouseUp(with: event(.leftMouseUp, at: inputPoint + SIMD2(40, -20)))
        precondition(inputRenderer.camera.phase == .brain, "A drag starting on a thought must never become a click")
        let afterDrag = inputRenderer.camera.frame(time: 0, aspect: 1.5)
        precondition(afterDrag.model != inputFrame.model)
        let clickPoint = InteractionController.project(geometry.regions[0].position, frame: afterDrag, size: size)!
        inputView.mouseDown(with: event(.leftMouseDown, at: clickPoint))
        inputView.mouseDragged(with: event(.leftMouseDragged, at: clickPoint + SIMD2(1, 1)))
        inputView.mouseUp(with: event(.leftMouseUp, at: clickPoint + SIMD2(1, 1)))
        precondition(inputAnchor != nil && inputRenderer.camera.phase == .brain,
                     "A click must request a topic before entering; tiny hand movement still counts as a click")
        precondition(inputRenderer.enterTopic(at: inputAnchor!, size: size))
        guard case .diving = inputRenderer.camera.phase else { fatalError("Naming a topic must start entry") }
        print("PASS: 25k white triangles, single accent, radial hover sizes/release/occlusion, native hover/drag/click handlers, rotated picking, dive/return, preserved orientation, repeat entry, GPU rendering. Frames: \(output.path)")
    }
}
