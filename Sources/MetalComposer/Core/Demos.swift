import Foundation

enum Demo: String, CaseIterable, Identifiable {
    case basics = "Basics"
    case feedback = "Feedback Trails"
    case iterator = "Iterator"

    var id: String { rawValue }

    func build(into g: Graph) {
        switch self {
        case .basics: Self.basics(g)
        case .feedback: Self.feedback(g)
        case .iterator: Self.iterator(g)
        }
    }

    private static func basics(_ g: Graph) {
        g.put(ClearPatch.self, 640, 40, ["color": .color(SIMD4(0.02, 0.02, 0.05, 1))])
        let shader = g.put(MetalShaderPatch.self, 640, 110)
        let sprite = g.put(SpritePatch.self, 640, 300, ["width": .number(1.3), "height": .number(0)])
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
        let show = g.put(SpritePatch.self, 680, 120, ["width": .number(2), "height": .number(0)], name: "Show Result")
        let speed = g.put(NumberPatch.self, 40, 140, ["value": .number(1)], name: "Speed")
        let mouse = g.put(MousePatch.self, 40, 240)

        let sub = rim.contents
        let previous = sub.put(PublishedInputPatch.self, 40, 40, name: "Previous Frame")
        previous.portType = .image
        let speedIn = sub.put(PublishedInputPatch.self, 40, 300, name: "Speed")
        let mx = sub.put(PublishedInputPatch.self, 40, 400, name: "Mouse X")
        let my = sub.put(PublishedInputPatch.self, 40, 500, name: "Mouse Y")
        let trail = sub.put(SpritePatch.self, 640, 40, ["width": .number(2.03), "height": .number(0),
                                                        "rotation": .number(0.7), "color": .color(SIMD4(1, 1, 1, 0.965))],
                            name: "Previous (zoom + fade)")
        let px = sub.put(MathExpressionPatch.self, 320, 220, ["expression": .string("sin(t * 1.7 * b) * 0.55 + a * 0.3")], name: "Brush X")
        let py = sub.put(MathExpressionPatch.self, 320, 360, ["expression": .string("sin(t * 2.3 * b) * 0.28 + a * 0.3")], name: "Brush Y")
        let spin = sub.put(MathExpressionPatch.self, 320, 500, ["expression": .string("t * 120 * b")], name: "Spin")
        let hue = sub.put(LFOPatch.self, 40, 140, ["type": .number(4), "period": .number(6), "amplitude": .number(0.5), "offset": .number(0.5)])
        let hsl = sub.put(HSLColorPatch.self, 320, 80, ["saturation": .number(0.9), "luminosity": .number(0.6)])
        let brush = sub.put(SpritePatch.self, 640, 260, ["width": .number(0.09), "height": .number(0.09)], name: "Brush")

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
        let sprite = sub.put(SpritePatch.self, 640, 160, ["blending": .number(1)])

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
}
