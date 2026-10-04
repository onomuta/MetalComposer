import AppKit
import CoreGraphics
import MetalComposerKit

extension Notification.Name {
    static let compositionReplaced = Notification.Name("MetalComposer.compositionReplaced")
}

/// The document: a root graph, the editor's position inside nested macros, the selection,
/// and every undoable edit. All edits go through this class so they can be undone.
final class Composition: ObservableObject {
    let root = Graph()
    /// IDs of the macros the editor has descended into, outermost first.
    @Published private(set) var path: [UUID] = []
    @Published var selection: Set<UUID> = []
    @Published var fileURL: URL?
    /// The document's own undo stack (text fields keep the window's, for typing).
    let undoManager = UndoManager()
    /// Visible center of the editor in graph coordinates, used to place new patches.
    var visibleCenter = CGPoint(x: 300, y: 200)

    static let pasteboardType = NSPasteboard.PasteboardType("dev.metalcomposer.patches")

    func touch() { objectWillChange.send() }

    // MARK: Navigation

    /// Macros from the root down to the graph being edited.
    var macroChain: [Patch] {
        var graph = root
        var chain: [Patch] = []
        for id in path {
            guard let macro = graph.node(id), let sub = macro.subgraph else { break }
            chain.append(macro)
            graph = sub
        }
        return chain
    }

    /// The graph shown in the editor.
    var graph: Graph { macroChain.last?.subgraph ?? root }

    var selectedNodes: [Patch] { graph.nodes.filter { selection.contains($0.id) } }
    var singleSelection: Patch? { selection.count == 1 ? selectedNodes.first : nil }

    func enter(_ macro: Patch) {
        guard macro.subgraph != nil, graph.node(macro.id) != nil else { return }
        path.append(macro.id)
        selection = []
    }

    func exit(toDepth depth: Int) {
        guard depth < path.count else { return }
        let leaving = path[depth]
        path = Array(path.prefix(depth))
        selection = [leaving]
    }

    // MARK: Undo

    private var lastCoalesceKey: String?
    private var lastCheckpoint = Date.distantPast

    /// Records the current state so the next edit can be undone. Repeated edits with the same
    /// `coalesce` key in quick succession (slider drags, typing) collapse into one undo step.
    func checkpoint(_ actionName: String, coalesce key: String? = nil) {
        let um = undoManager
        guard !um.isUndoing, !um.isRedoing else { return }
        let now = Date()
        defer { lastCoalesceKey = key; lastCheckpoint = now }
        if let key, key == lastCoalesceKey, now.timeIntervalSince(lastCheckpoint) < 1 { return }
        register(snapshot: root.record(), on: um, name: actionName)
    }

    private func register(snapshot: GraphRecord, on um: UndoManager, name: String) {
        um.registerUndo(withTarget: self) { target in
            let current = target.root.record()
            target.restore(snapshot)
            target.register(snapshot: current, on: um, name: name)
        }
        um.setActionName(name)
    }

    /// ⌘Z: undoes typing while a text field is being edited, otherwise the last graph edit.
    func undo() {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView, let um = text.undoManager, um.canUndo {
            um.undo()
        } else if undoManager.canUndo {
            undoManager.undo()
        }
        touch() // refresh menu titles once the redo action is registered
    }

    func redo() {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView, let um = text.undoManager, um.canRedo {
            um.redo()
        } else if undoManager.canRedo {
            undoManager.redo()
        }
        touch()
    }

    private func restore(_ record: GraphRecord) {
        root.load(record)
        path = Array(path.prefix(macroChain.count))
        let ids = Set(graph.nodes.map(\.id))
        selection = selection.intersection(ids)
        lastCoalesceKey = nil
        touch()
    }

    // MARK: Editing

    @discardableResult
    func add(_ type: Patch.Type, at position: CGPoint) -> Patch {
        checkpoint("Add \(type.title)")
        let patch = type.init(position: position)
        graph.nodes.append(patch)
        selection = [patch.id]
        touch()
        return patch
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        checkpoint("Delete")
        graph.remove(selection)
        selection = []
        touch()
    }

    func connect(from output: PortRef, to input: PortRef, undoable: Bool = true) {
        guard graph.canConnect(from: output, to: input) else { return }
        if undoable { checkpoint("Connect") }
        graph.connect(from: output, to: input)
        touch()
    }

    /// Removes a wire as the start of re-plugging it; the reconnect is part of the same undo step.
    func detach(_ connection: Connection) {
        checkpoint("Change Connection")
        graph.connections.removeAll { $0.id == connection.id }
        touch()
    }

    func beginMove() { checkpoint("Move") }
    func beginResize() { checkpoint("Resize Comment") }

    @discardableResult
    func addComment(at position: CGPoint) -> Patch {
        add(CommentPatch.self, at: position)
    }

    func setParam(_ node: Patch, _ key: String, _ value: Value) {
        checkpoint("Change \(node.displayTitle)", coalesce: "\(node.id)/\(key)")
        node.params[key] = value
        touch() // published ports may change type or name
    }

