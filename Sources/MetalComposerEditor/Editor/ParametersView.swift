import SwiftUI
import MetalComposerKit

/// Test values for the composition's parameters (its top-level Macro Inputs), set the way a host
/// app sets them. They drive the viewer only: they aren't saved, and movie export uses the
/// defaults. Keyed by the inputs' port keys.
final class ParameterValues: ObservableObject {
    @Published var values: [String: Value] = [:]

    /// The composition's parameters, top to bottom (the order a host app lists them in).
    static func inputs(of composition: Composition) -> [PublishedInputPatch] {
        composition.root.nodes.compactMap { $0 as? PublishedInputPatch }.sorted { $0.position.y < $1.position.y }
    }

    /// What the renderer passes to the top-level Macro Inputs: the test values, as each input's type.
    func published(for composition: Composition) -> [String: Value] {
        guard !values.isEmpty else { return [:] }
        var result: [String: Value] = [:]
        for input in Self.inputs(of: composition) {
            if let value = values[input.portKey] { result[input.portKey] = value.coerced(to: input.portType) }
        }
        return result
    }

    func value(of input: PublishedInputPatch) -> Value {
        values[input.portKey]?.coerced(to: input.portType) ?? input.defaultValue
    }

    /// The values an ONOM FLOW Input patch takes, when the composition uses one.
    static func hostValues(of composition: Composition) -> [OnomFlowInputPatch.HostValue] {
        OnomFlowInputPatch.isUsed(in: composition.root) ? OnomFlowInputPatch.hostValues : []
    }

    /// What the renderer passes to ONOM FLOW Input patches: only the values tried here, like a host sets them.
    func host(for composition: Composition) -> [String: Value] {
        guard !values.isEmpty else { return [:] }
        var result: [String: Value] = [:]
        for host in Self.hostValues(of: composition) {
            if let value = values[host.key] { result[host.key] = value.coerced(to: host.type) }
        }
        return result
    }
}

/// Opens the parameter panel; shown only when the composition has parameters.
struct ParametersButton: View {
    @ObservedObject var composition: Composition
    let parameters: ParameterValues
    @State private var showing = false

    var body: some View {
        if !ParameterValues.inputs(of: composition).isEmpty || !ParameterValues.hostValues(of: composition).isEmpty {
            Button { showing.toggle() } label: { Image(systemName: "dial.medium") }
                .help("Try the composition's parameters")
                .accessibilityLabel("Parameters")
                .popover(isPresented: $showing) {
                    ParametersPanel(composition: composition, parameters: parameters)
                        .frame(minWidth: 300, idealWidth: 340, minHeight: 220, idealHeight: 380)
                        #if os(iOS)
                        // A sheet on iPhone, low enough to watch the viewer while changing values.
                        .presentationDetents([.medium, .large])
                        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                        #endif
                }
        }
    }
}

/// The composition's parameters with controls for trying values.
struct ParametersPanel: View {
    @ObservedObject var composition: Composition
    @ObservedObject var parameters: ParameterValues

