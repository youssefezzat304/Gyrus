import SwiftUI
import MetalKit
import Combine

final class BrainSession: ObservableObject {
    @Published var canGoBack = false
    var onBack: (() -> Void)?
    func goBack() { onBack?() }
}

struct BrainView: NSViewRepresentable {
    @ObservedObject var session: BrainSession

    func makeNSView(context: Context) -> ParticleMetalView {
        let view = ParticleMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(3 / 255, 3 / 255, 5 / 255, 1)
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.framebufferOnly = true
        do {
            guard let device = view.device else { throw BrainRendererError.unavailableMetal }
            let renderer = try BrainRenderer(device: device, geometry: BrainParticleGenerator.generate())
            view.renderer = renderer
            view.delegate = renderer
            renderer.onCanGoBackChanged = { [weak session] available in
                session?.canGoBack = available
            }
            session.onBack = { [weak view] in
                guard let view, view.renderer?.returnToBrain() == true else { return }
                view.enableSetNeedsDisplay = false
                view.isPaused = false
            }
        } catch {
            // Initialization failures are developer diagnostics, never placeholder product UI.
            NSLog("Could not initialize particle brain: %@", String(describing: error))
            view.isPaused = true
        }
        return view
    }
    func updateNSView(_ nsView: ParticleMetalView, context: Context) {}
}

final class ParticleMetalView: MTKView {
    var renderer: BrainRenderer?
    private var mouseTracking: NSTrackingArea?
    private var pressPosition: SIMD2<Float>?
    private var lastDragPosition: SIMD2<Float>?
    private var didDrag = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseTracking { removeTrackingArea(mouseTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        mouseTracking = tracking
    }
    private func position(_ event: NSEvent) -> SIMD2<Float> {
        let point = convert(event.locationInWindow, from: nil)
        return SIMD2(Float(point.x), Float(isFlipped ? point.y : bounds.height - point.y))
    }
    override func mouseMoved(with event: NSEvent) { renderer?.pointerPosition = position(event) }
    override func mouseEntered(with event: NSEvent) { renderer?.pointerPosition = position(event) }
    override func mouseExited(with event: NSEvent) { renderer?.pointerPosition = nil }
    override func mouseDown(with event: NSEvent) {
        guard renderer?.camera.phase == .brain else { return }
        pressPosition = position(event)
        lastDragPosition = pressPosition
        didDrag = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let pressPosition, let lastDragPosition else { return }
        let current = position(event)
        guard didDrag || simd_distance(current, pressPosition) >= VisualConfiguration.dragThreshold else { return }
        didDrag = true
        renderer?.pointerPosition = nil
        renderer?.camera.rotate(by: current - lastDragPosition)
        self.lastDragPosition = current
    }
    override func mouseUp(with event: NSEvent) {
        guard pressPosition != nil else { return }
        renderer?.pointerPosition = position(event)
        if !didDrag { renderer?.click(size: SIMD2(Float(bounds.width), Float(bounds.height))) }
        pressPosition = nil
        lastDragPosition = nil
        didDrag = false
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.backgroundColor = NSColor(red: 3 / 255, green: 3 / 255, blue: 5 / 255, alpha: 1)
        window?.titlebarAppearsTransparent = true
        window?.titleVisibility = .hidden
    }
}
