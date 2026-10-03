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
    @State private var hovering = false
    @State private var pointer: CGPoint = .zero
    @State private var viewSize: CGSize = .zero
    @State private var scrollMonitor: Any?
    @FocusState private var focused: Bool

    private struct PortHit {
        var ref: PortRef
        var isOutput: Bool
        var type: PortType
        var point: CGPoint
    }

    private enum DragMode {
        case pan(start: CGSize)
        case move(id: UUID, grab: CGSize)
        case connect(from: PortHit, current: CGPoint)
    }

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                drawGrid(&ctx, size)
                var g = ctx
                g.translateBy(x: offset.width, y: offset.height)
                g.scaleBy(x: zoom, y: zoom)
                drawConnections(&g)
                drawNodes(&g)
                drawPendingConnection(&g)
            }
            .background(Color(white: 0.11))
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .simultaneousGesture(magnifyGesture)
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                if let id = composition.selection { composition.remove(id) }
                return .handled
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hovering = true; pointer = p
                case .ended: hovering = false
                }
            }
            .contextMenu { addPatchMenu }
            .overlay(alignment: .bottomTrailing) { zoomControls }
            .onAppear { viewSize = geo.size; zoomToFit(); installScrollMonitor() }
            .onDisappear { if let m = scrollMonitor { NSEvent.removeMonitor(m) } }
            .onChange(of: geo.size) { _, s in viewSize = s; updateVisibleCenter() }
            .onReceive(NotificationCenter.default.publisher(for: .compositionReplaced)) { _ in zoomToFit() }
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
        for node in composition.nodes.reversed() {
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
        composition.nodes.last { NodeLayout.frame($0).contains(p) }
    }

    private func portPoint(_ ref: PortRef, output: Bool) -> (CGPoint, PortType)? {
        guard let node = composition.node(ref.node) else { return nil }
        let ports = output ? node.outputPorts : node.inputPorts
        guard let i = ports.firstIndex(where: { $0.key == ref.port }) else { return nil }
        return (output ? NodeLayout.outputPoint(node, i) : NodeLayout.inputPoint(node, i), ports[i].type)
    }

    // MARK: Gestures

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if drag == nil { beginDrag(at: value.startLocation) }
                switch drag {
                case .pan(let start):
                    offset = CGSize(width: start.width + value.translation.width,
                                    height: start.height + value.translation.height)
                case .move(let id, let grab):
                    let p = toGraph(value.location)
                    composition.node(id)?.position = CGPoint(x: p.x - grab.width, y: p.y - grab.height)
                    composition.touch()
                case .connect(let from, _):
                    drag = .connect(from: from, current: toGraph(value.location))
                case nil: break
                }
            }
            .onEnded { value in
                if case .connect(let from, _) = drag, let target = hitPort(toGraph(value.location)),
                   target.isOutput != from.isOutput {
                    if from.isOutput {
                        composition.connect(from: from.ref, to: target.ref)
                    } else {
                        composition.connect(from: target.ref, to: from.ref)
                    }
                }
                if case .pan = drag { updateVisibleCenter() }
                drag = nil
            }
    }

    private func beginDrag(at screenPoint: CGPoint) {
        focused = true
        let p = toGraph(screenPoint)
        if let port = hitPort(p) {
            if !port.isOutput, let existing = composition.connection(into: port.ref),
               let (pt, type) = portPoint(existing.from, output: true) {
                // Grabbing a connected input detaches the wire so it can be re-plugged or dropped.
                composition.disconnect(existing)
                drag = .connect(from: PortHit(ref: existing.from, isOutput: true, type: type, point: pt), current: p)
            } else {
                drag = .connect(from: port, current: p)
            }
        } else if let node = hitNode(p) {
            composition.selection = node.id
            drag = .move(id: node.id, grab: CGSize(width: p.x - node.position.x, height: p.y - node.position.y))
        } else {
            composition.selection = nil
            drag = .pan(start: offset)
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

    @ViewBuilder private var addPatchMenu: some View {
        ForEach(PatchCategory.allCases) { category in
            Menu(category.rawValue) {
                ForEach(PatchRegistry.all.filter { $0.category == category }, id: \.typeID) { type in
                    Button(type.title) {
                        let p = toGraph(pointer)
                        composition.add(type, at: CGPoint(x: p.x - 20, y: p.y - 10))
                    }
                }
            }
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
        guard !composition.nodes.isEmpty, viewSize.width > 0 else { return }
        let bounds = composition.nodes.map(NodeLayout.frame).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -40, dy: -40)
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

    private func drawConnections(_ ctx: inout GraphicsContext) {
        for c in composition.connections {
            guard let (a, type) = portPoint(c.from, output: true), let (b, _) = portPoint(c.to, output: false) else { continue }
            let path = wire(a, b)
            ctx.stroke(path, with: .color(.black.opacity(0.5)), lineWidth: 4.5)
            ctx.stroke(path, with: .color(type.color), lineWidth: 2)
        }
    }

    private func drawPendingConnection(_ ctx: inout GraphicsContext) {
        guard case .connect(let from, let current) = drag else { return }
        let path = from.isOutput ? wire(from.point, current) : wire(current, from.point)
        ctx.stroke(path, with: .color(from.type.color), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
    }

    private func drawNodes(_ ctx: inout GraphicsContext) {
        let connectedInputs = Set(composition.connections.map(\.to))
        let connectedOutputs = Set(composition.connections.map(\.from))
        for node in composition.nodes {
            let frame = NodeLayout.frame(node)
            let selected = composition.selection == node.id
            let body = Path(roundedRect: frame, cornerRadius: 7)

            ctx.fill(Path(roundedRect: frame.offsetBy(dx: 0, dy: 3), cornerRadius: 7), with: .color(.black.opacity(0.35)))
            ctx.fill(body, with: .color(Color(white: 0.19)))

            var header = Path()
            header.addRoundedRect(in: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: NodeLayout.header),
                                  cornerSize: CGSize(width: 7, height: 7), style: .continuous)
            ctx.fill(header, with: .linearGradient(
                Gradient(colors: [node.category.color.opacity(0.95), node.category.color.opacity(0.7)]),
                startPoint: CGPoint(x: frame.minX, y: frame.minY), endPoint: CGPoint(x: frame.minX, y: frame.minY + NodeLayout.header)))

            ctx.draw(Text(node.title).font(.system(size: 11.5, weight: .semibold)).foregroundColor(.white),
                     at: CGPoint(x: frame.minX + 10, y: frame.minY + NodeLayout.header / 2), anchor: .leading)

            if let layer = composition.layerIndex(of: node) {
                ctx.draw(Text("#\(layer)").font(.system(size: 10, weight: .bold).monospacedDigit()).foregroundColor(.white.opacity(0.75)),
                         at: CGPoint(x: frame.maxX - 10, y: frame.minY + NodeLayout.header / 2), anchor: .trailing)
            }
            if node.statusMessage != nil {
                let dot = CGRect(x: frame.maxX - (node.category == .consumer ? 38 : 16), y: frame.minY + 8, width: 8, height: 8)
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
