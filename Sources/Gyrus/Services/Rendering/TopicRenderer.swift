import MetalKit
import simd

private struct TopicNodeGPU { var position: SIMD4<Float>; var appearance: SIMD4<Float> }
private struct TopicUniforms {
    var modelView: simd_float4x4
    var projection: simd_float4x4
    var viewport: SIMD4<Float>
    var accent: SIMD4<Float>
}

final class TopicRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    private let nodePipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    var topic: Topic?
    var selected: UUID?
    var orbit = SIMD2<Float>.zero

    init(device: MTLDevice, library: MTLLibrary? = nil) throws {
        self.device = device
        guard let queue = device.makeCommandQueue(), let library = library ?? device.makeDefaultLibrary() else {
            throw BrainRendererError.unavailableMetal
        }
        self.queue = queue
        func pipeline(vertex: String, fragment: String, topology: MTLPrimitiveTopologyClass) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            guard let v = library.makeFunction(name: vertex), let f = library.makeFunction(name: fragment) else {
                throw BrainRendererError.missingShaders
            }
            descriptor.vertexFunction = v
            descriptor.fragmentFunction = f
            descriptor.inputPrimitiveTopology = topology
            guard let color = descriptor.colorAttachments[0] else { throw BrainRendererError.allocationFailed }
            color.pixelFormat = .bgra8Unorm
            color.isBlendingEnabled = true
            color.sourceRGBBlendFactor = topology == .line ? .sourceAlpha : .one
            color.destinationRGBBlendFactor = .one
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        nodePipeline = try pipeline(vertex: "topicNode", fragment: "topicTriangle", topology: .point)
        linePipeline = try pipeline(vertex: "topicLine", fragment: "topicLineLight", topology: .line)
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.needsDisplay = true }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let command = queue.makeCommandBuffer() else { return }
        do {
            try encodeFrame(to: drawable.texture, command: command,
                pixelScale: Float(view.drawableSize.width / max(1, view.bounds.width)))
            command.present(drawable)
            command.commit()
        } catch { NSLog("Gyrus topic renderer: %@", String(describing: error)) }
    }

    func encodeFrame(to destination: MTLTexture, command: MTLCommandBuffer, pixelScale: Float) throws {
        let size = SIMD2(Float(destination.width), Float(destination.height)) / pixelScale
        let frame = TopicProjection.frame(size: size, orbit: orbit)
        var uniforms = TopicUniforms(modelView: frame.view * frame.model, projection: frame.projection,
            viewport: SIMD4(size.x, size.y, pixelScale, 0), accent: SIMD4(VisualConfiguration.activeColor, 1))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(2 / 255, 2 / 255, 4 / 255, 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw BrainRendererError.allocationFailed }
        defer { encoder.endEncoding() }
        guard let topic else { return }
        let positions = Dictionary(uniqueKeysWithValues: topic.keywords.map { ($0.id, $0.position) })
        let lines = topic.connections.flatMap { connection -> [SIMD4<Float>] in
            guard let a = positions[connection.first], let b = positions[connection.second] else { return [] }
            guard let screenA = InteractionController.project(a, frame: frame, size: size),
                  let screenB = InteractionController.project(b, frame: frame, size: size) else { return [] }
            // Stop outside the glyphs so violet edges never tint a neutral keyword's interior.
            let inset = min(0.4, 18 / max(1, simd_distance(screenA, screenB)))
            return [SIMD4(a + (b - a) * inset, 1), SIMD4(b + (a - b) * inset, 1)]
        }
        if !lines.isEmpty {
            guard let buffer = device.makeBuffer(bytes: lines, length: lines.count * MemoryLayout<SIMD4<Float>>.stride) else {
                throw BrainRendererError.allocationFailed
            }
            encoder.setRenderPipelineState(linePipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<TopicUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: lines.count)
        }
        var nodes = [TopicNodeGPU(position: SIMD4<Float>(0, 0, 0, 1), appearance: SIMD4(36, 0, 0.65, 0))]
        nodes += topic.keywords.map {
            TopicNodeGPU(position: SIMD4($0.position, 1), appearance: SIMD4($0.id == selected ? 28 : 16, $0.phase, $0.id == selected ? 1 : 0, 0))
        }
        guard let buffer = device.makeBuffer(bytes: nodes, length: nodes.count * MemoryLayout<TopicNodeGPU>.stride) else {
            throw BrainRendererError.allocationFailed
        }
        encoder.setRenderPipelineState(nodePipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<TopicUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TopicUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: nodes.count)
    }
}
