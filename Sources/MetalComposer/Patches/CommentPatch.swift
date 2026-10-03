import CoreGraphics
import Foundation

/// A sticky note on the canvas. It has no ports and never executes; being a patch means it
/// moves, copies, undoes, saves and groups into macros like everything else.
final class CommentPatch: Patch {
    override class var typeID: String { "comment" }
    override class var title: String { "Comment" }
    override class var librarySection: String { "Utility" }
    override class var summary: String { "A note on the canvas. Double-click to edit; drag the corner to resize." }

    static let palette: [(name: String, rgb: SIMD3<Double>)] = [
        ("Yellow", SIMD3(0.98, 0.86, 0.45)), ("Blue", SIMD3(0.55, 0.75, 0.98)),
        ("Green", SIMD3(0.6, 0.9, 0.6)), ("Pink", SIMD3(0.98, 0.65, 0.78)), ("Gray", SIMD3(0.78, 0.78, 0.8)),
    ]

    override class var inputSpecs: [PortSpec] {
        [PortSpec.string("text", "Text", "", isPort: false, multiline: true),
         PortSpec.menu("color", "Color", palette.map(\.name)).setting(),
         PortSpec.number("width", "Width", 240).hiddenSetting(),
         PortSpec.number("height", "Height", 110).hiddenSetting()]
    }

    static let minSize = CGSize(width: 80, height: 40)

    var size: CGSize {
        CGSize(width: max(Self.minSize.width, params["width"]?.number ?? 240),
               height: max(Self.minSize.height, params["height"]?.number ?? 110))
    }

    var text: String { params["text"]?.string ?? "" }

    var rgb: SIMD3<Double> {
        let i = Int(params["color"]?.number ?? 0)
        return Self.palette.indices.contains(i) ? Self.palette[i].rgb : Self.palette[0].rgb
    }
}
