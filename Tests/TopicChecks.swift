import AppKit
import SwiftUI
import MetalKit
import CoreImage
import simd

@main
struct TopicChecks {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GYRUS_CHECK_OUTPUT"] ?? "/tmp/GyrusTopicChecks")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let archive = output.appendingPathComponent("test-topics-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: archive) }
        let anchor = BrainAnchor(particleID: 10, position: SIMD3(0.1, 0.2, 0.3), normal: SIMD3(0, 0, 1))
        let store = TopicStore(archiveURL: archive)
        precondition(store.create(name: "  ", anchor: anchor) == nil)
        let topicID = store.create(name: "  Neuroscience  ", anchor: anchor)!
        precondition(store.topic(id: topicID)?.name == "Neuroscience")
        precondition(store.create(name: "Duplicate", anchor: anchor) == topicID && store.topics.count == 1)
        var draft = KeywordDraft()
        draft.text = " Neurons "
        precondition(draft.stage(existing: []))
        draft.text = "NEURONS"
        precondition(!draft.stage(existing: []))
        draft.text = "Synapses"
        precondition(draft.stage(existing: []))
        precondition(store.topic(id: topicID)!.keywords.isEmpty, "Return must only stage keywords")
        let added = store.addKeywords(draft.names, to: topicID)
        precondition(added.count == 2 && store.topic(id: topicID)!.connections.isEmpty)
        precondition(store.addKeywords(["neurons", "", String(repeating: "a", count: 121)], to: topicID).isEmpty)
        precondition(store.connect(added[0], to: added[1], in: topicID))
        precondition(!store.connect(added[1], to: added[0], in: topicID), "Reverse duplicate edges must be rejected")
        precondition(!store.connect(added[0], to: added[0], in: topicID))
        precondition(!store.connect(added[0], to: UUID(), in: topicID))
        let anotherID = store.create(name: "Astronomy", anchor: BrainAnchor(particleID: 20, position: .zero, normal: anchor.normal))!
        let otherKeyword = store.addKeywords(["Orbits"], to: anotherID)[0]
        precondition(!store.connect(added[0], to: otherKeyword, in: topicID), "Connections cannot cross topics")
        precondition(store.search("NEURO").map(\.id) == [topicID])
        precondition(store.search("not a topic").isEmpty)
        let loaded = TopicStore(archiveURL: archive)
        precondition(loaded.topics == store.topics, "Names, 3D positions, IDs, and edges must survive reopening")
        precondition(loaded.persistenceError == nil)
        print("PASS: staging, validation, topic/keyword identity, search, undirected edges, and local persistence")

        let badArchive = output.appendingPathComponent("invalid-\(UUID().uuidString).json")
        let invalid = Data("{bad archive".utf8)
        try invalid.write(to: badArchive)
        let protected = TopicStore(archiveURL: badArchive)
        _ = protected.create(name: "In memory only", anchor: anchor)
        precondition(protected.persistenceError != nil && !protected.canRetrySaving)
        let preservedData = try Data(contentsOf: badArchive)
        precondition(preservedData == invalid, "Unreadable saved data must not be overwritten")
        try FileManager.default.removeItem(at: badArchive)
        let failure = TopicStore(archiveURL: URL(fileURLWithPath: "/dev/null/Gyrus-topics.json"))
        _ = failure.create(name: "Still available", anchor: anchor)
        precondition(failure.topics.count == 1 && failure.persistenceError != nil)

        let interaction = KeywordInteraction()
        let graphIDs = store.addKeywords(["Memory", "Attention", "Cortex"], to: topicID)
        interaction.select(graphIDs[0], topicID: topicID, store: store)
        interaction.beginConnection()
        interaction.query = "attention"
        precondition(interaction.selected == graphIDs[0] && interaction.matches(in: store.topic(id: topicID)!).map(\.id) == [graphIDs[1]])
        interaction.select(graphIDs[1], topicID: topicID, store: store)
        precondition(interaction.connectionSource == nil && interaction.selected == graphIDs[0], "First node must stay selected after linking")
        interaction.beginConnection()
        precondition(!interaction.matches(in: store.topic(id: topicID)!).contains { $0.id == graphIDs[1] })
        let edgesBeforeCancel = store.topic(id: topicID)!.connections
        interaction.cancelConnection()
        precondition(store.topic(id: topicID)!.connections == edgesBeforeCancel)

        let size = SIMD2<Float>(1200, 800)
        var graphTopic = store.topic(id: topicID)!
        // Fixed separated nodes make 3D picking, rotation and GPU captures reproducible.
        graphTopic.keywords = [
            Keyword(id: added[0], name: "Neurons", position: SIMD3(-1.15, 0.50, 0.3), phase: 0.2),
            Keyword(id: added[1], name: "Synapses", position: SIMD3(1.1, 0.65, -0.6), phase: 1.5),
            Keyword(id: graphIDs[0], name: "Memory", position: SIMD3(-0.9, -0.8, -0.3), phase: 0.9),
            Keyword(id: graphIDs[1], name: "Attention", position: SIMD3(0.9, -0.7, 0.5), phase: 2.5)]
        let front = TopicProjection.frame(size: size, orbit: .zero)
        let rotated = TopicProjection.frame(size: size, orbit: SIMD2(0.4, -0.3))
        for keyword in graphTopic.keywords {
            let point = InteractionController.project(keyword.position, frame: rotated, size: size)!
            precondition(TopicProjection.pick(point: point, keywords: graphTopic.keywords, frame: rotated, size: size) == keyword.id)
        }
        precondition(InteractionController.project(graphTopic.keywords[0].position, frame: front, size: size)
                     != InteractionController.project(graphTopic.keywords[0].position, frame: rotated, size: size))
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal required") }
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Gyrus/Services/Rendering/TopicShaders.metal"), encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        let renderer = try TopicRenderer(device: device, library: library)
        renderer.topic = graphTopic
        renderer.selected = graphTopic.keywords[0].id
        let context = CIContext(mtlDevice: device)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        func render(_ name: String, width: Int = 2400, height: Int = 1600) throws -> [UInt8] {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]; desc.storageMode = .shared
            let texture = device.makeTexture(descriptor: desc)!
            let command = renderer.queue.makeCommandBuffer()!
            try renderer.encodeFrame(to: texture, command: command, pixelScale: 2)
            command.commit(); command.waitUntilCompleted()
            precondition(command.status == .completed)
            let image = CIImage(mtlTexture: texture, options: [.colorSpace: colorSpace])!.oriented(.downMirrored)
            try context.writePNGRepresentation(of: image, to: output.appendingPathComponent(name + ".png"), format: .RGBA8, colorSpace: colorSpace)
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            return bytes
        }
        let linked = try render("01-topic-connected")
        let white = InteractionController.project(graphTopic.keywords[1].position, frame: front, size: size)! * 2
        let whiteOffset = (Int(white.y) * 2400 + Int(white.x)) * 4
        precondition(abs(Int(linked[whiteOffset]) - Int(linked[whiteOffset + 2])) <= 3)
        renderer.topic?.connections = []
        let unlinked = try render("02-topic-unconnected")
        precondition(zip(linked, unlinked).contains { $0 != $1 }, "An explicit connection must produce a visible line")
        renderer.orbit = SIMD2(0.4, -0.3)
        _ = try render("03-topic-rotated")
        _ = try render("04-topic-minimum", width: 1800, height: 1200)
        _ = try render("05-topic-wide", width: 2880, height: 1500)

        let geometry = try BrainParticleGenerator.generate(meshURL: root.appendingPathComponent("Resources/Brain/Cortex.brainmesh"))
        let brainSource = try String(contentsOf: root.appendingPathComponent("Sources/Gyrus/Services/Rendering/BrainShaders.metal"), encoding: .utf8)
        let brain = try BrainRenderer(device: device, geometry: geometry, library: device.makeLibrary(source: brainSource, options: nil))
        let frame = brain.camera.frame(time: 0, aspect: 1.5)
        let whiteIndex = geometry.particles.indices.first { index in
            let p = geometry.particles[index]
            guard p.position.w == 0, geometry.regions.allSatisfy({ simd_distance($0.position, p.position.xyz) > 0.35 }),
                  let point = InteractionController.project(p.position.xyz, frame: frame, size: size) else { return false }
            return InteractionController.pickParticle(point: point, particles: geometry.particles, frame: frame, size: size) == index
        }!
        let p = geometry.particles[whiteIndex]
        let newAnchor = BrainAnchor(particleID: whiteIndex, position: p.position.xyz, normal: p.normal.xyz)
        let memory = TopicStore(archiveURL: nil)
        let session = BrainSession()
        brain.onParticleClicked = { session.requestTopic(at: $0, store: memory) }
        brain.onPhaseChanged = session.updatePhase
        session.onEnter = { anchor in
            brain.topicAnchors = memory.topics.map(\.anchor)
            return brain.enterTopic(at: anchor, size: size, time: 0) ? brain.camera.phase : nil
        }
        brain.pointerPosition = InteractionController.project(newAnchor.position, frame: frame, size: size)
        brain.click(size: size, time: 0)
        precondition(session.pendingAnchor?.particleID == whiteIndex && brain.camera.phase == .brain,
                     "Clicking a white particle must prompt for a name without starting entry")
        session.cancelNaming()
        precondition(memory.topics.isEmpty)
        session.requestTopic(at: newAnchor, store: memory)
        precondition(!session.nameTopic("  ", store: memory) && brain.camera.phase == .brain)
        precondition(session.nameTopic("New topic", store: memory))
        guard case .diving = brain.camera.phase else { fatalError("Naming must initiate the real camera dive") }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1200, height: 800, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        let target = device.makeTexture(descriptor: desc)!
        func brainFrame(_ time: Double) throws {
            let command = brain.queue.makeCommandBuffer()!
            try brain.encodeFrame(to: target, commandBuffer: command, time: time, pixelScale: 1)
            command.commit(); command.waitUntilCompleted()
            precondition(command.status == .completed)
        }
        try brainFrame(VisualConfiguration.diveDuration)
        precondition(session.isInSpace && session.currentTopicID == memory.topics[0].id)
        precondition(brain.returnToBrain(time: 4))
        try brainFrame(4)
        try brainFrame(4 + VisualConfiguration.returnDuration)
        precondition(session.canSearch && session.currentTopicID == nil)
        session.requestTopic(at: newAnchor, store: memory)
        precondition(session.pendingAnchor == nil && memory.topics.count == 1,
                     "An existing topic opens directly without naming or duplicating it")

        // Actual native mouse handlers: click selects a keyword; dragging across one does not.
        let native = KeywordMetalView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), device: device)
        native.isPaused = true; native.renderer = renderer; renderer.orbit = .zero; renderer.topic = graphTopic
        let nativeInteraction = KeywordInteraction()
        native.interaction = nativeInteraction; native.store = store
        let point = InteractionController.project(graphTopic.keywords[0].position, frame: front, size: size)!
        func event(_ type: NSEvent.EventType, _ point: SIMD2<Float>) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: CGFloat(point.x), y: CGFloat(800 - point.y)),
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        native.mouseDown(with: event(.leftMouseDown, point)); native.mouseUp(with: event(.leftMouseUp, point))
        precondition(nativeInteraction.selected == graphTopic.keywords[0].id)
        native.mouseDown(with: event(.leftMouseDown, point))
        native.mouseDragged(with: event(.leftMouseDragged, point + SIMD2(40, 25)))
        native.mouseUp(with: event(.leftMouseUp, point + SIMD2(40, 25)))
        precondition(nativeInteraction.orbit != .zero && nativeInteraction.selected == graphTopic.keywords[0].id)
        print("PASS: real white-particle naming/entry, cancel, reopening, graph GPU, perspective picking, native keyword selection/drag. Frames: \(output.path)")
    }
}
