import Metal
import XCTest
@testable import MetalComposer

final class TimeBaseTests: XCTestCase {
    private func inputs(_ patch: Patch, _ values: [String: Value] = [:]) -> Inputs {
        var v: [String: Value] = [:]
        for spec in patch.allInputs { v[spec.key] = (values[spec.key] ?? patch.params[spec.key] ?? spec.defaultValue).coerced(to: spec.type) }
        return Inputs(values: v)
    }

    private func positions(_ list: [ParticleInstance]) -> [SIMD3<Float>] {
        list.map { SIMD3($0.position.x, $0.position.y, $0.z) }
    }

    /// Plays from 0 to `end` in 60 fps steps with the emitter following `path`.
    private func play(_ p: ParticleSystemPatch, from start: Double = 0, to end: Double,
                      path: (Double) -> Float = { _ in 0 }) -> [ParticleInstance] {
        // Times from frame numbers (not by adding 1/60 repeatedly), so runs land on identical times.
        var last: [ParticleInstance] = []
        let frames = Int(((end - start) * 60).rounded())
        for f in 0...frames {
            let t = start + Double(f) / 60
            last = p.instances(inputs(p, ["x": .number(Double(path(t)))]), time: t)
        }
        return last
    }

    func testParticlesRewindPauseAndJumpToTheSamePicture() {
        let p = ParticleSystemPatch()
        let path: (Double) -> Float = { Float(sin($0 * 2) * 0.5) }
        let forward = play(p, to: 2, path: path)
        XCTAssertFalse(forward.isEmpty)
        XCTAssertLessThanOrEqual(forward.count, 600)

        // Pause: asking again for the same time changes nothing.
        XCTAssertEqual(positions(p.instances(inputs(p, ["x": .number(Double(path(2)))]), time: 2)), positions(forward))

        // Rewind to 0.5, then play forward again to 2: identical.
        let rewound = p.instances(inputs(p, ["x": .number(Double(path(0.5)))]), time: 0.5)
        XCTAssertLessThan(rewound.count, forward.count)
        let replayed = play(p, from: 0.5, to: 2, path: path)
        XCTAssertEqual(positions(replayed), positions(forward))

        // Jump straight to a later time without the frames in between: still consistent.
        let fresh = ParticleSystemPatch()
        _ = play(fresh, to: 2, path: path)
        XCTAssertEqual(positions(fresh.instances(inputs(fresh, ["x": .number(Double(path(2)))]), time: 2)), positions(forward))
        XCTAssertTrue(p.instances(inputs(p), time: -1).isEmpty, "nothing before time 0")
    }

    func testMovingEmitterLeavesATrail() {
        let p = ParticleSystemPatch()
        let out = play(p, to: 2, path: { Float($0) * 0.5 - 0.5 }) // emitter moves from -0.5 to 0.5
        let xs = out.map(\.position.x)
        XCTAssertGreaterThan(xs.max()! - xs.min()!, 0.5, "particles keep the emitter position from their birth")
    }

    func testTimeBaseInputs() {
        let lfo = LFOPatch()
        XCTAssertTrue(lfo.allInputs.contains { $0.key == "timeBase" && !$0.isPort })
        XCTAssertFalse(lfo.inputPorts.contains { $0.key == "patchTime" })
        lfo.params["timeBase"] = .number(2)
        XCTAssertTrue(lfo.inputPorts.contains { $0.key == "patchTime" })
        XCTAssertFalse(NumberPatch().allInputs.contains { $0.key == "timeBase" }, "only time-based patches get a time base")
    }

    func testEvaluatorAppliesTimeBase() throws {
        let resources = try RenderResources(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        func run(_ g: Graph, _ node: Patch, at t: Double) -> Double {
            let ctx = EvalContext(resources: resources, commandBuffer: resources.queue.makeCommandBuffer()!, time: t,
                                  deltaTime: 1.0 / 60, viewportSize: CGSize(width: 8, height: 8), mouse: .zero, mouseDown: false)
            return Evaluator(graph: g, context: ctx).outputs(of: node)["value"]!.number
        }
        let g = Graph()
        // LFO: offset 0.5 + 0.5 · sin(2π t), period 1.
        let external = g.put(LFOPatch.self, 0, 0, ["timeBase": .number(2), "patchTime": .number(0.25)])
        XCTAssertEqual(run(g, external, at: 10), 1, accuracy: 1e-9, "External ignores the viewer clock")
        let local = g.put(LFOPatch.self, 0, 0, ["timeBase": .number(1)])
        XCTAssertEqual(run(g, local, at: 5), 0.5, accuracy: 1e-9, "Local starts at 0")
        XCTAssertEqual(run(g, local, at: 5.25), 1, accuracy: 1e-9)
        local.restart()
        XCTAssertEqual(run(g, local, at: 7), 0.5, accuracy: 1e-9, "restart resets local time")
    }
}

final class IntegratorTests: XCTestCase {
    func testIntegratesOverTimeResetsAndRewinds() throws {
        let resources = try RenderResources(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let g = Graph()
        let integrator = g.put(IntegratorPatch.self, 0, 0, ["value": .number(2)])
        func step(time: Double, dt: Double) -> Double {
            let ctx = EvalContext(resources: resources, commandBuffer: resources.queue.makeCommandBuffer()!, time: time,
                                  deltaTime: dt, viewportSize: CGSize(width: 8, height: 8), mouse: .zero, mouseDown: false)
            return Evaluator(graph: g, context: ctx).outputs(of: integrator)["integral"]!.number
        }
        var out = 0.0
        for f in 1...60 { out = step(time: Double(f) / 60, dt: 1.0 / 60) }
        XCTAssertEqual(out, 2, accuracy: 1e-9, "2 per second for 1 second")
        XCTAssertEqual(step(time: 1, dt: 0), 2, accuracy: 1e-9, "paused: unchanged")

        integrator.params["reset"] = .bool(true)
        XCTAssertEqual(step(time: 1.1, dt: 0.1), 0)
        integrator.params["reset"] = .bool(false)

        // External time base: going back in time takes the amount back out.
        integrator.params["timeBase"] = .number(2)
        integrator.params["patchTime"] = .number(0)
        _ = step(time: 0, dt: 0)                 // first External frame: no elapsed time yet
        integrator.params["patchTime"] = .number(1.5)
        XCTAssertEqual(step(time: 0, dt: 0), 3, accuracy: 1e-9)
        integrator.params["patchTime"] = .number(1)
        XCTAssertEqual(step(time: 0, dt: 0), 2, accuracy: 1e-9)
    }
}
