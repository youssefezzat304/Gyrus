import Foundation
import simd

enum BrainPhase: Equatable {
    case brain, diving(region: Int, startedAt: Double), empty, returning(startedAt: Double)
}

struct CameraFrame {
    var model: simd_float4x4
    var view: simd_float4x4
    var projection: simd_float4x4
    var eye: SIMD3<Float>
    var progress: Float
    var activation: Float
    var selectedRegion: Int
    var viewProjection: simd_float4x4 { projection * view }
}

final class CameraController {
    private(set) var phase: BrainPhase = .brain
    private var diveModel = matrix_identity_float4x4
    private var entry = SIMD3<Float>(repeating: 0)
    private var startEye = SIMD3<Float>(0, 0, VisualConfiguration.cameraStartDistance)
    private var orbitRotation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    private var idleTimeOffset: Double = 0
    private var diveBrainTime: Double = 0
    private var selectedRegion = -1

    func rotate(by delta: SIMD2<Float>) {
        guard phase == .brain else { return }
        let yaw = simd_quatf(angle: delta.x * VisualConfiguration.dragSensitivity, axis: SIMD3<Float>(0, 1, 0))
        let pitch = simd_quatf(angle: delta.y * VisualConfiguration.dragSensitivity, axis: SIMD3<Float>(1, 0, 0))
        orbitRotation = simd_normalize(pitch * yaw * orbitRotation)
    }

    func beginReturn(time: Double) {
        guard phase == .empty else { return }
        phase = .returning(startedAt: time)
    }

    func beginDive(region: Int, regions: [ActiveRegion], time: Double, aspect: Float) {
        guard phase == .brain, regions.indices.contains(region) else { return }
        beginDive(at: regions[region].position, selectedRegion: region, time: time, aspect: aspect)
    }

    func beginDive(at position: SIMD3<Float>, selectedRegion region: Int = -1, time: Double, aspect: Float) {
        guard phase == .brain else { return }
        let current = frame(time: time, aspect: aspect)
        diveModel = current.model
        diveBrainTime = time - idleTimeOffset
        selectedRegion = region
        entry = (diveModel * SIMD4(position, 1)).xyz
        startEye = current.eye
        phase = .diving(region: region, startedAt: time)
    }

    func frame(time: Double, aspect: Float) -> CameraFrame {
        let c = VisualConfiguration.self
        let projection = perspective(fov: c.cameraFOV, aspect: max(aspect, 0.1), near: c.cameraNear, far: c.cameraFar)
        var model = simd_float4x4(orbitRotation) * brainTransform(time: Float(time - idleTimeOffset))
        var eye = SIMD3<Float>(0, 0, c.cameraStartDistance), target = c.cameraTarget
        var progress: Float = 0, activation: Float = 0, selected = -1
        switch phase {
        case .brain: break
        case let .diving(_, startedAt):
            progress = min(1, max(0, Float((time - startedAt) / c.diveDuration)))
            if progress >= 1 { phase = .empty }
        case .empty:
            progress = 1
        case let .returning(startedAt):
            let fraction = min(1, max(0, Float((time - startedAt) / c.returnDuration)))
            progress = 1 - smoothstep(0, 1, fraction)
            if fraction >= 1 {
                phase = .brain
                // Resume idle movement from the frozen pose, preserving the user's rotation.
                idleTimeOffset = time - diveBrainTime
                model = diveModel
            }
        }
        if phase != .brain {
            selected = selectedRegion
            activation = smoothstep(0, c.activationDuration / Float(c.diveDuration), progress)
            model = diveModel
            let alignment = smoothstep(0.025, c.diveAlignmentEnd, progress)
            target = mix(c.cameraTarget, entry, alignment)
            let travel = pow(smoothstep(0.075, 1, progress), c.diveAcceleration)
            let direction = simd_normalize(entry - startEye)
            eye = mix(startEye, entry + direction * c.diveTravelBeyondSurface, travel)
            target = mix(target, eye + direction, alignment)
        }
        return CameraFrame(model: model, view: lookAt(eye: eye, target: target), projection: projection,
                           eye: eye, progress: progress, activation: activation, selectedRegion: selected)
    }
}

/// Clicks test eight active centers; hover picks visible surface particles in one batched scan.
/// Coordinates use a top-left origin.
enum InteractionController {
    static func pickParticle(point: SIMD2<Float>, particles: [BrainParticle], frame: CameraFrame,
                             size: SIMD2<Float>) -> Int? {
        let modelView = frame.view * frame.model
        let mvp = frame.projection * modelView
        let localEye = (frame.model.inverse * SIMD4(frame.eye, 1)).xyz
        let radiusSquared = VisualConfiguration.particleHitRadius * VisualConfiguration.particleHitRadius
        var candidates: [(index: Int, distance: Float, depth: Float)] = []
        var frontDepth = Float.greatestFiniteMagnitude
        for (index, p) in particles.enumerated() {
            // Inner and drifting peripheral particles do not steal the surface's hover.
            guard p.position.w == 0 || p.position.w == 3 else { continue }
            let clip = mvp * SIMD4(p.position.xyz, 1)
            guard clip.w > 0, clip.z >= 0, clip.z <= clip.w else { continue }
            let screen = SIMD2((clip.x / clip.w * 0.5 + 0.5) * size.x,
                               (0.5 - clip.y / clip.w * 0.5) * size.y)
            let distance = simd_length_squared(screen - point)
            guard distance < radiusSquared,
                  simd_dot(p.normal.xyz, simd_normalize(localEye - p.position.xyz)) > 0.12 else { continue }
            let depth = -(modelView * SIMD4(p.position.xyz, 1)).z
            frontDepth = min(frontDepth, depth)
            candidates.append((index, distance, depth))
        }
        // Reject back walls in a fold before choosing the closest projected ball.
        return candidates.filter { $0.depth <= frontDepth + 0.055 }
            .min { $0.distance < $1.distance }?.index
    }

    static func isFacingCamera(_ region: ActiveRegion, frame: CameraFrame) -> Bool {
        let world = (frame.model * SIMD4(region.position, 1)).xyz
        let normal = simd_normalize((frame.model * SIMD4(region.normal, 0)).xyz)
        return simd_dot(normal, simd_normalize(frame.eye - world)) > 0.04
    }

    static func project(_ position: SIMD3<Float>, frame: CameraFrame, size: SIMD2<Float>) -> SIMD2<Float>? {
        let clip = frame.viewProjection * frame.model * SIMD4(position, 1)
        guard clip.w > 0 else { return nil }
        let ndc = clip.xyz / clip.w
        guard ndc.z >= 0, ndc.z <= 1, abs(ndc.x) <= 1, abs(ndc.y) <= 1 else { return nil }
        return SIMD2((ndc.x * 0.5 + 0.5) * size.x, (0.5 - ndc.y * 0.5) * size.y)
    }
    static func hitTest(point: SIMD2<Float>, regions: [ActiveRegion], frame: CameraFrame, size: SIMD2<Float>) -> Int? {
        var nearest: Int?, distance = VisualConfiguration.hoverRadius
        for (index, region) in regions.enumerated() {
            guard isFacingCamera(region, frame: frame) else { continue }
            guard let screen = project(region.position, frame: frame, size: size) else { continue }
            let d = simd_length(screen - point)
            if d < distance { nearest = index; distance = d }
        }
        return nearest
    }
}
