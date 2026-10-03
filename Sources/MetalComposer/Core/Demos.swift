import Foundation

enum Demo: String, CaseIterable, Identifiable {
    case basics = "Basics"
    case feedback = "Feedback Trails"
    case iterator = "Iterator"
    case cube = "3D Cube"
    case structures = "Structures & Queue"

    var id: String { rawValue }

    func build(into g: Graph) {
        switch self {
        case .basics: Self.basics(g)
        case .feedback: Self.feedback(g)
        case .iterator: Self.iterator(g)
        case .cube: Self.cube(g)
        case .structures: Self.structures(g)
        }
    }

    private static func basics(_ g: Graph) {
        g.put(ClearPatch.self, 640, 40, ["color": .color(SIMD4(0.02, 0.02, 0.05, 1))])
        let shader = g.put(MetalShaderPatch.self, 640, 110)
        let sprite = g.put(BillboardPatch.self, 640, 300, ["width": .number(1.3), "height": .number(0)])
        let particles = g.put(ParticleSystemPatch.self, 640, 520)

        let hueLFO = g.put(LFOPatch.self, 40, 40, ["type": .number(4), "period": .number(10), "amplitude": .number(0.5), "offset": .number(0.5)])
        let text = g.put(TextImagePatch.self, 40, 190, ["text": .string("Metal Composer"), "size": .number(120)])
        let bob = g.put(LFOPatch.self, 40, 300, ["period": .number(4), "amplitude": .number(0.06), "offset": .number(0)])
        let wobble = g.put(MathExpressionPatch.self, 40, 450, ["expression": .string("sin(t * 1.3) * 3 + a")])
        let mouse = g.put(MousePatch.self, 40, 590)
        let hsl = g.put(HSLColorPatch.self, 320, 600, ["saturation": .number(0.8), "luminosity": .number(0.6)])

        g.link(hueLFO, "value", shader, "p2")
        g.link(hueLFO, "value", hsl, "hue")
        g.link(text, "image", sprite, "image")
        g.link(bob, "value", sprite, "y")
        g.link(wobble, "result", sprite, "rotation")
        g.link(mouse, "x", particles, "x")
        g.link(mouse, "y", particles, "y")
        g.link(hsl, "color", particles, "color")
    }

    /// A Render In Image whose output is fed back into itself, slightly zoomed and rotated.
    private static func feedback(_ g: Graph) {
        g.put(ClearPatch.self, 680, 40, ["color": .color(SIMD4(0, 0, 0, 1))])
        let rim = g.put(RenderInImagePatch.self, 360, 130, ["clear": .color(SIMD4(0, 0, 0, 1))], name: "Feedback")
        let show = g.put(BillboardPatch.self, 680, 120, ["width": .number(2), "height": .number(0)], name: "Show Result")
        let speed = g.put(NumberPatch.self, 40, 140, ["value": .number(1)], name: "Speed")
        let mouse = g.put(MousePatch.self, 40, 240)

        let sub = rim.contents
        let previous = sub.put(PublishedInputPatch.self, 40, 40, name: "Previous Frame")
        previous.portType = .image
        let speedIn = sub.put(PublishedInputPatch.self, 40, 300, name: "Speed")
        let mx = sub.put(PublishedInputPatch.self, 40, 400, name: "Mouse X")
        let my = sub.put(PublishedInputPatch.self, 40, 500, name: "Mouse Y")
        let trail = sub.put(BillboardPatch.self, 640, 40, ["width": .number(2.03), "height": .number(0),
                                                        "rotation": .number(0.7), "color": .color(SIMD4(1, 1, 1, 0.965))],
                            name: "Previous (zoom + fade)")
        let px = sub.put(MathExpressionPatch.self, 320, 220, ["expression": .string("sin(t * 1.7 * b) * 0.55 + a * 0.3")], name: "Brush X")
        let py = sub.put(MathExpressionPatch.self, 320, 360, ["expression": .string("sin(t * 2.3 * b) * 0.28 + a * 0.3")], name: "Brush Y")
        let spin = sub.put(MathExpressionPatch.self, 320, 500, ["expression": .string("t * 120 * b")], name: "Spin")
        let hue = sub.put(LFOPatch.self, 40, 140, ["type": .number(4), "period": .number(6), "amplitude": .number(0.5), "offset": .number(0.5)])
        let hsl = sub.put(HSLColorPatch.self, 320, 80, ["saturation": .number(0.9), "luminosity": .number(0.6)])
        let brush = sub.put(BillboardPatch.self, 640, 260, ["width": .number(0.09), "height": .number(0.09)], name: "Brush")

        sub.link(previous, "value", trail, "image")
        sub.link(hue, "value", hsl, "hue")
        sub.link(hsl, "color", brush, "color")
        sub.link(mx, "value", px, "a")
        sub.link(my, "value", py, "a")
        for e in [px, py, spin] { sub.link(speedIn, "value", e, "b") }
        sub.link(px, "result", brush, "x")
        sub.link(py, "result", brush, "y")
        sub.link(spin, "result", brush, "rotation")

        g.link(rim, "image", show, "image")
        g.link(rim, "image", rim, previous.portKey) // the feedback loop
        g.link(speed, "value", rim, speedIn.portKey)
        g.link(mouse, "x", rim, mx.portKey)
        g.link(mouse, "y", rim, my.portKey)
    }

