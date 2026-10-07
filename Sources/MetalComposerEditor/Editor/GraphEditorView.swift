#if os(macOS)
import AppKit
#endif
import SwiftUI
import UniformTypeIdentifiers
import MetalComposerKit

extension PortType {
    var color: Color {
        switch self {
        case .number: return Color(red: 0.55, green: 0.7, blue: 0.95)
        case .bool: return Color(red: 0.95, green: 0.8, blue: 0.3)
        case .color: return Color(red: 0.95, green: 0.45, blue: 0.65)
        case .string: return Color(red: 0.5, green: 0.85, blue: 0.55)
        case .image: return Color(red: 0.75, green: 0.55, blue: 0.95)
        case .structure: return Color(red: 0.98, green: 0.62, blue: 0.3)
        case .any: return Color(white: 0.8)
        }
    }
}

extension PatchCategory {
    var color: Color {
        switch self {
        case .provider: return Color(red: 0.42, green: 0.32, blue: 0.75)
        case .processor: return Color(red: 0.2, green: 0.55, blue: 0.4)
        case .consumer: return Color(red: 0.75, green: 0.32, blue: 0.3)
        }
    }
}

/// Fixed node geometry in graph coordinates; used for both drawing and hit testing.
enum NodeLayout {
    static let width: CGFloat = 180
    static let header: CGFloat = 24
    static let row: CGFloat = 18
    static let footer: CGFloat = 6
    static let portHitRadius: CGFloat = 10

    static func frame(_ node: Patch) -> CGRect {
        if let comment = node as? CommentPatch { return CGRect(origin: node.position, size: comment.size) }
        let rows = max(node.inputPorts.count, node.outputPorts.count, 1)
        return CGRect(x: node.position.x, y: node.position.y, width: width,
                      height: header + CGFloat(rows) * row + footer)
    }

    static func resizeHandle(_ comment: CommentPatch) -> CGRect {
        let f = frame(comment)
        return CGRect(x: f.maxX - 14, y: f.maxY - 14, width: 14, height: 14)
    }

    static func inputPoint(_ node: Patch, _ index: Int) -> CGPoint {
        CGPoint(x: node.position.x, y: node.position.y + header + row * (CGFloat(index) + 0.5))
    }

    static func outputPoint(_ node: Patch, _ index: Int) -> CGPoint {
        CGPoint(x: node.position.x + width, y: node.position.y + header + row * (CGFloat(index) + 0.5))
    }
}

struct GraphEditorView: View {
    @ObservedObject var composition: Composition

    @State private var offset = CGSize(width: 30, height: 30)
    @State private var zoom: CGFloat = 1
    @State private var pinchStartZoom: CGFloat?
    @State private var drag: DragMode?
    @State private var detachedWire = false
    @State private var hovering = false
    @State private var pointer: CGPoint = .zero
    @State private var viewSize: CGSize = .zero
    @State private var scrollMonitor: Any?
    @State private var lastClick: (id: UUID, time: Date)?
    @State private var redrawTick = 0
    @State private var dropTargeted = false
    @State private var hoveredPort: PortHit?
    @State private var editingComment: UUID?
    @FocusState private var focused: Bool

    private struct PortHit {
        var ref: PortRef
        var isOutput: Bool
        var type: PortType
        var point: CGPoint
    }

    private enum DragMode {
        case pan(start: CGSize)
        case move(start: CGPoint, origins: [UUID: CGPoint], moved: Bool, clicked: UUID)
        case marquee(start: CGPoint, current: CGPoint, base: Set<UUID>)
        case connect(from: PortHit, current: CGPoint)
        case resize(id: UUID, start: CGPoint, origin: CGSize, moved: Bool)
        case ignore
    }

    private var graph: Graph { composition.graph }

