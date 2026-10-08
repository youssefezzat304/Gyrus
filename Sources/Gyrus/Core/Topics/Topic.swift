import Foundation
import simd

struct BrainAnchor: Codable, Equatable {
    let particleID: Int
    let position: SIMD3<Float>
    let normal: SIMD3<Float>
}

struct Keyword: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    let position: SIMD3<Float>
    let phase: Float
}

struct KeywordConnection: Codable, Equatable, Hashable {
    let first: UUID
    let second: UUID

    init(_ a: UUID, _ b: UUID) {
        (first, second) = a.uuidString < b.uuidString ? (a, b) : (b, a)
    }
}

struct Topic: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    let anchor: BrainAnchor
    var keywords: [Keyword] = []
    var connections: [KeywordConnection] = []
}

enum TopicText {
    static func cleaned(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    static func key(_ text: String) -> String {
        cleaned(text).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    static func validName(_ text: String) -> Bool { !cleaned(text).isEmpty && cleaned(text).count <= 120 }
}

/// Entry drafts are isolated from the topic until the user explicitly presses Add.
struct KeywordDraft {
    var text = ""
    private(set) var names: [String] = []
    private(set) var error: String?

    @discardableResult
    mutating func stage(existing: [Keyword]) -> Bool {
        let name = TopicText.cleaned(text)
        guard TopicText.validName(name) else {
            error = name.isEmpty ? "Type a keyword first." : "Use 120 characters or fewer."
            return false
        }
        let used = Set(existing.map { TopicText.key($0.name) } + names.map { TopicText.key($0) })
        guard !used.contains(TopicText.key(name)) else {
            error = "This keyword is already in the space or your list."
            return false
        }
        names.append(name)
        text = ""
        error = nil
        return true
    }

    mutating func remove(at index: Int) {
        guard names.indices.contains(index) else { return }
        names.remove(at: index)
    }
}

enum KeywordPlacement {
    static func next(avoiding existing: [Keyword]) -> SIMD3<Float> {
        var best = SIMD3<Float>(1, 0, 0), bestDistance: Float = -1
        for _ in 0..<96 {
            let angle = Float.random(in: 0..<(2 * .pi))
            let radius = Float.random(in: 0.72...1.85)
            let candidate = SIMD3(cos(angle) * radius, sin(angle) * radius * 0.76, Float.random(in: -0.85...0.85))
            let nearest = existing.map {
                simd_distance(SIMD2($0.position.x, $0.position.y), SIMD2(candidate.x, candidate.y))
            }.min() ?? 10
            if nearest > 0.28 { return candidate }
            if nearest > bestDistance { best = candidate; bestDistance = nearest }
        }
        return best
    }
}

enum TopicProjection {
    static func frame(size: SIMD2<Float>, orbit: SIMD2<Float>) -> CameraFrame {
        let yaw = simd_quatf(angle: orbit.x, axis: SIMD3<Float>(0, 1, 0))
        let pitch = simd_quatf(angle: orbit.y, axis: SIMD3<Float>(1, 0, 0))
        let eye = SIMD3<Float>(0, 0, 7.8)
        return CameraFrame(model: simd_float4x4(pitch * yaw),
            view: lookAt(eye: eye, target: .zero),
            projection: perspective(fov: VisualConfiguration.cameraFOV, aspect: max(0.1, size.x / max(1, size.y)),
                                    near: 0.01, far: 30),
            eye: eye, progress: 0, activation: 0, selectedRegion: -1)
    }

    static func pick(point: SIMD2<Float>, keywords: [Keyword], frame: CameraFrame, size: SIMD2<Float>) -> UUID? {
        keywords.compactMap { keyword -> (UUID, Float, Float)? in
            guard let screen = InteractionController.project(keyword.position, frame: frame, size: size) else { return nil }
            let distance = simd_distance(point, screen)
            guard distance < 18 else { return nil }
            let depth = -(frame.view * frame.model * SIMD4(keyword.position, 1)).z
            return (keyword.id, distance, depth)
        }.min { a, b in abs(a.1 - b.1) < 2 ? a.2 < b.2 : a.1 < b.1 }?.0
    }
}
