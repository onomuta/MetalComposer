import SwiftUI
import MetalComposerKit

/// A rotary control. Drag up/right to increase, down/left to decrease; ⌥ for fine, ⇧ for coarse
/// steps; double-click to reset.
/// - With a suggested `range` it shows a 270° arc and 200 points of drag cover the range, but the
///   value may keep going past either end (the arc just stays pinned).
/// - Without one it turns endlessly, `step` per point (one indicator turn = 360 steps, so an
///   angle knob points the way the angle does).
/// - `limits` are the only hard bounds.
struct Knob: View {
    @Binding var value: Double
    var range: ClosedRange<Double>?
    var limits: ClosedRange<Double>?
    var step: Double?
    var defaultValue: Double
    var size: CGFloat = Knob.defaultSize

    /// Bigger with touch, so a finger can grab it.
    #if os(macOS)
    static let defaultSize: CGFloat = 22
    #else
    static let defaultSize: CGFloat = 30
    #endif

    @State private var dragStart: Double?

    private static let sweep = 270.0      // degrees covered by a ranged knob
    private static let startAngle = 135.0 // 0 points right, clockwise; this is the bottom-left stop

    /// Change in value per point dragged, from the value the drag started at so the speed stays constant.
    private func sensitivity(from base: Double) -> Double {
        if let range { return (range.upperBound - range.lowerBound) / 200 }
        if let step { return step }
        return max(abs(base), 1) * 0.005
    }

    private func clamped(_ v: Double) -> Double {
        guard let limits else { return v }
        return min(max(v, limits.lowerBound), limits.upperBound)
    }

    /// 0…1 position of the indicator.
    private var fraction: Double {
        if let range, range.upperBound > range.lowerBound {
            return min(max((value - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
        }
        // Endless: one indicator turn per 360 steps (10 units without a step), pointing up at 0.
        let turns = value / ((step ?? 10.0 / 360) * 360)
        return turns - floor(turns)
    }

    var body: some View {
        Canvas { ctx, canvasSize in
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let r = min(canvasSize.width, canvasSize.height) / 2 - 1.5

            ctx.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                     with: .color(Color.controlBackground))
            ctx.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                       with: .color(.secondary.opacity(0.5)), lineWidth: 1)

            let angle: Double
            if range != nil {
                // Track and filled arc from the minimum stop to the current value.
                var track = Path()
                track.addArc(center: center, radius: r - 2.5, startAngle: .degrees(Self.startAngle),
                             endAngle: .degrees(Self.startAngle + Self.sweep), clockwise: false)
                ctx.stroke(track, with: .color(.secondary.opacity(0.25)), lineWidth: 2)
                angle = Self.startAngle + Self.sweep * fraction
                var filled = Path()
                filled.addArc(center: center, radius: r - 2.5, startAngle: .degrees(Self.startAngle),
                              endAngle: .degrees(angle), clockwise: false)
                ctx.stroke(filled, with: .color(.accentColor), lineWidth: 2)
            } else {
                angle = -90 + 360 * fraction
            }

            let rad = angle * .pi / 180
            var pointer = Path()
            pointer.move(to: CGPoint(x: center.x + cos(rad) * r * 0.2, y: center.y + sin(rad) * r * 0.2))
            pointer.addLine(to: CGPoint(x: center.x + cos(rad) * (r - 4.5), y: center.y + sin(rad) * (r - 4.5)))
            ctx.stroke(pointer, with: .color(.primary), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { g in
                    let start = dragStart ?? value
                    dragStart = start
                    let scale = HeldKeys.option ? 0.1 : (HeldKeys.shift ? 10 : 1)
                    value = clamped(start + (g.translation.width - g.translation.height) * sensitivity(from: start) * scale)
                }
                .onEnded { _ in dragStart = nil }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded { value = defaultValue })
        .onHover(perform: ResizeCursor.upDown.set)
        .help("Drag to change (⌥ fine, ⇧ coarse) · double-click to reset")
        .accessibilityElement()
        .accessibilityLabel("Knob")
        .accessibilityValue(Text(verbatim: String(format: "%.3f", value)))
        .accessibilityAdjustableAction { direction in
            let increment = sensitivity(from: value) * 10
            value = clamped(value + (direction == .increment ? increment : -increment))
        }
    }
}