    /// With touch, dragging the background moves around the graph (as in Maps); a range selection
    /// needs ⇧ or ⌘ on a keyboard. The Mac selects a range and pans with ⌥ or two-finger scroll.
    #if os(macOS)
    private static let backgroundDragPans = false
    #else
    private static let backgroundDragPans = true
    #endif

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                _ = redrawTick
                drawGrid(&ctx, size)
                var g = ctx
                g.translateBy(x: offset.width, y: offset.height)
                g.scaleBy(x: zoom, y: zoom)
                drawComments(&g)
                drawConnections(&g)
                drawNodes(&g)
                drawPendingConnection(&g)
                drawMarquee(&g)
            }
            .background(Color(white: composition.path.isEmpty ? 0.11 : 0.085))
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .simultaneousGesture(magnifyGesture)
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.escape) {
                // Escape reaches this handler even while a comment's text view has the keyboard.
                if editingComment != nil {
                    editingComment = nil
                    focused = true
                    return .handled
                }
                guard !composition.path.isEmpty else { return .ignored }
                composition.exit(toDepth: composition.path.count - 1)
                return .handled
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    hovering = true
                    pointer = p
                    hoveredPort = drag == nil ? hitPort(toGraph(p)) : nil
                case .ended:
                    hovering = false
                    hoveredPort = nil
                }
            }
            .contextMenu { contextMenu }
            .dropDestination(for: URL.self) { urls, location in
                let images = urls.filter { url in
                    url.isFileURL && (UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false)
                }
                guard !images.isEmpty else { return false }
                let p = toGraph(location)
                composition.importImages(images, at: CGPoint(x: p.x - NodeLayout.width / 2, y: p.y - NodeLayout.header / 2))
                focused = true
                return true
            } isTargeted: { dropTargeted = $0 }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) { commentEditor }
            .overlay(alignment: .topLeading) { portTooltip }
            .overlay(alignment: .topLeading) { breadcrumb }
            .overlay(alignment: .bottomTrailing) { zoomControls }
            .onAppear { viewSize = geo.size; zoomToFit(); installScrollMonitor() }
            .onDisappear { removeScrollMonitor() }
            .onChange(of: geo.size) { _, s in viewSize = s; updateVisibleCenter() }
            .onChange(of: composition.path) { _, _ in zoomToFit() }
            .onReceive(NotificationCenter.default.publisher(for: .compositionReplaced)) { _ in zoomToFit() }
            .onReceive(NotificationCenter.default.publisher(for: .patchStatusChanged)) { _ in redrawTick += 1 }
        }
    }

    // MARK: Coordinates

    private func toGraph(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - offset.width) / zoom, y: (p.y - offset.height) / zoom)
    }

    private func updateVisibleCenter() {
        composition.visibleCenter = toGraph(CGPoint(x: viewSize.width / 2 - NodeLayout.width / 2 * zoom,
                                                    y: viewSize.height / 2 - 60 * zoom))
    }

    private func setZoom(_ newZoom: CGFloat, around p: CGPoint) {
        let z = min(max(newZoom, 0.25), 3)
        let anchor = toGraph(p)
        zoom = z
        offset = CGSize(width: p.x - anchor.x * z, height: p.y - anchor.y * z)
        updateVisibleCenter()
    }

    // MARK: Hit testing

    private func hitPort(_ p: CGPoint) -> PortHit? {
        for node in graph.nodes.reversed() {
            for (i, spec) in node.outputPorts.enumerated() {
                let pt = NodeLayout.outputPoint(node, i)
                if hypot(pt.x - p.x, pt.y - p.y) < NodeLayout.portHitRadius {
                    return PortHit(ref: PortRef(node: node.id, port: spec.key), isOutput: true, type: spec.type, point: pt)
                }
            }
            for (i, spec) in node.inputPorts.enumerated() {
                let pt = NodeLayout.inputPoint(node, i)
                if hypot(pt.x - p.x, pt.y - p.y) < NodeLayout.portHitRadius {
                    return PortHit(ref: PortRef(node: node.id, port: spec.key), isOutput: false, type: spec.type, point: pt)
                }
            }
        }
        return nil
    }

    private func hitNode(_ p: CGPoint) -> Patch? {
        graph.nodes.last { !($0 is CommentPatch) && NodeLayout.frame($0).contains(p) }
            ?? graph.nodes.last { $0 is CommentPatch && NodeLayout.frame($0).contains(p) }
    }

    private func portPoint(_ ref: PortRef, output: Bool) -> (CGPoint, PortType)? {
        guard let node = graph.node(ref.node) else { return nil }
        let ports = output ? node.outputPorts : node.inputPorts
        guard let i = ports.firstIndex(where: { $0.key == ref.port }) else { return nil }
        return (output ? NodeLayout.outputPoint(node, i) : NodeLayout.inputPoint(node, i), ports[i].type)
    }

    // MARK: Gestures

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if drag == nil { beginDrag(at: value.startLocation) }
                let p = toGraph(value.location)
                switch drag {
                case .pan(let start):
                    offset = CGSize(width: start.width + value.translation.width,
                                    height: start.height + value.translation.height)
                case .move(let start, let origins, var moved, let clicked):
                    guard moved || hypot(value.translation.width, value.translation.height) > 2 else { return }
                    if !moved { composition.beginMove(); moved = true }
                    let dx = p.x - start.x, dy = p.y - start.y
                    for (id, o) in origins { graph.node(id)?.position = CGPoint(x: o.x + dx, y: o.y + dy) }
                    drag = .move(start: start, origins: origins, moved: moved, clicked: clicked)
                    composition.touch()
                case .marquee(let start, _, let base):
                    drag = .marquee(start: start, current: p, base: base)
                    let rect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                                      width: abs(p.x - start.x), height: abs(p.y - start.y))
                    composition.selection = base.union(graph.nodes.filter { NodeLayout.frame($0).intersects(rect) }.map(\.id))
                case .connect(let from, _):
                    drag = .connect(from: from, current: p)
                case .resize(let id, let start, let origin, var moved):
                    guard let comment = graph.node(id) as? CommentPatch else { return }
                    if !moved { composition.beginResize(); moved = true }
                    comment.params["width"] = .number(max(CommentPatch.minSize.width, origin.width + p.x - start.x))
                    comment.params["height"] = .number(max(CommentPatch.minSize.height, origin.height + p.y - start.y))
                    drag = .resize(id: id, start: start, origin: origin, moved: moved)
                    composition.touch()
                case .ignore, nil:
                    break
                }
            }
            .onEnded { value in
                switch drag {
                case .connect(let from, _):
                    if let target = hitPort(toGraph(value.location)), target.isOutput != from.isOutput {
                        let (out, inp) = from.isOutput ? (from.ref, target.ref) : (target.ref, from.ref)
                        // Re-plugging a detached wire belongs to the detach's undo step.
                        composition.connect(from: out, to: inp, undoable: !detachedWire)
                    }
                case .move(_, _, let moved, let clicked):
                    if !moved { handleClick(on: clicked) }
                case .pan:
                    // A tap on the background (iOS pans instead of selecting) clears the selection.
                    if Self.backgroundDragPans, hypot(value.translation.width, value.translation.height) < 3 {
                        composition.selection = []
                    }
                    updateVisibleCenter()
                default:
                    break
                }
                drag = nil
                detachedWire = false
            }
    }

    private func beginDrag(at screenPoint: CGPoint) {
        focused = true
        editingComment = nil
        hoveredPort = nil
        let p = toGraph(screenPoint)
        let extend = HeldKeys.shift || HeldKeys.command

        if let comment = graph.nodes.reversed().compactMap({ $0 as? CommentPatch })
            .first(where: { NodeLayout.resizeHandle($0).contains(p) }) {
            composition.selection = [comment.id]
            drag = .resize(id: comment.id, start: p, origin: comment.size, moved: false)
        } else if let port = hitPort(p) {
            if !port.isOutput, let existing = graph.connection(into: port.ref),
               let (pt, type) = portPoint(existing.from, output: true) {
                // Grabbing a connected input detaches the wire so it can be re-plugged or dropped.
                composition.detach(existing)
                detachedWire = true
                drag = .connect(from: PortHit(ref: existing.from, isOutput: true, type: type, point: pt), current: p)
            } else {
                drag = .connect(from: port, current: p)
            }
        } else if let node = hitNode(p) {
            if extend {
                if composition.selection.contains(node.id) {
                    composition.selection.remove(node.id)
                    drag = .ignore
                    return
                }
                composition.selection.insert(node.id)
            } else if !composition.selection.contains(node.id) {
                composition.selection = [node.id]
            }
            let origins = Dictionary(uniqueKeysWithValues: composition.selectedNodes.map { ($0.id, $0.position) })
            drag = .move(start: p, origins: origins, moved: false, clicked: node.id)
        } else if HeldKeys.option || (Self.backgroundDragPans && !extend) {
            drag = .pan(start: offset)
        } else {
            let base = extend ? composition.selection : []
            composition.selection = base
            drag = .marquee(start: p, current: p, base: base)
        }
    }

    /// A click without movement: collapse the selection to the node, or open a macro on double-click.
    private func handleClick(on id: UUID) {
        let now = Date()
        if let last = lastClick, last.id == id, now.timeIntervalSince(last.time) < 0.35, let node = graph.node(id) {
            if node is CommentPatch {
                lastClick = nil
                focused = false // let the note's text view take the keyboard
                editingComment = id
                return
            }
            if node.subgraph != nil {
                lastClick = nil
                composition.enter(node)
                return
            }
        }
        lastClick = (id, now)
        if !HeldKeys.shift, !HeldKeys.command {
            composition.selection = [id]
        }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchStartZoom == nil { pinchStartZoom = zoom }
                setZoom(pinchStartZoom! * value.magnification, around: value.startLocation)
            }
            .onEnded { _ in pinchStartZoom = nil }
    }

    /// Two-finger scroll pans; ⌘-scroll zooms.
    private func installScrollMonitor() {
        #if os(macOS)
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard hovering else { return event }
            if event.modifierFlags.contains(.command) {
                setZoom(zoom * (1 + event.scrollingDeltaY * 0.01), around: pointer)
            } else {
                let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
                offset.width += event.scrollingDeltaX * k
                offset.height += event.scrollingDeltaY * k
                updateVisibleCenter()
            }
            return nil
        }
        #endif
    }

    private func removeScrollMonitor() {
        #if os(macOS)
        if let m = scrollMonitor { NSEvent.removeMonitor(m) }
        scrollMonitor = nil
        #endif
    }

    // MARK: Menus & overlays

    @ViewBuilder private var contextMenu: some View {
        ForEach(PatchRegistry.sections, id: \.self) { section in
            Menu(section) {
                ForEach(PatchRegistry.all.filter { $0.librarySection == section }, id: \.typeID) { type in
                    Button(type.title) {
                        let p = toGraph(pointer)
                        composition.add(type, at: CGPoint(x: p.x - 20, y: p.y - 10))
                    }
                }
            }
        }
        Button("Add Comment Here") {
            let p = toGraph(pointer)
            composition.addComment(at: p)
        }
        if !composition.selection.isEmpty {
            Divider()
            Button("Group into Macro") { composition.groupSelectionIntoMacro() }
            Button("Duplicate") { composition.duplicateSelection() }
            Button("Delete") { composition.deleteSelection() }
        }
        if let node = composition.singleSelection, node.subgraph != nil {
            Button("Open \(node.displayTitle)") { composition.enter(node) }
            if composition.canExplode(node) {
                Button("Explode Macro") { composition.explodeMacro(node) }
            }
        }
    }

    @ViewBuilder private var breadcrumb: some View {
        let chain = composition.macroChain
        if !chain.isEmpty {
            HStack(spacing: 4) {
                Button("Root") { composition.exit(toDepth: 0) }
                ForEach(Array(chain.enumerated()), id: \.element.id) { i, macro in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    if i == chain.count - 1 {
                        Text(macro.displayTitle).fontWeight(.semibold)
                    } else {
                        Button(macro.displayTitle) { composition.exit(toDepth: i + 1) }
                    }
                }
                Text("Esc to go up").font(.caption2).foregroundStyle(.tertiary).padding(.leading, 6)
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(10)
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            Button { setZoom(zoom / 1.2, around: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)) } label: { Image(systemName: "minus.magnifyingglass") }
            Text("\(Int(zoom * 100))%").monospacedDigit().frame(width: 44)
            Button { setZoom(zoom * 1.2, around: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)) } label: { Image(systemName: "plus.magnifyingglass") }
            Button("Fit") { zoomToFit() }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
    }

    private func zoomToFit() {
        guard viewSize.width > 0 else { return }
        guard !graph.nodes.isEmpty else {
            zoom = 1
            offset = CGSize(width: 40, height: 60)
            updateVisibleCenter()
            return
        }
        let bounds = graph.nodes.map(NodeLayout.frame).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -40, dy: -50)
        let z = min(max(min(viewSize.width / bounds.width, viewSize.height / bounds.height), 0.25), 1.5)
        zoom = z
        offset = CGSize(width: (viewSize.width - bounds.width * z) / 2 - bounds.minX * z,
                        height: (viewSize.height - bounds.height * z) / 2 - bounds.minY * z)
        updateVisibleCenter()
    }

    // MARK: Drawing

    private func drawGrid(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let step = 24 * zoom
        guard step > 6 else { return }
        var path = Path()
        var x = offset.width.truncatingRemainder(dividingBy: step)
        while x < size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += step }
        var y = offset.height.truncatingRemainder(dividingBy: step)
        while y < size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += step }
        ctx.stroke(path, with: .color(.white.opacity(0.04)), lineWidth: 1)
    }

    private func wire(_ a: CGPoint, _ b: CGPoint) -> Path {
        var path = Path()
        let dx = max(40, abs(b.x - a.x) * 0.5)
        path.move(to: a)
        path.addCurve(to: b, control1: CGPoint(x: a.x + dx, y: a.y), control2: CGPoint(x: b.x - dx, y: b.y))
        return path
    }

    /// A wire from a node back into itself, routed over the top of the node.
    private func loopWire(_ a: CGPoint, _ b: CGPoint, top: CGFloat) -> Path {
        var path = Path()
        let y = top - 30
        path.move(to: a)
        path.addCurve(to: CGPoint(x: (a.x + b.x) / 2, y: y), control1: CGPoint(x: a.x + 60, y: a.y), control2: CGPoint(x: a.x + 60, y: y))
        path.addCurve(to: b, control1: CGPoint(x: b.x - 60, y: y), control2: CGPoint(x: b.x - 60, y: b.y))
        return path
    }

    private func drawConnections(_ ctx: inout GraphicsContext) {
        for c in graph.connections {
            guard let (a, type) = portPoint(c.from, output: true), let (b, _) = portPoint(c.to, output: false) else { continue }
            let path: Path
            if c.from.node == c.to.node, let node = graph.node(c.from.node) {
                path = loopWire(a, b, top: node.position.y)
            } else {
                path = wire(a, b)
            }
            ctx.stroke(path, with: .color(.black.opacity(0.5)), lineWidth: 4.5)
            ctx.stroke(path, with: .color(type.color), lineWidth: 2)
        }
    }

    private func drawPendingConnection(_ ctx: inout GraphicsContext) {
        guard case .connect(let from, let current) = drag else { return }
        let path = from.isOutput ? wire(from.point, current) : wire(current, from.point)
        ctx.stroke(path, with: .color(from.type.color), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
    }

    private func drawMarquee(_ ctx: inout GraphicsContext) {
        guard case .marquee(let start, let current, _) = drag else { return }
        let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                          width: abs(current.x - start.x), height: abs(current.y - start.y))
        ctx.fill(Path(rect), with: .color(Color.accentColor.opacity(0.12)))
        ctx.stroke(Path(rect), with: .color(Color.accentColor.opacity(0.8)), lineWidth: 1 / zoom)
    }

    private func drawNodes(_ ctx: inout GraphicsContext) {
        let connectedInputs = Set(graph.connections.map(\.to))
        let connectedOutputs = Set(graph.connections.map(\.from))
        for node in graph.nodes where !(node is CommentPatch) {
            let frame = NodeLayout.frame(node)
            let selected = composition.selection.contains(node.id)
            let category = node.category
            let isMacro = node.subgraph != nil
            let body = Path(roundedRect: frame, cornerRadius: 7)

            ctx.fill(Path(roundedRect: frame.offsetBy(dx: 0, dy: 3), cornerRadius: 7), with: .color(.black.opacity(0.35)))
            if isMacro {
                // Stacked look for patches that contain a graph.
                ctx.fill(Path(roundedRect: frame.offsetBy(dx: 5, dy: -5), cornerRadius: 7), with: .color(Color(white: 0.26)))
            }
            ctx.fill(body, with: .color(Color(white: 0.19)))

            var header = Path()
            header.addRoundedRect(in: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: NodeLayout.header),
                                  cornerSize: CGSize(width: 7, height: 7), style: .continuous)
            ctx.fill(header, with: .linearGradient(
                Gradient(colors: [category.color.opacity(0.95), category.color.opacity(0.7)]),
                startPoint: CGPoint(x: frame.minX, y: frame.minY), endPoint: CGPoint(x: frame.minX, y: frame.minY + NodeLayout.header)))

            let title = (isMacro ? "⧉ " : "") + node.headerTitle
            ctx.draw(Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundColor(.white),
                     at: CGPoint(x: frame.minX + 10, y: frame.minY + NodeLayout.header / 2), anchor: .leading)

            if let layer = graph.layerIndex(of: node) {
                ctx.draw(Text("#\(layer)").font(.system(size: 10, weight: .bold).monospacedDigit()).foregroundColor(.white.opacity(0.75)),
                         at: CGPoint(x: frame.maxX - 10, y: frame.minY + NodeLayout.header / 2), anchor: .trailing)
            }
            if node.statusMessage != nil {
                let dot = CGRect(x: frame.maxX - (category == .consumer ? 38 : 16), y: frame.minY + 8, width: 8, height: 8)
                ctx.fill(Path(ellipseIn: dot), with: .color(.red))
            }

            for (i, spec) in node.inputPorts.enumerated() {
                let pt = NodeLayout.inputPoint(node, i)
                drawPort(&ctx, pt, spec.type, filled: connectedInputs.contains(PortRef(node: node.id, port: spec.key)))
                ctx.draw(Text(spec.name).font(.system(size: 10.5)).foregroundColor(.white.opacity(0.82)),
                         at: CGPoint(x: pt.x + 10, y: pt.y), anchor: .leading)
            }
            for (i, spec) in node.outputPorts.enumerated() {
                let pt = NodeLayout.outputPoint(node, i)
                drawPort(&ctx, pt, spec.type, filled: connectedOutputs.contains(PortRef(node: node.id, port: spec.key)))
                ctx.draw(Text(spec.name).font(.system(size: 10.5)).foregroundColor(.white.opacity(0.82)),
                         at: CGPoint(x: pt.x - 10, y: pt.y), anchor: .trailing)
            }

            ctx.stroke(body, with: .color(selected ? Color.accentColor : .white.opacity(0.12)), lineWidth: selected ? 2 : 1)
        }
    }

    private func drawComments(_ ctx: inout GraphicsContext) {
        for case let comment as CommentPatch in graph.nodes {
            let frame = NodeLayout.frame(comment)
            let rgb = comment.rgb
            let fill = Color(red: rgb.x, green: rgb.y, blue: rgb.z)
            let shape = Path(roundedRect: frame, cornerRadius: 4)
            ctx.fill(Path(roundedRect: frame.offsetBy(dx: 0, dy: 3), cornerRadius: 4), with: .color(.black.opacity(0.3)))
            ctx.fill(shape, with: .color(fill.opacity(0.92)))
            if editingComment != comment.id {
                let text = comment.text.isEmpty ? "Double-click to write a note" : comment.text
                ctx.draw(Text(text).font(.system(size: 12)).foregroundColor(.black.opacity(comment.text.isEmpty ? 0.35 : 0.85)),
                         in: frame.insetBy(dx: 9, dy: 8))
            }
            // Resize grip.
            let h = NodeLayout.resizeHandle(comment)
            var grip = Path()
            for k in stride(from: CGFloat(4), through: 12, by: 4) {
                grip.move(to: CGPoint(x: h.maxX - k, y: h.maxY - 2))
                grip.addLine(to: CGPoint(x: h.maxX - 2, y: h.maxY - k))
            }
            ctx.stroke(grip, with: .color(.black.opacity(0.3)), lineWidth: 1)
            let selected = composition.selection.contains(comment.id)
            ctx.stroke(shape, with: .color(selected ? Color.accentColor : .black.opacity(0.15)), lineWidth: selected ? 2 : 1)
        }
    }

    // MARK: Comment editing & port tooltips

    @ViewBuilder private var commentEditor: some View {
        if let id = editingComment, let comment = graph.node(id) as? CommentPatch {
            let size = comment.size
            NoteEditor(text: Binding(get: { comment.text },
                                     set: { composition.setParam(comment, "text", .string($0)) }),
                       onFinish: { editingComment = nil; focused = true })
                .frame(width: size.width, height: size.height)
                .scaleEffect(zoom, anchor: .topLeading)
                .offset(x: offset.width + comment.position.x * zoom, y: offset.height + comment.position.y * zoom)
        }
    }

    /// What a port currently carries, and where it comes from.
    private func currentValue(_ hit: PortHit) -> (value: Value?, source: String?) {
        guard let node = graph.node(hit.ref.node) else { return (nil, nil) }
        if hit.isOutput { return (node.lastOutputs[hit.ref.port], nil) }
        if let c = graph.connection(into: hit.ref), let src = graph.node(c.from.node) {
            let name = src.outputPorts.first { $0.key == c.from.port }?.name ?? c.from.port
            return (src.lastOutputs[c.from.port], "from \(src.displayTitle) · \(name)")
        }
        let spec = node.inputPorts.first { $0.key == hit.ref.port }
        return ((node.params[hit.ref.port] ?? spec?.defaultValue)?.coerced(to: hit.type), nil)
    }

    @ViewBuilder private var portTooltip: some View {
        if let hit = hoveredPort, drag == nil, let node = graph.node(hit.ref.node) {
            let name = (hit.isOutput ? node.outputPorts : node.inputPorts).first { $0.key == hit.ref.port }?.name ?? hit.ref.port
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let current = currentValue(hit)
                PortValueBubble(name: name, type: hit.type, value: current.value, source: current.source)
            }
            .fixedSize()
            .allowsHitTesting(false)
            .offset(x: offset.width + hit.point.x * zoom + 10, y: offset.height + hit.point.y * zoom + 12)
        }
    }

    private func drawPort(_ ctx: inout GraphicsContext, _ p: CGPoint, _ type: PortType, filled: Bool) {
        let r: CGFloat = 4.5
        let circle = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        ctx.fill(circle, with: .color(filled ? type.color : Color(white: 0.12)))
        ctx.stroke(circle, with: .color(type.color), lineWidth: 1.5)
    }
}

