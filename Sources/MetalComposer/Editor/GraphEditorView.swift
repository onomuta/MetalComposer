import AppKit
import SwiftUI

extension PortType {
    var color: Color {
        switch self {
        case .number: return Color(red: 0.55, green: 0.7, blue: 0.95)
        case .bool: return Color(red: 0.95, green: 0.8, blue: 0.3)
        case .color: return Color(red: 0.95, green: 0.45, blue: 0.65)
        case .string: return Color(red: 0.5, green: 0.85, blue: 0.55)
        case .image: return Color(red: 0.75, green: 0.55, blue: 0.95)
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
        let rows = max(node.inputPorts.count, node.outputPorts.count, 1)
        return CGRect(x: node.position.x, y: node.position.y, width: width,
                      height: header + CGFloat(rows) * row + footer)
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
        case ignore
    }

    private var graph: Graph { composition.graph }

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                _ = redrawTick
                drawGrid(&ctx, size)
                var g = ctx
                g.translateBy(x: offset.width, y: offset.height)
                g.scaleBy(x: zoom, y: zoom)
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
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in composition.deleteSelection(); return .handled }
            .onKeyPress(.escape) {
                if !composition.path.isEmpty { composition.exit(toDepth: composition.path.count - 1) }
                return .handled
            }
            .onCommand(#selector(NSText.copy(_:))) { composition.copySelection() }
            .onCommand(#selector(NSText.cut(_:))) { composition.cutSelection() }
            .onCommand(#selector(NSText.paste(_:))) { composition.paste() }
            .onCommand(#selector(NSText.selectAll(_:))) { composition.selectAll() }
            .onCommand(#selector(NSText.delete(_:))) { composition.deleteSelection() }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hovering = true; pointer = p
                case .ended: hovering = false
                }
            }
            .contextMenu { contextMenu }
            .overlay(alignment: .topLeading) { breadcrumb }
            .overlay(alignment: .bottomTrailing) { zoomControls }
            .onAppear { viewSize = geo.size; zoomToFit(); installScrollMonitor() }
            .onDisappear { if let m = scrollMonitor { NSEvent.removeMonitor(m) } }
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
        graph.nodes.last { NodeLayout.frame($0).contains(p) }
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
        let p = toGraph(screenPoint)
        let mods = NSEvent.modifierFlags
        let extend = mods.contains(.shift) || mods.contains(.command)

        if let port = hitPort(p) {
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
        } else if mods.contains(.option) {
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
        if let last = lastClick, last.id == id, now.timeIntervalSince(last.time) < 0.35,
           let node = graph.node(id), node.subgraph != nil {
            lastClick = nil
            composition.enter(node)
            return
        }
        lastClick = (id, now)
        let mods = NSEvent.modifierFlags
        if !mods.contains(.shift), !mods.contains(.command) {
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
        if !composition.selection.isEmpty {
            Divider()
            Button("Group into Macro") { composition.groupSelectionIntoMacro() }
            Button("Duplicate") { composition.duplicateSelection() }
            Button("Delete") { composition.deleteSelection() }
        }
        if let node = composition.singleSelection, node.subgraph != nil {
            Button("Open \(node.displayTitle)") { composition.enter(node) }
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
        for node in graph.nodes {
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

    private func drawPort(_ ctx: inout GraphicsContext, _ p: CGPoint, _ type: PortType, filled: Bool) {
        let r: CGFloat = 4.5
        let circle = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        ctx.fill(circle, with: .color(filled ? type.color : Color(white: 0.12)))
        ctx.stroke(circle, with: .color(type.color), lineWidth: 1.5)
    }
}
