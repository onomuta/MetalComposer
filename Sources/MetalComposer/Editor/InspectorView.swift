import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct InspectorView: View {
    @ObservedObject var composition: Composition

    var body: some View {
        if let node = composition.selectedNode {
            NodeInspector(node: node, composition: composition).id(node.id)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "square.on.square.dashed").font(.largeTitle).foregroundStyle(.tertiary)
                Text("Select a patch to edit its inputs").foregroundStyle(.secondary)
                Text("Right-click the canvas or use the library to add patches.\nDrag from an output to an input to connect.")
                    .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct NodeInspector: View {
    @ObservedObject var node: Patch
    @ObservedObject var composition: Composition

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.title).font(.headline)
                    Text(node.summary).font(.caption).foregroundStyle(.secondary)
                }
                if let layer = composition.layerIndex(of: node) {
                    LabeledContent("Layer") {
                        HStack {
                            Text("#\(layer)").monospacedDigit()
                            Button { composition.moveLayer(node, by: -1) } label: { Image(systemName: "arrow.down") }.help("Send backward")
                            Button { composition.moveLayer(node, by: 1) } label: { Image(systemName: "arrow.up") }.help("Bring forward")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                if let status = node.statusMessage {
                    Text(status).font(.system(.caption, design: .monospaced)).foregroundStyle(.red).textSelection(.enabled)
                }
            }

            if !node.allInputs.isEmpty {
                Section("Inputs") {
                    ForEach(node.allInputs, id: \.key) { spec in
                        inputRow(spec)
                    }
                }
            }

            if !node.outputPorts.isEmpty {
                Section("Outputs") {
                    TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(node.outputPorts, id: \.key) { spec in
                                LabeledContent(spec.name) {
                                    Text(node.lastOutputs[spec.key]?.summary ?? "—").monospacedDigit().textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func inputRow(_ spec: PortSpec) -> some View {
        if spec.isPort, let conn = composition.connection(into: PortRef(node: node.id, port: spec.key)),
           let src = composition.node(conn.from.node) {
            LabeledContent(spec.name) {
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("← \(src.title) · \(src.outputPorts.first { $0.key == conn.from.port }?.name ?? conn.from.port)")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(src.lastOutputs[conn.from.port]?.summary ?? "—").monospacedDigit()
                    }
                }
            }
        } else if let options = spec.options {
            Picker(spec.name, selection: Binding(
                get: { Int((node.params[spec.key] ?? spec.defaultValue).number) },
                set: { node.params[spec.key] = .number(Double($0)) })) {
                ForEach(options.indices, id: \.self) { Text(options[$0]).tag($0) }
            }
        } else {
            switch spec.type {
            case .number: numberRow(spec)
            case .bool:
                Toggle(spec.name, isOn: Binding(
                    get: { (node.params[spec.key] ?? spec.defaultValue).bool },
                    set: { node.params[spec.key] = .bool($0) }))
            case .color:
                ColorPicker(spec.name, selection: colorBinding(spec))
            case .string: stringRow(spec)
            case .image:
                LabeledContent(spec.name) { Text("Connect an image").foregroundStyle(.tertiary) }
            }
        }
    }

    private func numberBinding(_ spec: PortSpec) -> Binding<Double> {
        Binding(get: { (node.params[spec.key] ?? spec.defaultValue).number },
                set: { node.params[spec.key] = .number($0) })
    }

    @ViewBuilder
    private func numberRow(_ spec: PortSpec) -> some View {
        LabeledContent(spec.name) {
            HStack {
                if let range = spec.range {
                    Slider(value: Binding(get: { min(max(numberBinding(spec).wrappedValue, range.lowerBound), range.upperBound) },
                                          set: { numberBinding(spec).wrappedValue = $0 }),
                           in: range)
                    .controlSize(.small)
                }
                TextField("", value: numberBinding(spec), format: .number.precision(.fractionLength(0...4)))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
            }
        }
    }

    private func colorBinding(_ spec: PortSpec) -> Binding<CGColor> {
        Binding(
            get: {
                let c = (node.params[spec.key] ?? spec.defaultValue).color
                return CGColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: CGFloat(c.w))
            },
            set: { cg in
                let srgb = cg.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil) ?? cg
                let comps = srgb.components ?? [1, 1, 1, 1]
                let rgba = comps.count >= 4 ? comps : [comps[0], comps[0], comps[0], comps.last ?? 1]
                node.params[spec.key] = .color(SIMD4(Float(rgba[0]), Float(rgba[1]), Float(rgba[2]), Float(rgba[3])))
            })
    }

    private func stringBinding(_ spec: PortSpec) -> Binding<String> {
        Binding(get: { (node.params[spec.key] ?? spec.defaultValue).string },
                set: { node.params[spec.key] = .string($0) })
    }

    @ViewBuilder
    private func stringRow(_ spec: PortSpec) -> some View {
        if spec.multiline {
            VStack(alignment: .leading) {
                HStack {
                    Text(spec.name)
                    Spacer()
                    Button("Reset") { node.params[spec.key] = spec.defaultValue }.controlSize(.small)
                }
                CodeEditor(text: stringBinding(spec))
                    .frame(minHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        } else if spec.isFilePath {
            LabeledContent(spec.name) {
                HStack {
                    Text(URL(fileURLWithPath: stringBinding(spec).wrappedValue).lastPathComponent)
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.image]
                        if panel.runModal() == .OK, let url = panel.url { stringBinding(spec).wrappedValue = url.path }
                    }
                }
            }
        } else {
            TextField(spec.name, text: stringBinding(spec))
        }
    }
}

/// Plain-text code editor without smart quotes or autocorrection.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.backgroundColor = NSColor(white: 0.09, alpha: 1)
        tv.textColor = NSColor(white: 0.92, alpha: 1)
        tv.insertionPointColor = .white
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.string = text
        tv.delegate = context.coordinator
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let tv = scroll.documentView as! NSTextView
        if tv.string != text { tv.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        init(_ parent: CodeEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}