/// QC-style tooltip showing the live value on a port.
private struct PortValueBubble: View {
    let name: String
    let type: PortType
    let value: Value?
    let source: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(type.color).frame(width: 8, height: 8)
                Text(name).fontWeight(.semibold)
                Text(type.displayName).foregroundStyle(.secondary)
            }
            if let source { Text(source).foregroundStyle(.secondary) }
            content
        }
        .font(.caption)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.12)))
        .shadow(radius: 6, y: 2)
    }

    @ViewBuilder private var content: some View {
        switch value {
        case nil:
            Text("Not evaluated (nothing uses it)").foregroundStyle(.secondary)
        case .image(let texture)?:
            if let texture, let thumb = TexturePreview.thumbnail(texture) {
                Image(decorative: thumb, scale: 1)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Text(verbatim: "\(texture.width) × \(texture.height)").monospacedDigit().foregroundStyle(.secondary)
            } else {
                Text("No image").foregroundStyle(.secondary)
            }
        case .color(let c)?:
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z), opacity: Double(c.w)))
                    .frame(width: 18, height: 18)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.3)))
                Text(value!.summary).monospacedDigit()
            }
        case let v?:
            Text(v.summary).monospacedDigit().lineLimit(10).frame(maxWidth: 260, alignment: .leading)
        }
    }
}