    /// An Iterator drawing a ring of sprites whose radius is driven from outside.
    private static func iterator(_ g: Graph) {
        g.put(ClearPatch.self, 640, 40, ["color": .color(SIMD4(0.03, 0.03, 0.06, 1))])
        let iter = g.put(IteratorPatch.self, 360, 140, ["iterations": .number(48)], name: "Ring")
        let radius = g.put(LFOPatch.self, 40, 140, ["period": .number(6), "amplitude": .number(0.2), "offset": .number(0.5)], name: "Radius")

        let sub = iter.contents
        let vars = sub.nodes.compactMap { $0 as? IteratorVariablesPatch }.first!
        let radiusIn = sub.put(PublishedInputPatch.self, 40, 200, name: "Radius")
        let ex = sub.put(MathExpressionPatch.self, 320, 40, ["expression": .string("cos(a * 2 * pi + t * 0.4) * b")], name: "X")
        let ey = sub.put(MathExpressionPatch.self, 320, 180, ["expression": .string("sin(a * 4 * pi + t * 0.7) * b * 0.55")], name: "Y")
        let size = sub.put(MathExpressionPatch.self, 320, 320, ["expression": .string("0.03 + 0.025 * sin(t * 3 + a * 18)")], name: "Size")
        let rot = sub.put(MathExpressionPatch.self, 320, 460, ["expression": .string("t * 60 + a * 360")], name: "Rotation")
        let hsl = sub.put(HSLColorPatch.self, 320, 600, ["saturation": .number(0.85), "luminosity": .number(0.6)])
        let sprite = sub.put(BillboardPatch.self, 640, 160, ["blending": .number(1)])

        for e in [ex, ey, size, rot] { sub.link(vars, "position", e, "a") }
        sub.link(radiusIn, "value", ex, "b")
        sub.link(radiusIn, "value", ey, "b")
        sub.link(vars, "position", hsl, "hue")
        sub.link(ex, "result", sprite, "x")
        sub.link(ey, "result", sprite, "y")
        sub.link(size, "result", sprite, "width")
        sub.link(size, "result", sprite, "height")
        sub.link(rot, "result", sprite, "rotation")
        sub.link(hsl, "color", sprite, "color")

        g.link(radius, "value", iter, radiusIn.portKey)
    }