    func rename(_ node: Patch, _ name: String) {
        checkpoint("Rename", coalesce: "\(node.id)/name")
        node.customTitle = name.isEmpty ? nil : name
        touch()
    }

    func moveLayer(_ node: Patch, by delta: Int) {
        checkpoint("Change Layer")
        graph.moveLayer(node, by: delta)
        touch()
    }

    /// How a file is stored in the document: relative to the document's folder when it is inside it
    /// (so the folder can move as a whole, e.g. into a VJ app's material folder), absolute otherwise.
    func storedPath(for url: URL) -> String {
        let file = url.standardizedFileURL.path
        guard let folder = fileURL?.deletingLastPathComponent().standardizedFileURL.path,
              file.hasPrefix(folder + "/") else { return file }
        return String(file.dropFirst(folder.count + 1))
    }

    /// Adds one Image Importer per file, stacked downward from `position`, as a single undo step.
    func importImages(_ urls: [URL], at position: CGPoint) {
        guard !urls.isEmpty else { return }
        checkpoint(urls.count == 1 ? "Import Image" : "Import Images")
        var added: [Patch] = []
        for (i, url) in urls.enumerated() {
            let patch = ImageImporterPatch(position: CGPoint(x: position.x, y: position.y + CGFloat(i) * 70))
            patch.params["path"] = .string(storedPath(for: url))
            patch.customTitle = url.deletingPathExtension().lastPathComponent
            added.append(patch)
        }
        graph.nodes += added
        selection = Set(added.map(\.id))
        touch()
    }

    func selectAll() {
        selection = Set(graph.nodes.map(\.id))
    }

    // MARK: Clipboard

    /// True while a text field or text view has the keyboard; edit commands then belong to the text.
    static var isEditingText: Bool { NSApp.keyWindow?.firstResponder is NSText }

    /// Runs an Edit-menu command on the graph, or forwards it to the focused text.
    func perform(_ textAction: Selector, graph graphAction: () -> Void) {
        if Self.isEditingText {
            NSApp.sendAction(textAction, to: nil, from: nil)
        } else {
            graphAction()
        }
    }

