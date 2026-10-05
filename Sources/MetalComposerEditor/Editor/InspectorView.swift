import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MetalComposerKit

struct InspectorView: View {
    @ObservedObject var composition: Composition

    var body: some View {
        if let node = composition.singleSelection {
            NodeInspector(node: node, composition: composition).id(node.id)
        } else if composition.selection.count > 1 {
            VStack(spacing: 10) {
                Text("\(composition.selection.count) patches selected").font(.headline)
                HStack {
                    Button("Group into Macro") { composition.groupSelectionIntoMacro() }
                    Button("Duplicate") { composition.duplicateSelection() }
                    Button("Delete", role: .destructive) { composition.deleteSelection() }
                }
                Text("⌘G group · ⌘D duplicate · ⌘C / ⌘V copy & paste").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "square.on.square.dashed").font(.largeTitle).foregroundStyle(.tertiary)
                Text("Select a patch to edit its inputs").foregroundStyle(.secondary)
                Text("Right-click the canvas or use the library to add patches.\nDrag from an output to an input to connect; drag on empty space to select several.")
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
                TextField(node is PublishedPortPatch ? "Port Name" : "Name", text: Binding(
                    get: { node.customTitle ?? "" },
                    set: { composition.rename(node, $0) }), prompt: Text(node.title))
                if node.subgraph != nil {
                    HStack {
                        Button("Open \(node.displayTitle)  (double-click)") { composition.enter(node) }
                        if composition.canExplode(node) {
                            Button("Explode") { composition.explodeMacro(node) }.help("Move the contents out of the macro (⇧⌘G)")
                        }
                    }
                }
                if let layer = composition.graph.layerIndex(of: node) {
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
                    ForEach(node.allInputs.filter { !$0.hidden && !isWeightSetByFont($0) }, id: \.key) { spec in
                        inputRow(spec)
                    }
                    if let importer = node as? ImageImporterPatch {
                        embeddedImageNote(importer)
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

    /// Text Image's Weight only applies to the system font; another font's style is in its name.
    private func isWeightSetByFont(_ spec: PortSpec) -> Bool {
        node is TextImagePatch && spec.key == "weight" && !(node.params["font"]?.string ?? "").isEmpty
    }

    @ViewBuilder
    private func embeddedImageNote(_ importer: ImageImporterPatch) -> some View {
        let bytes = importer.embeddedByteCount
        if importer.params["embed"]?.bool == true {
            // The editor UI is in English, so don't use the system's localized byte units.
            let size = bytes >= 1_000_000 ? String(format: "%.1f MB", Double(bytes) / 1e6)
                : String(format: "%.0f KB", max(1, Double(bytes) / 1e3))
            if bytes == 0 {
                Text("The file couldn't be read, so nothing is embedded. Choose the file again.")
                    .font(.caption).foregroundStyle(.red)
            } else if bytes > ImageImporterPatch.embedWarningBytes {
                Text("Embedded \(size). Large embedded images make the composition slow to open, and apps that play it may pause while it loads. Consider keeping this image as a file.")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text("Embedded \(size). The composition works without the file.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func inputRow(_ spec: PortSpec) -> some View {
        if spec.isPort, let conn = composition.graph.connection(into: PortRef(node: node.id, port: spec.key)),
           let src = composition.graph.node(conn.from.node) {
            LabeledContent(spec.name) {
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("← \(src.displayTitle) · \(src.outputPorts.first { $0.key == conn.from.port }?.name ?? conn.from.port)")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(src.lastOutputs[conn.from.port]?.summary ?? "—").monospacedDigit()
                    }
                }
            }
        } else if let options = spec.options {
            Picker(spec.name, selection: Binding(
                get: { Int((node.params[spec.key] ?? spec.defaultValue).number) },
                set: { composition.setParam(node, spec.key, .number(Double($0))) })) {
                ForEach(options.indices, id: \.self) { Text(options[$0]).tag($0) }
            }
        } else {
            switch spec.type {
            case .number: numberRow(spec)
            case .bool:
                Toggle(spec.name, isOn: Binding(
                    get: { (node.params[spec.key] ?? spec.defaultValue).bool },
                    set: { composition.setParam(node, spec.key, .bool($0)) }))
            case .color:
                ColorPicker(spec.name, selection: colorBinding(spec))
            case .string: stringRow(spec)
            case .image:
                LabeledContent(spec.name) { Text("Connect an image").foregroundStyle(.tertiary) }
            case .structure:
                LabeledContent(spec.name) { Text("Connect a structure").foregroundStyle(.tertiary) }
            case .any:
                // Virtual input: text that is exactly a number becomes a number, anything else stays
                // text. "1." or "0.10" stay text until finished, so typing never gets reformatted.
                TextField(spec.name, text: Binding(
                    get: {
                        let v = node.params[spec.key] ?? spec.defaultValue
                        if case .number(let d) = v { return Self.canonical(d) }
                        return v.summary
                    },
                    set: { text in
                        let trimmed = text.trimmingCharacters(in: .whitespaces)
                        let value = Double(trimmed).flatMap { Self.canonical($0) == trimmed ? Value.number($0) : nil }
                        composition.setParam(node, spec.key, value ?? .string(text))
                    }), prompt: Text("number or text"))
            }
        }
    }

    /// Shortest text for a number: "2", "1.5", "-0.25".
    static func canonical(_ d: Double) -> String {
        d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
    }

    private func numberBinding(_ spec: PortSpec) -> Binding<Double> {
        Binding(get: { (node.params[spec.key] ?? spec.defaultValue).number },
                set: { composition.setParam(node, spec.key, .number(spec.clamped($0))) })
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
                Knob(value: numberBinding(spec), range: spec.range, limits: spec.limits, step: spec.step,
                     defaultValue: spec.defaultValue.number)
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
                composition.setParam(node, spec.key, .color(SIMD4(Float(rgba[0]), Float(rgba[1]), Float(rgba[2]), Float(rgba[3]))))
            })
    }

    private func stringBinding(_ spec: PortSpec) -> Binding<String> {
        Binding(get: { (node.params[spec.key] ?? spec.defaultValue).string },
                set: { composition.setParam(node, spec.key, .string($0)) })
    }

    @ViewBuilder
    private func stringRow(_ spec: PortSpec) -> some View {
        if spec.multiline {
            VStack(alignment: .leading) {
                HStack {
                    Text(spec.name)
                    Spacer()
                    Button("Reset") { composition.setParam(node, spec.key, spec.defaultValue) }.controlSize(.small)
                }
                CodeEditor(text: stringBinding(spec))
                    .frame(minHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        } else if spec.isFontName {
            LabeledContent(spec.name) {
                FontPicker(name: stringBinding(spec))
            }
        } else if spec.isFilePath {
            LabeledContent(spec.name) {
                HStack {
                    Text(URL(fileURLWithPath: stringBinding(spec).wrappedValue).lastPathComponent)
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.image]
                        if panel.runModal() == .OK, let url = panel.url {
                            stringBinding(spec).wrappedValue = composition.storedPath(for: url)
                        }
                    }
                    .fixedSize()
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

/// Picks an installed font: a menu of families, each with its styles. Stores the PostScript name
/// ("" = the system font).
struct FontPicker: View {
    @Binding var name: String

    /// Installed families and their styles as (PostScript name, style name). Read once; fonts
    /// installed while the app runs show up after a restart.
    private static let families: [(family: String, faces: [(name: String, style: String)])] = {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
            .map { family in
                let faces = (manager.availableMembers(ofFontFamily: family) ?? []).compactMap { member -> (String, String)? in
                    guard let ps = member.first as? String, let style = member[safe: 1] as? String else { return nil }
                    return (ps, style)
                }
                return (family, faces)
            }
            .filter { !$0.faces.isEmpty }
    }()

    private var label: String {
        if name.isEmpty { return "System Font" }
        guard let font = NSFont(name: name, size: 12) else { return "\(name) (not installed)" }
        return font.displayName ?? name
    }

    var body: some View {
        Menu(label) {
            Button("System Font") { name = "" }
            Divider()
            ForEach(Self.families, id: \.family) { entry in
                if entry.faces.count == 1 {
                    Button(entry.family) { name = entry.faces[0].name }
                } else {
                    Menu(entry.family) {
                        ForEach(entry.faces, id: \.name) { face in
                            Button(face.style) { name = face.name }
                        }
                    }
                }
            }
        }
        .fixedSize()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