#if os(macOS)
/// Inline text editor for comments. Escape ends editing; a plain SwiftUI TextEditor
/// can't do this because NSTextView consumes Escape before SwiftUI sees it.
private struct NoteEditor: NSViewRepresentable {
    @Binding var text: String
    var onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Catches Escape at the key level, before key bindings turn it into completion.
    final class TextView: NSTextView {
        var onEscape: (() -> Void)?
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
        }
    }

    func makeNSView(context: Context) -> TextView {
        let tv = TextView()
        tv.onEscape = onFinish
        tv.font = .systemFont(ofSize: 12)
        tv.textColor = NSColor.black.withAlphaComponent(0.85)
        tv.insertionPointColor = .black
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.textContainerInset = NSSize(width: 4, height: 8)
        tv.string = text
        tv.delegate = context.coordinator
        // After SwiftUI has applied its own focus changes for this click.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            tv.window?.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        }
        return tv
    }

    func updateNSView(_ tv: TextView, context: Context) {
        context.coordinator.parent = self
        tv.onEscape = onFinish
        if tv.string != text { tv.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteEditor
        init(_ parent: NoteEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}
#else
/// Inline text editor for comments. Escape (on a hardware keyboard) ends editing.
private struct NoteEditor: UIViewRepresentable {
    @Binding var text: String
    var onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class TextView: UITextView {
        var onEscape: (() -> Void)?

        override var keyCommands: [UIKeyCommand]? {
            [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape))]
        }

        @objc private func escape() { onEscape?() }
    }

    func makeUIView(context: Context) -> TextView {
        let tv = TextView()
        tv.onEscape = onFinish
        tv.font = .systemFont(ofSize: 12)
        tv.textColor = UIColor.black.withAlphaComponent(0.85)
        tv.tintColor = .black
        tv.backgroundColor = .clear
        tv.smartQuotesType = .no
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        tv.text = text
        tv.delegate = context.coordinator
        DispatchQueue.main.async { tv.becomeFirstResponder() }
        return tv
    }

    func updateUIView(_ tv: TextView, context: Context) {
        context.coordinator.parent = self
        tv.onEscape = onFinish
        if tv.text != text { tv.text = text }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NoteEditor
        init(_ parent: NoteEditor) { self.parent = parent }

        func textViewDidChange(_ tv: UITextView) { parent.text = tv.text }
    }
}
#endif
