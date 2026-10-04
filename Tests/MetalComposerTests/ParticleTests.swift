import XCTest
@testable import MetalComposerKit
@testable import MetalComposerEditor

final class ParticleTests: XCTestCase {
    /// The shader reads `struct { float2 position; float z; float size; float alpha; }`: 24-byte stride.
    func testInstanceLayoutMatchesShader() {
        XCTAssertEqual(MemoryLayout<ParticleInstance>.stride, 24)
        XCTAssertEqual(MemoryLayout<ParticleInstance>.offset(of: \.z), 8)
        XCTAssertEqual(MemoryLayout<ParticleInstance>.offset(of: \.alpha), 16)
    }

    func testHasZPositionAndOldFilesDefaultToZero() throws {
        let keys = ParticleSystemPatch.inputSpecs.map(\.key)
        XCTAssertEqual(Array(keys.prefix(4)), ["enable", "x", "y", "z"])
        // A particle system saved before Z existed loads with z = 0.
        let json = #"{"nodes":[{"id":"6B0C2C3E-1F7E-4E0B-9E2B-2C1F5C4E8A11","type":"particle-system","x":0,"y":0,"params":{"x":{"t":"n","v":0.5}}}],"connections":[]}"#
        let g = Graph()
        g.load(try JSONDecoder().decode(GraphRecord.self, from: Data(json.utf8)))
        XCTAssertEqual(g.nodes.first?.params["z"]?.number, 0)
        XCTAssertEqual(g.nodes.first?.params["x"]?.number, 0.5)
    }
}
