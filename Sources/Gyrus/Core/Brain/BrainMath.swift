import simd

func smoothstep(_ lower: Float, _ upper: Float, _ value: Float) -> Float {
    let t = min(1, max(0, (value - lower) / (upper - lower)))
    return t * t * (3 - 2 * t)
}

func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * t }

func perspective(fov: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let y = 1 / tan(fov / 2), z = far / (near - far)
    return simd_float4x4(columns: (
        SIMD4(y / aspect, 0, 0, 0), SIMD4(0, y, 0, 0),
        SIMD4(0, 0, z, -1), SIMD4(0, 0, near * z, 0)))
}

func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>) -> simd_float4x4 {
    let z = simd_normalize(eye - target)
    let x = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), z)), y = simd_cross(z, x)
    return simd_float4x4(columns: (
        SIMD4(x.x, y.x, z.x, 0), SIMD4(x.y, y.y, z.y, 0), SIMD4(x.z, y.z, z.z, 0),
        SIMD4(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)))
}

func brainTransform(time: Float) -> simd_float4x4 {
    let c = VisualConfiguration.self
    let yaw = c.brainYaw + sin(time * c.idleRotationSpeed) * c.idleYawAmount
    let pitch = c.brainPitch + sin(time * 0.13) * c.idlePitchAmount
    let rotation = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0))
    var result = simd_float4x4(rotation)
    result.columns.0 *= c.brainScale
    result.columns.1 *= c.brainScale
    result.columns.2 *= c.brainScale
    result.columns.3.y = sin(time * 0.31) * c.idleFloatAmount
    return result
}

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