    func copySelection() {
        guard !selection.isEmpty, let data = try? JSONEncoder().encode(graph.record(only: selection)) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: Self.pasteboardType)
    }

    func cutSelection() {
        copySelection()
        deleteSelection()
    }

    func paste() {
        guard let data = NSPasteboard.general.data(forType: Self.pasteboardType),
              let record = try? JSONDecoder().decode(GraphRecord.self, from: data) else { return }
        insert(record, offset: CGSize(width: 30, height: 30), actionName: "Paste")
    }

    func duplicateSelection() {
        guard !selection.isEmpty else { return }
        insert(graph.record(only: selection), offset: CGSize(width: 30, height: 30), actionName: "Duplicate")
    }

    /// Adds copies of the recorded patches with fresh IDs and selects them.
    private func insert(_ record: GraphRecord, offset: CGSize, actionName: String) {
        checkpoint(actionName)
        var idMap: [UUID: UUID] = [:]
        var added: [Patch] = []
        for var nr in record.nodes {
            let newID = UUID()
            idMap[nr.id] = newID
            nr.id = newID
            nr.x += offset.width
            nr.y += offset.height
            guard let patch = Graph.makePatch(nr) else { continue }
            (patch as? PublishedPortPatch)?.regenerateKey()
            added.append(patch)
        }
        graph.nodes += added
        for c in record.connections {
            guard let a = idMap[c.from.node], let b = idMap[c.to.node] else { continue }
            graph.connections.append(Connection(from: PortRef(node: a, port: c.from.port), to: PortRef(node: b, port: c.to.port)))
        }
        selection = Set(added.map(\.id))
        touch()
    }

    // MARK: Macros

    /// Moves the selected patches into a new macro. Wires crossing the boundary are routed
    /// through Macro Input / Macro Output patches so the graph keeps working unchanged.
    func groupSelectionIntoMacro() {
        let g = graph
        let ids = selection
        let inner = g.nodes.filter { ids.contains($0.id) }
        guard !inner.isEmpty else { return }
        checkpoint("Group into Macro")

        let bounds = inner.map { CGRect(origin: $0.position, size: CGSize(width: 180, height: 80)) }
            .reduce(CGRect.null) { $0.union($1) }
        let macro = MacroPatch(position: CGPoint(x: bounds.midX - 90, y: bounds.midY - 40))
        let sub = macro.contents
        sub.nodes = inner

        var inbound: [PortRef: PublishedInputPatch] = [:]   // keyed by outside source
        var outbound: [PortRef: PublishedOutputPatch] = [:] // keyed by inside source
        var outer: [Connection] = []
        var inY = bounds.minY, outY = bounds.minY

        for c in g.connections {
            switch (ids.contains(c.from.node), ids.contains(c.to.node)) {
            case (true, true):
                sub.connections.append(c)
            case (false, false):
                outer.append(c)
            case (false, true):
                let proxy: PublishedInputPatch
                if let existing = inbound[c.from] {
                    proxy = existing
                } else {
                    let spec = g.node(c.to.node)?.inputPorts.first { $0.key == c.to.port }
                    proxy = PublishedInputPatch(position: CGPoint(x: bounds.minX - 240, y: inY))
                    inY += 70
                    proxy.customTitle = spec?.name ?? "Input"
                    proxy.portType = spec?.type ?? .number
                    sub.nodes.append(proxy)
                    inbound[c.from] = proxy
                    outer.append(Connection(from: c.from, to: PortRef(node: macro.id, port: proxy.portKey)))
                }
                sub.connections.append(Connection(from: PortRef(node: proxy.id, port: "value"), to: c.to))
            case (true, false):
                let proxy: PublishedOutputPatch
                if let existing = outbound[c.from] {
                    proxy = existing
                } else {
                    let spec = g.node(c.from.node)?.outputPorts.first { $0.key == c.from.port }
                    proxy = PublishedOutputPatch(position: CGPoint(x: bounds.maxX + 260, y: outY))
                    outY += 70
                    proxy.customTitle = spec?.name ?? "Output"
                    proxy.portType = spec?.type ?? .number
                    sub.nodes.append(proxy)
                    outbound[c.from] = proxy
                    sub.connections.append(Connection(from: c.from, to: PortRef(node: proxy.id, port: "value")))
                }
                outer.append(Connection(from: PortRef(node: macro.id, port: proxy.portKey), to: c.to))
            }
        }

        // Keep the macro at the layer position of the first grouped patch.
        let insertAt = g.nodes.firstIndex { ids.contains($0.id) } ?? g.nodes.count
        g.nodes.removeAll { ids.contains($0.id) }
        g.nodes.insert(macro, at: min(insertAt, g.nodes.count))
        g.connections = outer
        selection = [macro.id]
        touch()
    }

    /// Only plain macros can be exploded; Iterator, Render In Image and 3D Transformation
    /// change how their contents run, so flattening them would change the result.
    func canExplode(_ node: Patch?) -> Bool {
        guard let node else { return false }
        return type(of: node) == MacroPatch.self
    }

    /// The inverse of Group into Macro: moves the macro's patches into the current graph and
    /// rewires everything that went through its Macro Input / Macro Output patches.
    func explodeMacro(_ macro: Patch) {
        guard canExplode(macro), let macro = macro as? MacroPatch, let index = graph.nodes.firstIndex(where: { $0.id == macro.id }) else { return }
        checkpoint("Explode Macro")
        let g = graph
        let sub = macro.contents
        let inner = sub.nodes.filter { !($0 is PublishedPortPatch) }

        // Place the contents where the macro was.
        let bounds = inner.map(NodeLayout.frame).reduce(CGRect.null) { $0.union($1) }
        if !bounds.isNull {
            let dx = macro.position.x - bounds.minX, dy = macro.position.y - bounds.minY
            for n in inner { n.position = CGPoint(x: n.position.x + dx, y: n.position.y + dy) }
        }

        func port(_ proxyID: UUID) -> PublishedPortPatch? { sub.node(proxyID) as? PublishedPortPatch }
        func macroPort(_ proxy: PublishedPortPatch) -> PortRef { PortRef(node: macro.id, port: proxy.portKey) }

        var wires: [PortRef: Connection] = [:] // one wire per input
        for c in g.connections where c.from.node != macro.id && c.to.node != macro.id { wires[c.to] = c }
        var constants: [(PortRef, Value)] = []

        for c in sub.connections {
            // Where the value really comes from: an inner output, the wire into the macro, or the macro's own value.
            var source: PortRef? = c.from
            var constant: Value?
            if let input = port(c.from.node) as? PublishedInputPatch {
                source = g.connection(into: macroPort(input))?.from
                if source == nil { constant = macro.params[input.portKey] ?? input.portType.defaultValue }
            }
            // Where it goes: an inner input, or every wire leaving the macro's matching output.
            let targets: [PortRef]
            if let output = port(c.to.node) as? PublishedOutputPatch {
                targets = g.connections.filter { $0.from == macroPort(output) }.map(\.to)
            } else {
                targets = [c.to]
            }
            for t in targets {
                if let source, source.node != macro.id {
                    wires[t] = Connection(from: source, to: t)
                } else if let constant {
                    constants.append((t, constant))
                }
            }
        }

        g.nodes.remove(at: index)
        g.nodes.insert(contentsOf: inner, at: index)
        g.connections = Array(wires.values)
        for (ref, value) in constants where wires[ref] == nil { g.node(ref.node)?.params[ref.port] = value }
        selection = Set(inner.map(\.id))
        touch()
    }

    // MARK: Documents

    func replaceDocument(with record: GraphRecord, url: URL?) {
        root.load(record)
        path = []
        selection = []
        fileURL = url
        undoManager.removeAllActions()
        touch()
        DispatchQueue.main.async { NotificationCenter.default.post(name: .compositionReplaced, object: self) }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(root.record())
    }

    func load(_ data: Data, url: URL?) throws {
        replaceDocument(with: try JSONDecoder().decode(GraphRecord.self, from: data), url: url)
    }

    func loadDemo(_ demo: Demo) {
        let g = Graph()
        demo.build(into: g)
        replaceDocument(with: g.record(), url: nil)
    }
}
