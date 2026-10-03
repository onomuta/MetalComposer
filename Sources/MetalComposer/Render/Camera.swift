import simd

extension simd_float4x4 {
    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t.x, t.y, t.z, 1)
        return m
    }

    static func scale(_ s: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(diagonal: SIMD4(s.x, s.y, s.z, 1))
    }

    /// Rotation by Euler angles in degrees, applied X first, then Y, then Z.
    static func rotation(degrees r: SIMD3<Float>) -> simd_float4x4 {
        let rad = r * (.pi / 180)
        let rx = simd_quatf(angle: rad.x, axis: SIMD3(1, 0, 0))
        let ry = simd_quatf(angle: rad.y, axis: SIMD3(0, 1, 0))
        let rz = simd_quatf(angle: rad.z, axis: SIMD3(0, 0, 1))
        return simd_float4x4(rz * ry * rx)
    }
}

/// The fixed QC-style camera: at z = 0 the visible area spans x -1…1 and y ±height/width,
/// so 2D patches keep their composition units while z adds perspective.
enum Camera {
    static let distance: Float = 2
    static let near: Float = 0.01
    static let far: Float = 100

    static let view = simd_float4x4.translation(SIMD3(0, 0, -distance))

    static func projection(aspect: Float) -> simd_float4x4 {
        let xs = distance               // maps x = ±1 at z = 0 to the viewport edges
        let ys = distance * aspect
        let zs = far / (near - far)     // Metal clip depth 0…1
        return simd_float4x4(columns: (SIMD4(xs, 0, 0, 0), SIMD4(0, ys, 0, 0),
                                       SIMD4(0, 0, zs, -1), SIMD4(0, 0, zs * near, 0)))
    }
}
