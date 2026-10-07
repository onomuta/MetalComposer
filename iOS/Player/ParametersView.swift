import MetalComposerKit
import SwiftUI

/// Controls for the composition's top-level Macro Inputs.
struct ParametersView: View {
    let player: CompositionPlayer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                ForEach(player.parameters) { parameter in
                    ParameterRow(player: player, parameter: parameter)
                }
            }
            .navigationTitle("Parameters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") {
                        player.parameters.forEach { player.setValue($0.defaultValue, forParameter: $0.key) }
                        // Rebuild the rows so they show the defaults.
                        resetCount += 1
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .id(resetCount)
        }
    }

    @State private var resetCount = 0
}

private struct ParameterRow: View {
    let player: CompositionPlayer
    let parameter: CompositionParameter
    @State private var value: CompositionValue

    init(player: CompositionPlayer, parameter: CompositionParameter) {
        self.player = player
        self.parameter = parameter
        _value = State(initialValue: player.value(forParameter: parameter.key) ?? parameter.defaultValue)
    }

    var body: some View {
        switch value {
        case .number(let n):
            VStack(alignment: .leading) {
                HStack {
                    Text(parameter.name)
                    Spacer()
                    TextField("", value: number, format: .number.precision(.fractionLength(0...3)))
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(maxWidth: 100)
                }
                // Macro Inputs don't carry a range, so guess one from the default.
                Slider(value: number, in: Self.range(around: parameter.defaultValue, current: n))
            }
        case .boolean:
            Toggle(parameter.name, isOn: Binding(get: { if case .boolean(let b) = value { return b } else { return false } },
                                                 set: { set(.boolean($0)) }))
        case .color(let c):
            ColorPicker(parameter.name, selection: Binding(
                get: { CGColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: CGFloat(c.w)) },
                set: { color in
                    let srgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil) ?? color
                    let comps = (srgb.components ?? [0, 0, 0, 1]).map(Float.init)
                    set(.color(comps.count >= 4 ? SIMD4(comps[0], comps[1], comps[2], comps[3]) : SIMD4(comps[0], comps[0], comps[0], 1)))
                }))
        case .string(let s):
            HStack {
                Text(parameter.name)
                TextField(parameter.name, text: Binding(get: { s }, set: { set(.string($0)) }))
                    .multilineTextAlignment(.trailing)
            }
        case .image:
            LabeledContent(parameter.name, value: "Image (not editable here)")
        }
    }

    private var number: Binding<Double> {
        Binding(get: { if case .number(let n) = value { return n } else { return 0 } },
                set: { set(.number($0)) })
    }

    private func set(_ new: CompositionValue) {
        value = new
        player.setValue(new, forParameter: parameter.key)
    }

    /// 0…1 for defaults in that range, otherwise ± twice the default's size; widened to include
    /// a value typed outside it.
    private static func range(around defaultValue: CompositionValue, current: Double) -> ClosedRange<Double> {
        guard case .number(let d) = defaultValue else { return 0...1 }
        var lo = 0.0, hi = 1.0
        if !(0...1).contains(d) {
            let span = max(1, abs(d) * 2)
            lo = d < 0 ? -span : 0
            hi = span
        }
        return min(lo, current)...max(hi, current)
    }
}
