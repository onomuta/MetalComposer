import XCTest
import UniformTypeIdentifiers
@testable import MetalComposer

/// The `.mcomp` file path: what ⌘S writes, ⌘O must read back, and the Open panel must let through.
final class DocumentTests: XCTestCase {
    private func temporaryFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("Untitled.mcomp")
    }

    func testSavedCompositionLoadsBack() throws {
        let saved = Composition()
        saved.loadDemo(.feedback)
        let url = try temporaryFile()
        try saved.encoded().write(to: url, options: .atomic)

        let loaded = Composition()
        try loaded.load(Data(contentsOf: url), url: url)
        XCTAssertEqual(loaded.fileURL, url)
        XCTAssertEqual(loaded.root.nodes.map(\.typeID), saved.root.nodes.map(\.typeID))
        XCTAssertEqual(Set(loaded.root.connections), Set(saved.root.connections))
        for (a, b) in zip(saved.root.nodes, loaded.root.nodes) {
            XCTAssertEqual(a.params.keys.sorted(), b.params.keys.sorted(), a.title)
            XCTAssertEqual(a.subgraph?.nodes.count, b.subgraph?.nodes.count, a.title)
        }
        XCTAssertEqual(try loaded.encoded(), try saved.encoded()) // byte-identical on the second save
    }

    /// NSOpenPanel enables a file only if the type LaunchServices assigns it conforms to an allowed type.
    func testSavedFileConformsToCompositionType() throws {
        let url = try temporaryFile()
        try Composition().encoded().write(to: url, options: .atomic)
        let type = try XCTUnwrap(url.resourceValues(forKeys: [.contentTypeKey]).contentType)
        XCTAssertTrue(type.conforms(to: .metalComposition), "\(type.identifier) would be greyed out in the Open panel")
        XCTAssertEqual(UTType.metalComposition.preferredFilenameExtension, "mcomp")
    }
}
