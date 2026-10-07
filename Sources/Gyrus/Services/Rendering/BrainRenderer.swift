import MetalKit
import MetalPerformanceShaders
import QuartzCore
import simd

private struct FrameUniforms {
    var model: simd_float4x4
    var view: simd_float4x4
    var projection: simd_float4x4
    var cameraTime: SIMD4<Float>
    var viewport: SIMD4<Float>
    var appearance: SIMD4<Float>
    var accent: SIMD4<Float>
    var activity: SIMD4<Float>
    var transition: SIMD4<Float>
    var bloom: SIMD4<Float>
    var background: SIMD4<Float>
    var emptyBackground: SIMD4<Float>
    var control: SIMD4<Float>
    var sprite: SIMD4<Float>
    var hoverPoint: SIMD4<Float> // local xyz, smoothed strength
    var hoverStyle: SIMD4<Float> // central vertex ID, radius, center diameter, neighbor diameter
}

private struct GPURegion {
    var positionPhase: SIMD4<Float>
    var interaction: SIMD4<Float>
}

enum BrainRendererError: Error { case unavailableMetal, missingShaders, allocationFailed }

final class BrainRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let regions: [ActiveRegion]
    let camera = CameraController()
    private let particleBuffer: MTLBuffer
    private let particleCount: Int
    private let particles: [BrainParticle]
    private let particlePipeline: MTLRenderPipelineState
    private let corticalDepthPipeline: MTLRenderPipelineState
    private let corticalDepthState: MTLDepthStencilState
    private let compositePipeline: MTLRenderPipelineState
    private let bloomPipeline: MTLComputePipelineState
    private let blur: MPSImageGaussianBlur
    private var sceneTexture: MTLTexture?
    private var corticalDepthTexture: MTLTexture?
    private var bloomTexture: MTLTexture?
    private var blurredTexture: MTLTexture?
    private var hoverAmounts: [Float]
    private var previousTime: Double = 0
    private let epoch = CACurrentMediaTime()
    var pointerPosition: SIMD2<Float>?
    private(set) var hoveredRegion: Int?
    private(set) var hoveredParticle: Int?
    private(set) var particleHoverAmount: Float = 0
    private var hoverParticlePosition = SIMD3<Float>(repeating: 0)
    private var hoverParticleID = -1
    private(set) var lastFrame: CameraFrame?
    var onCanGoBackChanged: ((Bool) -> Void)?
    private var lastCanGoBack = false

    @discardableResult
    func returnToBrain(time: Double? = nil) -> Bool {
        guard camera.phase == .empty else { return false }
        camera.beginReturn(time: time ?? CACurrentMediaTime() - epoch)
        pointerPosition = nil
        hoveredRegion = nil
        hoveredParticle = nil
        particleHoverAmount = 0
        lastCanGoBack = false
        onCanGoBackChanged?(false)
        return true
    }

    init(device: MTLDevice, geometry: BrainGeometry, library: MTLLibrary? = nil) throws {
        self.device = device
        guard let queue = device.makeCommandQueue(),
              let buffer = device.makeBuffer(bytes: geometry.particles,
                    length: geometry.particles.count * MemoryLayout<BrainParticle>.stride, options: .storageModeShared)
        else { throw BrainRendererError.allocationFailed }
        self.queue = queue
        particleBuffer = buffer
        particleBuffer.label = "Immutable cortical particle population"
        particleCount = geometry.particles.count
        particles = geometry.particles
        regions = geometry.regions
        hoverAmounts = Array(repeating: 0, count: geometry.regions.count)
        guard let shaders = library ?? device.makeDefaultLibrary(),
              let vertex = shaders.makeFunction(name: "brainParticle"),
              let depthVertex = shaders.makeFunction(name: "corticalDepth"),
              let fragment = shaders.makeFunction(name: "particleLight"),
              let screen = shaders.makeFunction(name: "screenTriangle"),
              let composite = shaders.makeFunction(name: "compositeBrain"),
              let extract = shaders.makeFunction(name: "extractBloom") else { throw BrainRendererError.missingShaders }
        let particles = MTLRenderPipelineDescriptor()
        particles.label = "Batched luminous particles"
        particles.vertexFunction = vertex
        particles.fragmentFunction = fragment
        particles.inputPrimitiveTopology = .point
        let color = particles.colorAttachments[0]!
        color.pixelFormat = .rgba16Float
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.destinationRGBBlendFactor = .one
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .one
        particlePipeline = try device.makeRenderPipelineState(descriptor: particles)
        let depth = MTLRenderPipelineDescriptor()
        depth.label = "Optical depth from surface particles only"
        depth.vertexFunction = depthVertex
        depth.inputPrimitiveTopology = .point
        depth.depthAttachmentPixelFormat = .depth32Float
        corticalDepthPipeline = try device.makeRenderPipelineState(descriptor: depth)
        let depthState = MTLDepthStencilDescriptor()
        depthState.depthCompareFunction = .less
        depthState.isDepthWriteEnabled = true
        guard let state = device.makeDepthStencilState(descriptor: depthState) else { throw BrainRendererError.allocationFailed }
        corticalDepthState = state
        let final = MTLRenderPipelineDescriptor()
        final.label = "Optical bloom and dark environment"
        final.vertexFunction = screen
        final.fragmentFunction = composite
        final.colorAttachments[0].pixelFormat = .bgra8Unorm
        compositePipeline = try device.makeRenderPipelineState(descriptor: final)
        bloomPipeline = try device.makeComputePipelineState(function: extract)
        blur = MPSImageGaussianBlur(device: device, sigma: VisualConfiguration.bloomRadius)
        blur.edgeMode = .clamp
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        sceneTexture = nil
        if camera.phase == .empty { view.needsDisplay = true }
    }

    func click(size: SIMD2<Float>) {
        guard camera.phase == .brain, let pointerPosition else { return }
        let time = CACurrentMediaTime() - epoch
        let frame = camera.frame(time: time, aspect: size.x / max(1, size.y))
        guard let region = InteractionController.hitTest(point: pointerPosition, regions: regions, frame: frame, size: size) else { return }
        camera.beginDive(region: region, regions: regions, time: time, aspect: size.x / size.y)
        hoveredRegion = nil
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let command = queue.makeCommandBuffer() else { return }
        do {
            try encodeFrame(to: drawable.texture, commandBuffer: command, time: CACurrentMediaTime() - epoch,
                            pixelScale: Float(view.drawableSize.width / max(1, view.bounds.width)))
            command.present(drawable)
            command.commit()
            if camera.phase == .empty {
                view.isPaused = true
                view.enableSetNeedsDisplay = true
            }
        } catch {
            NSLog("Gyrus renderer: %@", String(describing: error))
            view.isPaused = true
        }
    }

    /// Shared by the live view and the offscreen visual/integration checks.
    func encodeFrame(to destination: MTLTexture, commandBuffer: MTLCommandBuffer, time: Double, pixelScale: Float) throws {
        let width = destination.width, height = destination.height
        if sceneTexture?.width != width || sceneTexture?.height != height {
            func texture(_ w: Int, _ h: Int, _ label: String) throws -> MTLTexture {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                    width: w, height: h, mipmapped: false)
                descriptor.storageMode = .private
                descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
                guard let texture = device.makeTexture(descriptor: descriptor) else { throw BrainRendererError.allocationFailed }
                texture.label = label
                return texture
            }
            sceneTexture = try texture(width, height, "Linear particle light")
            let depth = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                width: width, height: height, mipmapped: false)
            depth.storageMode = .private
            depth.usage = [.renderTarget, .shaderRead]
            corticalDepthTexture = device.makeTexture(descriptor: depth)
            bloomTexture = try texture(max(1, (width + 3) / 4), max(1, (height + 3) / 4), "Bright optical emission")
            blurredTexture = try texture(max(1, (width + 3) / 4), max(1, (height + 3) / 4), "Restrained bloom")
        }
        guard let sceneTexture, let corticalDepthTexture, let bloomTexture, let blurredTexture else { throw BrainRendererError.allocationFailed }
        let frame = camera.frame(time: time, aspect: Float(width) / Float(height))
        lastFrame = frame
        let canGoBack = camera.phase == .empty
        if canGoBack != lastCanGoBack {
            lastCanGoBack = canGoBack
            onCanGoBackChanged?(canGoBack)
        }
        let logicalSize = SIMD2(Float(width), Float(height)) / pixelScale
        hoveredRegion = camera.phase == .brain ? pointerPosition.flatMap {
            InteractionController.hitTest(point: $0, regions: regions, frame: frame, size: logicalSize)
        } : nil
        hoveredParticle = camera.phase == .brain ? pointerPosition.flatMap {
            InteractionController.pickParticle(point: $0, particles: particles, frame: frame, size: logicalSize)
        } : nil
        let dt = Float(min(0.1, max(0, time - previousTime)))
        previousTime = time
        if let hoveredParticle {
            hoverParticleID = hoveredParticle
            hoverParticlePosition = particles[hoveredParticle].position.xyz
        }
        let hoverTarget: Float = hoveredParticle == nil ? 0 : 1
        particleHoverAmount += (hoverTarget - particleHoverAmount) * (1 - exp(-dt * VisualConfiguration.hoverResponse))
        if camera.phase != .brain { particleHoverAmount = 0 }
        for i in hoverAmounts.indices {
            let target: Float = hoveredRegion == i ? 1 : 0
            hoverAmounts[i] += (target - hoverAmounts[i]) * (1 - exp(-dt * VisualConfiguration.hoverResponse))
        }
        let c = VisualConfiguration.self
        var uniforms = FrameUniforms(model: frame.model, view: frame.view, projection: frame.projection,
            cameraTime: SIMD4(frame.eye, Float(time)), viewport: SIMD4(Float(width), Float(height), pixelScale, c.cameraStartDistance),
            appearance: SIMD4(c.baseParticleBrightness, c.depthFadeStrength, c.shimmerFraction, c.shimmerAmount),
            accent: SIMD4(c.activeColor, c.activeRadius), activity: SIMD4(c.activePulseAmount, c.activeGlowIntensity, c.hoverExpansion, frame.progress),
            transition: SIMD4(frame.activation, Float(frame.selectedRegion),
                1 - smoothstep(c.fadeStartProgress, 1, frame.progress), 1 - smoothstep(c.violetFadeStartProgress, 1, frame.progress)),
            bloom: SIMD4(c.bloomStrength, c.bloomThreshold, c.exposure, c.backgroundIllumination),
            background: SIMD4(c.backgroundColor, c.corticalContrast), emptyBackground: SIMD4(c.emptyBackgroundColor, c.lightResponseGamma),
            control: SIMD4(Float(regions.count), c.cameraNear, c.cameraFar, c.corticalOcclusionStrength),
            sprite: SIMD4(c.particleSpriteScale, c.hoverDepthTolerance, c.triangleFill, c.triangleStroke),
            hoverPoint: SIMD4(hoverParticlePosition, particleHoverAmount),
            hoverStyle: SIMD4(Float(hoverParticleID), c.hoverFalloffRadius, c.hoverCenterDiameter, c.hoverNeighborDiameter))
        let gpuRegions = regions.enumerated().map { GPURegion(positionPhase: SIMD4($0.element.position, $0.element.phase),
                                                             interaction: SIMD4(hoverAmounts[$0.offset], 0, 0, 0)) }
        let depthPass = MTLRenderPassDescriptor()
        depthPass.depthAttachment.texture = corticalDepthTexture
        depthPass.depthAttachment.loadAction = .clear
        depthPass.depthAttachment.storeAction = .store
        depthPass.depthAttachment.clearDepth = 1
        guard let depthEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: depthPass) else { throw BrainRendererError.allocationFailed }
        if frame.progress < 1 {
            depthEncoder.setRenderPipelineState(corticalDepthPipeline)
            depthEncoder.setDepthStencilState(corticalDepthState)
            depthEncoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
            depthEncoder.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            depthEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: particleCount)
        }
        depthEncoder.endEncoding()
        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = sceneTexture
        scenePass.colorAttachments[0].loadAction = .clear
        scenePass.colorAttachments[0].storeAction = .store
        scenePass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: scenePass) else { throw BrainRendererError.allocationFailed }
        encoder.label = "One draw for all brain particles"
        if frame.progress < 1 {
            encoder.setRenderPipelineState(particlePipeline)
            encoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
            encoder.setVertexTexture(corticalDepthTexture, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            encoder.setVertexBytes(gpuRegions, length: gpuRegions.count * MemoryLayout<GPURegion>.stride, index: 2)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: particleCount)
        }
        encoder.endEncoding()
        guard let compute = commandBuffer.makeComputeCommandEncoder() else { throw BrainRendererError.allocationFailed }
        compute.setComputePipelineState(bloomPipeline)
        compute.setTexture(sceneTexture, index: 0)
        compute.setTexture(bloomTexture, index: 1)
        compute.setBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 0)
        compute.dispatchThreads(MTLSize(width: bloomTexture.width, height: bloomTexture.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        compute.endEncoding()
        blur.encode(commandBuffer: commandBuffer, sourceTexture: bloomTexture, destinationTexture: blurredTexture)
        let finalPass = MTLRenderPassDescriptor()
        finalPass.colorAttachments[0].texture = destination
        finalPass.colorAttachments[0].loadAction = .dontCare
        finalPass.colorAttachments[0].storeAction = .store
        guard let final = commandBuffer.makeRenderCommandEncoder(descriptor: finalPass) else { throw BrainRendererError.allocationFailed }
        final.setRenderPipelineState(compositePipeline)
        final.setFragmentTexture(sceneTexture, index: 0)
        final.setFragmentTexture(blurredTexture, index: 1)
        final.setFragmentBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 0)
        final.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        final.endEncoding()
    }
}