    var body: some View {
        let inputs = ParameterValues.inputs(of: composition)
        VStack(spacing: 0) {
            HStack {
                Text("Parameters").font(.headline)
                Spacer()
                Button("Reset") { parameters.values = [:] }
                    .disabled(parameters.values.isEmpty)
                    .help("Go back to the default values")
                Button("Set as Defaults") { setAsDefaults(inputs) }
                    .disabled(parameters.values.isEmpty)
                    .help("Store these values as the Macro Inputs' Default Value")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Form {
                if !inputs.isEmpty {
                    Section {
                        ForEach(inputs, id: \.id) { input in
                            ParameterRow(input: input, parameters: parameters)
                        }
                    } footer: {
                        Text("Values here drive the viewer the way a host app would set them. They aren't saved with the composition.")
                    }
                }
                let hostValues = ParameterValues.hostValues(of: composition)
                if !hostValues.isEmpty {
                    Section {
                        ForEach(hostValues, id: \.key) { host in
                            HostValueRow(host: host, parameters: parameters)
                        }
                    } header: {
                        Text("ONOM FLOW")
                    } footer: {
                        Text("Try what ONOM FLOW would send to the ONOM FLOW Input patch. Without a value, Beat, Beat 2 and Beat 4 follow the BPM.")
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func setAsDefaults(_ inputs: [PublishedInputPatch]) {
        for input in inputs where parameters.values[input.portKey] != nil {
            composition.setParam(input, "default", parameters.value(of: input))
        }
        parameters.values = [:]
    }
}

/// One value of the ONOM FLOW Input patch, tried the way ONOM FLOW sets it.
private struct HostValueRow: View {
    let host: OnomFlowInputPatch.HostValue
    @ObservedObject var parameters: ParameterValues

    private var value: Value { parameters.values[host.key]?.coerced(to: host.type) ?? host.defaultValue }
    private var isChanged: Bool { parameters.values[host.key] != nil }
    private func set(_ new: Value) { parameters.values[host.key] = new }

    var body: some View {
        let name = Text(host.name).fontWeight(isChanged ? .semibold : .regular)
        switch host.type {
        case .number:
            let range: ClosedRange<Double> = host.key == "onom-flow.bpm" ? 20...300 : 0...1
            let number = Binding(get: { value.number }, set: { set(.number(min(max($0, range.lowerBound), range.upperBound))) })
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    name
                    Spacer()
                    TextField("", value: number, format: .number.precision(.fractionLength(0...3)))
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(maxWidth: 90)
                }
                Slider(value: number, in: range)
            }
        case .color:
            ColorPicker(selection: Binding(get: { ParameterRow.cgColor(value.color) }, set: { set(.color(ParameterRow.simd($0))) })) { name }
        case .string:
            LabeledContent {
                TextField("", text: Binding(get: { value.string }, set: { set(.string($0)) }))
                    .multilineTextAlignment(.trailing)
            } label: { name }
        default:
            LabeledContent { Text("Set by the host app").foregroundStyle(.secondary) } label: { name }
        }
    }
}

private struct ParameterRow: View {
    @ObservedObject var input: PublishedInputPatch
    @ObservedObject var parameters: ParameterValues

    private var value: Value { parameters.value(of: input) }
    private var isChanged: Bool { parameters.values[input.portKey] != nil }

    private func set(_ new: Value) { parameters.values[input.portKey] = new }

    var body: some View {
        let name = Text(input.displayTitle).fontWeight(isChanged ? .semibold : .regular)
        switch input.portType {
        case .number:
            let number = Binding(get: { value.number }, set: { set(input.clamped(.number($0))) })
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    name
                    Spacer()
                    TextField("", value: number, format: .number.precision(.fractionLength(0...3)))
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(maxWidth: 90)
                        #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                }
                Slider(value: number, in: input.valueRange ?? Self.range(around: input.defaultValue.number, current: value.number))
            }
        case .bool:
            Toggle(isOn: Binding(get: { value.bool }, set: { set(.bool($0)) })) { name }
        case .color:
            ColorPicker(selection: Binding(get: { Self.cgColor(value.color) }, set: { set(.color(Self.simd($0))) })) { name }
        case .string:
            LabeledContent {
                TextField("", text: Binding(get: { value.string }, set: { set(.string($0)) }))
                    .multilineTextAlignment(.trailing)
            } label: { name }
        default:
            LabeledContent { Text("Set by the host app").foregroundStyle(.secondary) } label: { name }
        }
    }

    /// Without Limit Range, guess a range from the default: 0…1 for defaults in it,
    /// otherwise ± twice the default's size; widened to include a value typed outside it.
    private static func range(around defaultValue: Double, current: Double) -> ClosedRange<Double> {
        var lo = 0.0, hi = 1.0
        if !(0...1).contains(defaultValue) {
            let span = max(1, abs(defaultValue) * 2)
            lo = defaultValue < 0 ? -span : 0
            hi = span
        }
        return min(lo, current)...max(hi, current)
    }

    static func cgColor(_ c: SIMD4<Float>) -> CGColor {
        CGColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: CGFloat(c.w))
    }

    static func simd(_ color: CGColor) -> SIMD4<Float> {
        let srgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil) ?? color
        let c = (srgb.components ?? [0, 0, 0, 1]).map(Float.init)
        return c.count >= 4 ? SIMD4(c[0], c[1], c[2], c[3]) : SIMD4(c[0], c[0], c[0], c.last ?? 1)
    }
}
