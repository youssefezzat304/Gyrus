import SwiftUI
import MetalKit

struct TopicMetalView: NSViewRepresentable {
    let topic: Topic
    @ObservedObject var interaction: KeywordInteraction
    @ObservedObject var store: TopicStore

    func makeNSView(context: Context) -> KeywordMetalView {
        let view = KeywordMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        if let device = view.device {
            do { view.renderer = try TopicRenderer(device: device); view.delegate = view.renderer }
            catch { NSLog("Could not initialize topic space: %@", String(describing: error)) }
        }
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: KeywordMetalView, context: Context) {
        view.interaction = interaction
        view.store = store
        view.renderer?.topic = topic
        view.renderer?.selected = interaction.selected
        view.renderer?.orbit = interaction.orbit
        view.setAccessibilityLabel("Keywords in \(topic.name)")
        view.needsDisplay = true
    }
}

final class KeywordMetalView: MTKView {
    var renderer: TopicRenderer?
    weak var interaction: KeywordInteraction?
    weak var store: TopicStore?
    private var press: SIMD2<Float>?
    private var last: SIMD2<Float>?
    private var didDrag = false
    private var accessibleKeywords: [UUID: KeywordAccessibilityElement] = [:]

    override func accessibilityChildren() -> [Any]? {
        guard let topic = renderer?.topic, let interaction else { return [] }
        let size = SIMD2(Float(bounds.width), Float(bounds.height))
        let frame = TopicProjection.frame(size: size, orbit: interaction.orbit)
        let ids = Set(topic.keywords.map(\.id))
        accessibleKeywords = accessibleKeywords.filter { ids.contains($0.key) }
        return topic.keywords.compactMap { keyword -> KeywordAccessibilityElement? in
            guard let point = InteractionController.project(keyword.position, frame: frame, size: size) else { return nil }
            let element = accessibleKeywords[keyword.id] ?? KeywordAccessibilityElement()
            accessibleKeywords[keyword.id] = element
            element.setAccessibilityElement(true)
            element.setAccessibilityEnabled(true)
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(keyword.name)
            element.setAccessibilityValue(interaction.selected == keyword.id ? "Selected" : "")
            element.setAccessibilityHelp(interaction.connectionSource == nil ? "Select this keyword" : "Connect the selected keyword to this one")
            element.setAccessibilityParent(self)
            let local = NSRect(x: CGFloat(point.x) - 18, y: bounds.height - CGFloat(point.y) - 18, width: 36, height: 36)
            let inWindow = convert(local, to: nil)
            element.setAccessibilityFrame(window?.convertToScreen(inWindow) ?? inWindow)
            element.press = { [weak self] in
                guard let self, let store = self.store else { return }
                self.interaction?.select(keyword.id, topicID: topic.id, store: store)
            }
            return element
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private func point(_ event: NSEvent) -> SIMD2<Float> {
        let p = convert(event.locationInWindow, from: nil)
        return SIMD2(Float(p.x), Float(isFlipped ? p.y : bounds.height - p.y))
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        press = point(event); last = press; didDrag = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let press, let last else { return }
        let current = point(event)
        guard didDrag || simd_distance(current, press) >= VisualConfiguration.dragThreshold else { return }
        didDrag = true
        interaction?.orbit += (current - last) * VisualConfiguration.dragSensitivity
        self.last = current
    }
    override func mouseUp(with event: NSEvent) {
        defer { press = nil; last = nil; didDrag = false }
        guard press != nil, !didDrag, let topic = renderer?.topic, let store, let interaction else { return }
        let size = SIMD2(Float(bounds.width), Float(bounds.height))
        let frame = TopicProjection.frame(size: size, orbit: interaction.orbit)
        let id = TopicProjection.pick(point: point(event), keywords: topic.keywords, frame: frame, size: size)
        interaction.select(id, topicID: topic.id, store: store)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { interaction?.cancelConnection() }
        else { super.keyDown(with: event) }
    }
}

private final class KeywordAccessibilityElement: NSAccessibilityElement {
    var press: (() -> Void)?
    override func accessibilityPerformPress() -> Bool {
        guard let press else { return false }
        press()
        return true
    }
}