    /// Six opaque 3D Sprites forming a cube (sorted by the depth buffer) inside a 3D Transformation,
    /// with a Billboard label that always faces the viewer.
    private static func cube(_ g: Graph) {
        g.put(ClearPatch.self, 640, 40, ["color": .color(SIMD4(0.02, 0.02, 0.04, 1))])
        let cube = g.put(Transform3DPatch.self, 360, 120, name: "Cube")
        let spinX = g.put(MathExpressionPatch.self, 40, 120, ["expression": .string("t * 37")], name: "Spin X")
        let spinY = g.put(MathExpressionPatch.self, 40, 260, ["expression": .string("t * 23")], name: "Spin Y")
        g.link(spinX, "result", cube, "rx")
        g.link(spinY, "result", cube, "ry")

        let h: Double = 0.3
        let faces: [(String, [String: Value], SIMD4<Float>)] = [
            ("Front", ["z": .number(h)], SIMD4(0.95, 0.35, 0.3, 1)),
            ("Back", ["z": .number(-h)], SIMD4(0.3, 0.55, 0.95, 1)),
            ("Right", ["x": .number(h), "rotationY": .number(90)], SIMD4(0.35, 0.85, 0.45, 1)),
            ("Left", ["x": .number(-h), "rotationY": .number(90)], SIMD4(0.95, 0.8, 0.3, 1)),
            ("Top", ["y": .number(h), "rotationX": .number(90)], SIMD4(0.7, 0.4, 0.95, 1)),
            ("Bottom", ["y": .number(-h), "rotationX": .number(90)], SIMD4(0.3, 0.85, 0.85, 1)),
        ]
        let sub = cube.contents
        for (i, face) in faces.enumerated() {
            var params = face.1
            params["width"] = .number(2 * h)
            params["height"] = .number(2 * h)
            params["color"] = .color(face.2)
            sub.put(SpritePatch.self, CGFloat(40 + (i % 3) * 220), CGFloat(40 + (i / 3) * 280), params, name: face.0)
        }
        let label = sub.put(TextImagePatch.self, 40, 600, ["text": .string("Metal"), "size": .number(96)])
        let billboard = sub.put(BillboardPatch.self, 300, 600, ["width": .number(0.32)], name: "Label (faces viewer)")
        sub.link(label, "image", billboard, "image")
    }

    /// A moving point packed into a {x, y} structure, queued for 60 frames and drawn back by an
    /// Iterator as a trail: Structure Maker → Queue → Structure Count / Index Member / Key Member.
    private static func structures(_ g: Graph) {
        g.put(ClearPatch.self, 980, 40, ["color": .color(SIMD4(0.02, 0.02, 0.04, 1))])
        let px = g.put(MathExpressionPatch.self, 40, 60, ["expression": .string("sin(t * 1.3) * 0.7 + sin(t * 3.1) * 0.1")], name: "Path X")
        let py = g.put(MathExpressionPatch.self, 40, 200, ["expression": .string("sin(t * 2.1) * 0.35")], name: "Path Y")
        let maker = g.put(StructureMakerPatch.self, 300, 100, ["count": .number(2), "keys": .string("x, y")], name: "Point")
        let queue = g.put(QueuePatch.self, 540, 100, ["size": .number(60)], name: "Last 60 Points")
        let count = g.put(StructureCountPatch.self, 540, 280)
        let trail = g.put(IteratorPatch.self, 780, 120, name: "Trail")
        g.link(px, "result", maker, "m0")
        g.link(py, "result", maker, "m1")
        g.link(maker, "structure", queue, "value")
        g.link(queue, "queue", count, "structure")
        g.link(count, "count", trail, "iterations")

        let sub = trail.contents
        let vars = sub.nodes.compactMap { $0 as? IteratorVariablesPatch }.first!
        let points = sub.put(PublishedInputPatch.self, 40, 200, name: "Points")
        points.portType = .structure
        let pick = sub.put(StructureIndexMemberPatch.self, 300, 120)
        let kx = sub.put(StructureKeyMemberPatch.self, 540, 60, ["key": .string("x")])
        let ky = sub.put(StructureKeyMemberPatch.self, 540, 180, ["key": .string("y")])
        let size = sub.put(MathExpressionPatch.self, 540, 300, ["expression": .string("0.01 + 0.05 * a")], name: "Size")
        let hsl = sub.put(HSLColorPatch.self, 540, 440, ["saturation": .number(0.85), "luminosity": .number(0.6)])
        let dot = sub.put(BillboardPatch.self, 800, 160, ["blending": .number(1)], name: "Dot")
        sub.link(points, "value", pick, "structure")
        sub.link(vars, "index", pick, "index")
        sub.link(pick, "member", kx, "structure")
        sub.link(pick, "member", ky, "structure")
        sub.link(vars, "position", size, "a")
        sub.link(vars, "position", hsl, "hue")
        sub.link(kx, "member", dot, "x")
        sub.link(ky, "member", dot, "y")
        sub.link(size, "result", dot, "width")
        sub.link(size, "result", dot, "height")
        sub.link(hsl, "color", dot, "color")

        g.link(queue, "queue", trail, points.portKey)
    }
}
