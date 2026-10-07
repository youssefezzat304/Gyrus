import Foundation
import simd

struct BrainParticle {
    var position: SIMD4<Float> // w = layer: 0 surface, 1 inner, 2 peripheral, 3 active center
    var normal: SIMD4<Float> // w = cortical exposure
    var appearance: SIMD4<Float> // size, brightness, phase, random seed
}

struct ActiveRegion {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var phase: Float
}

struct BrainGeometry {
    var particles: [BrainParticle]
    var regions: [ActiveRegion]
}

enum BrainAssetError: Error { case missingMesh, invalidMesh }

/// The mesh is CPU-only spatial data. There is deliberately no mesh draw path.
enum BrainParticleGenerator {
    private struct Vertex {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
        var exposure: Float
    }

    static func generate(meshURL: URL? = Bundle.main.url(forResource: "Cortex", withExtension: "brainmesh")) throws -> BrainGeometry {
        guard let meshURL else { throw BrainAssetError.missingMesh }
        let data = try Data(contentsOf: meshURL)
        guard data.count >= 12, Array(data.prefix(4)) == Array("GYRS".utf8) else { throw BrainAssetError.invalidMesh }
        var cursor = 4
        func uint() -> UInt32 {
            defer { cursor += 4 }
            return data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)) }
        }
        func float() -> Float { Float(bitPattern: uint()) }
        let vertexCount = Int(uint()), faceCount = Int(uint())
        guard vertexCount > 0, faceCount > 0,
              data.count == 12 + vertexCount * 28 + faceCount * 12 else { throw BrainAssetError.invalidMesh }
        var vertices = [Vertex]()
        vertices.reserveCapacity(vertexCount)
        for _ in 0..<vertexCount {
            let position = SIMD3(float(), float(), float()), normal = SIMD3(float(), float(), float())
            vertices.append(Vertex(position: position, normal: normal, exposure: float()))
        }
        var faces = [SIMD3<Int>](), cumulativeAreas = [Float]()
        var area: Float = 0
        for _ in 0..<faceCount {
            let f = SIMD3(Int(uint()), Int(uint()), Int(uint()))
            guard f.min() >= 0, f.max() < vertexCount else { throw BrainAssetError.invalidMesh }
            let a = vertices[f.x], b = vertices[f.y], c = vertices[f.z]
            let triangleArea = simd_length(simd_cross(b.position - a.position, c.position - a.position)) / 2
            let center = (a.position + b.position + c.position) / 3
            let variation = 0.84 + 0.16 * sin(center.x * 8 + center.y * 4) * cos(center.z * 6)
            area += triangleArea * variation
            cumulativeAreas.append(area)
            faces.append(f)
        }
        guard area.isFinite, area > 0 else { throw BrainAssetError.invalidMesh }
        var rng = SeededRandom(state: VisualConfiguration.seed), particles = [BrainParticle]()
        particles.reserveCapacity(VisualConfiguration.particleCount + VisualConfiguration.activeRegionCount)
        for index in 0..<VisualConfiguration.particleCount {
            let sample = rng.unit() * area
            var low = 0, high = faceCount - 1
            while low < high {
                let middle = (low + high) / 2
                if cumulativeAreas[middle] < sample { low = middle + 1 } else { high = middle }
            }
            let f = faces[low], a = vertices[f.x], b = vertices[f.y], c = vertices[f.z]
            let u = sqrt(rng.unit()), v = rng.unit(), weights = SIMD3(1 - u, u * (1 - v), u * v)
            var p = a.position * weights.x + b.position * weights.y + c.position * weights.z
            let n = simd_normalize(a.normal * weights.x + b.normal * weights.y + c.normal * weights.z)
            let exposure = a.exposure * weights.x + b.exposure * weights.y + c.exposure * weights.z
            let fraction = Float(index) / Float(VisualConfiguration.particleCount)
            var layer: Float = 0, brightness: Float = 0.7 + rng.unit() * 0.6
            var size = VisualConfiguration.particleMinSize
                + pow(rng.unit(), 2) * (VisualConfiguration.particleMaxSize - VisualConfiguration.particleMinSize)
            if fraction >= VisualConfiguration.surfaceParticleRatio + VisualConfiguration.internalParticleRatio {
                layer = 2
                p += n * (0.008 + pow(rng.unit(), 2) * 0.065)
                brightness *= VisualConfiguration.peripheralBrightness
                size *= 0.8
            } else if fraction >= VisualConfiguration.surfaceParticleRatio {
                layer = 1
                let depth = VisualConfiguration.internalDepth.lowerBound
                    + rng.unit() * (VisualConfiguration.internalDepth.upperBound - VisualConfiguration.internalDepth.lowerBound)
                p = (p - n * depth) * (0.93 + rng.unit() * 0.06)
                brightness *= VisualConfiguration.internalBrightness
                size *= 0.82
            } else { p += n * ((rng.unit() - 0.5) * 0.008) }
            particles.append(BrainParticle(position: SIMD4(p, layer), normal: SIMD4(n, exposure),
                appearance: SIMD4(size, brightness, rng.unit() * 2 * .pi, rng.unit())))
        }
        // Pick exposed cortical vertices near art-directed screen positions. Seeds in 3D can
        // accidentally snap to a buried wall between gyri, making activation invisible.
        let seeds: [SIMD2<Float>] = [SIMD2(-0.22, 0.34), SIMD2(0.13, 0.36),
            SIMD2(-0.29, 0.02), SIMD2(0.24, 0.03), SIMD2(-0.19, -0.33),
            SIMD2(0.13, -0.35), SIMD2(-0.04, 0.56), SIMD2(0.31, 0.28),
            SIMD2(-0.12, 0.10), SIMD2(0.02, -0.12), SIMD2(-0.38, 0.20), SIMD2(0.34, -0.15)]
        let model = brainTransform(time: 0)
        let eye = SIMD3<Float>(0, 0, VisualConfiguration.cameraStartDistance)
        let viewProjection = perspective(fov: VisualConfiguration.cameraFOV, aspect: 1.5,
            near: VisualConfiguration.cameraNear, far: VisualConfiguration.cameraFar)
            * lookAt(eye: eye, target: VisualConfiguration.cameraTarget)
        let candidates = vertices.map { vertex -> (Vertex, SIMD2<Float>, Float) in
            let world = model * SIMD4(vertex.position, 1)
            let clip = viewProjection * world
            return (vertex, SIMD2(clip.x, clip.y) / clip.w, world.z)
        }
        var regions = [ActiveRegion]()
        for (index, seed) in seeds.prefix(VisualConfiguration.activeRegionCount).enumerated() {
            var nearby = candidates.filter { simd_length($0.1 - seed) < 0.045 }
            if nearby.isEmpty {
                nearby = [candidates.min { simd_length_squared($0.1 - seed) < simd_length_squared($1.1 - seed) }!]
            }
            let front = nearby.map { $0.2 }.max()!
            let vertex = nearby.filter { $0.2 > front - 0.025 }.max {
                func score(_ candidate: (Vertex, SIMD2<Float>, Float)) -> Float {
                    let world = (model * SIMD4(candidate.0.position, 1)).xyz
                    let n = simd_normalize((model * SIMD4(candidate.0.normal, 0)).xyz)
                    return candidate.0.exposure + max(0, simd_dot(n, simd_normalize(eye - world)))
                }
                return score($0) < score($1)
            }!.0
            let p = vertex.position + vertex.normal * 0.005
            regions.append(ActiveRegion(position: p, normal: vertex.normal, phase: Float(index) * 2.399))
            particles.append(BrainParticle(position: SIMD4(p, 3), normal: SIMD4(vertex.normal, 1),
                appearance: SIMD4(VisualConfiguration.particleMinSize * VisualConfiguration.activeCenterScale,
                                  1.7, Float(index) * 2.399, Float(index))))
        }
        return BrainGeometry(particles: particles, regions: regions)
    }
}

private struct SeededRandom {
    var state: UInt64
    mutating func unit() -> Float {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        z ^= z >> 31
        return Float(z >> 40) / Float(1 << 24)
    }
}
