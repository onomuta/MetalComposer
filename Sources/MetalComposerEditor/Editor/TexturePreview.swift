import CoreImage
import Metal
import MetalComposerKit

/// Small CPU-side snapshots of GPU textures for the editor (port tooltips).
enum TexturePreview {
    private static var context: CIContext?

    static func thumbnail(_ texture: MTLTexture, maxSide: CGFloat = 160) -> CGImage? {
        if context == nil { context = CIContext(mtlDevice: texture.device) }
        guard let context, var image = CIImage(mtlTexture: texture, options: nil) else { return nil }
        // Textures here store the top row first; Core Image's origin is bottom-left.
        image = image.oriented(.downMirrored)
        let scale = min(1, maxSide / max(image.extent.width, image.extent.height))
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(image, from: image.extent)
    }
}
