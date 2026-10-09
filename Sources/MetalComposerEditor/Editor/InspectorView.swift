#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI
import UniformTypeIdentifiers
import MetalComposerKit

struct InspectorView: View {
    @ObservedObject var composition: Composition

    #if os(macOS)
    private static let emptyHint = "Right-click the canvas or use the library to add patches.\nDrag from an output to an input to connect; drag on empty space to select several."
    #else
    private static let emptyHint = "Touch and hold the canvas or use the library to add patches.\nDrag from an output to an input to connect; drag empty space to move around. Touch and hold a port to see its value."
    #endif

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
                Text(loc(Self.emptyHint))
                    .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct NodeInspector: View {
    #if os(macOS)
    static let doubleClick = "double-click"
    #else
    static let doubleClick = "double-tap"
    #endif

    @ObservedObject var node: Patch
    @ObservedObject var composition: Composition
    /// The file setting being chosen with the file picker (iOS).
    @State private var choosingFileFor: String?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.title).font(.headline)
                    Text(loc(node.summary)).font(.caption).foregroundStyle(.secondary)
                }
                TextField(loc(node is PublishedPortPatch ? "Port Name" : "Name"), text: Binding(
                    get: { node.customTitle ?? "" },
                    set: { composition.rename(node, $0) }), prompt: Text(node.title))
                if node.subgraph != nil {
                    HStack {
                        Button(loc("Open %@  (%@)", node.displayTitle, loc(Self.doubleClick))) { composition.enter(node) }
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
                    ForEach(node.allInputs.filter { !$0.hidden && ($0.isPort || node.showsSetting($0.key)) }, id: \.key) { spec in
                        inputRow(spec)
                    }
                    if let importer = node as? ImageImporterPatch, importer.showsSetting("embed") {
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
        } else if spec.isFontStyle {
            LabeledContent(spec.name) {
                FontStylePicker(family: node.params["font"]?.string ?? "", style: stringBinding(spec))
            }
        } else if spec.isFilePath {
            LabeledContent(spec.name) {
                HStack {
                    Text(URL(fileURLWithPath: stringBinding(spec).wrappedValue).lastPathComponent)
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Choose…") {
                        #if os(macOS)
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.image]
                        if panel.runModal() == .OK, let url = panel.url {
                            stringBinding(spec).wrappedValue = composition.storedPath(for: url)
                            // In the App Sandbox (Mac App Store) the file is readable only for
                            // now, so keep its bytes in the composition.
                            if Composition.filesReadableOnlyNow {
                                composition.setParam(node, "embed", .bool(true))
                            }
                        }
                        #else
                        choosingFileFor = spec.key
                        #endif
                    }
                    .fixedSize()
                    #if !os(macOS)
                    .fileImporter(isPresented: Binding(get: { choosingFileFor == spec.key },
                                                       set: { if !$0 { choosingFileFor = nil } }),
                                  allowedContentTypes: [.image]) { result in
                        guard case .success(let url) = result else { return }
                        // A picked file is only readable for now, so keep its bytes in the composition.
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        composition.setParam(node, spec.key, .string(url.path))
                        composition.setParam(node, "embed", .bool(true))
                    }
                    #endif
                }
            }
        } else {
            TextField(spec.name, text: stringBinding(spec))
        }
    }
}

#if os(macOS)
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
#else
/// Plain-text code editor without smart quotes or autocorrection.
struct CodeEditor: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.spellCheckingType = .no
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.smartInsertDeleteType = .no
        tv.backgroundColor = UIColor(white: 0.09, alpha: 1)
        tv.textColor = UIColor(white: 0.92, alpha: 1)
        tv.tintColor = .white
        tv.textContainerInset = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        tv.text = text
        tv.delegate = context.coordinator
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.parent = self
        if tv.text != text { tv.text = text }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditor
        init(_ parent: CodeEditor) { self.parent = parent }
        func textViewDidChange(_ tv: UITextView) { parent.text = tv.text }
    }
}
#endif

/// Picks a font family ("" = the system font). The style comes from Text Image's Weight.
struct FontPicker: View {
    @Binding var name: String

    /// Installed families, read once; fonts installed while the app runs show up after a restart.
    #if os(macOS)
    private static let families = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }
    #else
    private static let families = UIFont.familyNames.sorted()
    #endif

    private var label: String {
        if name.isEmpty { return "System Font" }
        if name == TextImagePatch.systemMonospaced || Self.families.contains(name) { return name }
        return "\(name) (not installed)"
    }

    var body: some View {
        Menu(label) {
            Button("System Font") { name = "" }
            Button(TextImagePatch.systemMonospaced) { name = TextImagePatch.systemMonospaced }
            Divider()
            ForEach(Self.families, id: \.self) { family in
                Button(family) { name = family }
            }
        }
        .fixedSize()
    }
}

/// Picks one of the styles of `family` (lightest first). A style the family doesn't have shows
/// which of its styles is used instead.
struct FontStylePicker: View {
    var family: String
    @Binding var style: String

    var body: some View {
        let styles = TextImagePatch.styles(of: family)
        let used = TextImagePatch.resolvedStyle(family: family, style: style)
        let label = used.map { $0.name.caseInsensitiveCompare(style) == .orderedSame ? $0.name : "\(style) → \($0.name)" } ?? style
        Menu(label) {
            ForEach(styles, id: \.name) { s in
                Button(s.name) { style = s.name }
            }
        }
        .fixedSize()
    }
}
