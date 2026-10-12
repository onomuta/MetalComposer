import CoreText
import Foundation

/// One character of a string at a time, measured the way Text Image lays it out, for animating text
/// letter by letter: in an Iterator, give Iterations the Count and Index the iteration index, draw
/// Character with a Text Image of the same font, weight and spacing, and place it with X and Width.
///
/// X, Width and Line Width are in text heights (the height of a Text Image of this font), so they
/// work at any font size: to show the text H tall, give a Billboard Width × H as its width (height
/// auto) and put it at X × H. X is the character's centre, measured from the centre of the line.
/// A string with several lines is measured as one line (line breaks count as spaces).
package final class TextCharactersPatch: Patch {
    package override class var typeID: String { "text-characters" }
    package override class var title: String { "Text Characters" }
    package override class var summary: String {
        "One character of a string by index, with the count and where Text Image places it, for letter-by-letter animation."
    }
    package override class var inputSpecs: [PortSpec] {
        [.string("text", "String", "Hello"), .index("index", "Index"),
         .font("font", "Font"), .fontStyle("fontStyle", "Weight", "Bold"),
         .menu("spacing", "Spacing", ["Proportional", "Monospaced Digits", "Monospaced"])]
    }
    package override class var outputSpecs: [PortSpec] {
        [.string("character", "Character"), .number("count", "Count"),
         .number("x", "X"), .number("width", "Width"), .number("lineWidth", "Line Width")]
    }

    /// A string split into characters, with each one's centre and Text Image width in text heights.
    package struct Measured: Equatable {
        package var characters: [String]
        package var centers: [Double]
        package var widths: [Double]
        package var lineWidth: Double
    }

    /// Measuring at a large size keeps the rounding of image sizes from showing in the ratios.
    private static let measuringSize = 200.0

    package static func measure(_ text: String, family: String, style: String, spacing: Int) -> Measured {
        let characters = Array(text)
        guard !characters.isEmpty else { return Measured(characters: [], centers: [], widths: [], lineWidth: 0) }
        let font = TextImagePatch.resolvedFont(family: family, style: style, size: measuringSize)
        let line = String(characters.map { $0.isNewline ? " " : $0 })
        let lineLayout = TextLayout.make(line, font: font, spacing: spacing)
        let height = lineLayout.size.height
        let padding = TextLayout.padding

        // Each character's centre across the line image, in points.
        var centers: [CGFloat] = []
        if spacing == 0 {
            // The font's own advances and kerning, as Core Text sets the whole line.
            let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [.font: font]))
            var offset = 0
            for c in Array(line) {
                let length = c.utf16.count
                let start = CTLineGetOffsetForStringIndex(ctLine, offset, nil)
                let end = CTLineGetOffsetForStringIndex(ctLine, offset + length, nil)
                centers.append(padding + (start + end) / 2)
                offset += length
            }
        } else {
            // Cells, as TextLayout.make places them.
            let metrics = CharacterMetrics.shared
            let cells = metrics.cells(font)
            let cell = max(cells.alphanumeric, line.map { metrics.of($0, font).advance }.max() ?? 0)
            var x = padding
            for c in line {
                let slot = spacing == 2 ? cell : (c.isASCII && c.isNumber ? cells.digit : metrics.of(c, font).advance)
                centers.append(x + slot / 2)
                x += slot
            }
        }
        let middle = lineLayout.size.width / 2
        return Measured(
            characters: characters.map(String.init),
            centers: centers.map { Double(($0 - middle) / height) },
            widths: Array(line).map { Double(TextLayout.make(String($0), font: font, spacing: spacing).size.width / height) },
            lineWidth: Double(lineLayout.size.width / height))
    }

    /// The last measurement: an Iterator asks for every index of the same string each frame.
    private var measured: (key: String, value: Measured)?

    package override func reset() { measured = nil }

    package override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        let text = i.string("text"), family = i.string("font"), style = i.string("fontStyle"), spacing = i.int("spacing")
        let key = "\(text)|\(family)|\(style)|\(spacing)"
        let m: Measured
        if let hit = measured, hit.key == key {
            m = hit.value
        } else {
            m = Self.measure(text, family: family, style: style, spacing: spacing)
            measured = (key, m)
        }
        let index = i.int("index")
        var out: [String: Value] = ["count": .number(Double(m.characters.count)), "lineWidth": .number(m.lineWidth)]
        if m.characters.indices.contains(index) {
            out["character"] = .string(m.characters[index])
            out["x"] = .number(m.centers[index])
            out["width"] = .number(m.widths[index])
        } else {
            out["character"] = .string("")
            out["x"] = .number(0)
            out["width"] = .number(0)
        }
        return out
    }
}
