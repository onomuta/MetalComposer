#if os(macOS)
import XCTest
@testable import MetalComposerEditor

final class RecentFilesTests: XCTestCase {
    private var folder: URL!
    private var defaults: UserDefaults!
    private let suite = "RecentFilesTests-\(UUID().uuidString)"

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("recent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: suite)
        addTeardownBlock { [folder, suite] in
            try? FileManager.default.removeItem(at: folder!)
            UserDefaults().removePersistentDomain(forName: suite)
        }
    }

    private func file(_ name: String, in sub: String = "") throws -> URL {
        let dir = sub.isEmpty ? folder! : folder.appendingPathComponent(sub)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name + ".mcomp")
        try Data("{}".utf8).write(to: url)
        return url
    }

    func testNewestFirstWithoutDuplicatesAndLimited() throws {
        let recent = RecentFiles(defaults: defaults)
        let a = try file("a"), b = try file("b")
        recent.add(a); recent.add(b); recent.add(a)
        XCTAssertEqual(recent.items.map(\.name), ["a", "b"])
        for k in 0..<12 { recent.add(try file("f\(k)")) }
        XCTAssertEqual(recent.items.count, RecentFiles.limit)
        XCTAssertEqual(recent.items.first?.name, "f11")
    }

    func testKeptAcrossLaunchesAndReopened() throws {
        let a = try file("a")
        RecentFiles(defaults: defaults).add(a)
        let later = RecentFiles(defaults: defaults) // a relaunch
        let item = try XCTUnwrap(later.items.first)
        let url = try XCTUnwrap(later.resolve(item))
        defer { url.stopAccessingSecurityScopedResource() }
        XCTAssertEqual(url.standardizedFileURL.path, a.standardizedFileURL.path)
    }

    func testMissingFilesAndClearing() throws {
        let recent = RecentFiles(defaults: defaults)
        let gone = try file("gone")
        recent.add(gone)
        try FileManager.default.removeItem(at: gone)
        XCTAssertNil(recent.resolve(try XCTUnwrap(recent.items.first)))

        recent.add(try file("x"))
        recent.clear()
        XCTAssertTrue(recent.items.isEmpty)
        XCTAssertTrue(RecentFiles(defaults: defaults).items.isEmpty, "cleared for good")
    }

    func testSameNamesShowTheirFolders() throws {
        let recent = RecentFiles(defaults: defaults)
        recent.add(try file("show", in: "Friday"))
        recent.add(try file("show", in: "Saturday"))
        recent.add(try file("solo"))
        let shows = recent.items.filter { $0.name == "show" }
        XCTAssertEqual(shows.count, 2)
        XCTAssertTrue(shows.allSatisfy(recent.needsFolder))
        XCTAssertFalse(recent.needsFolder(recent.items.first { $0.name == "solo" }!))
        XCTAssertEqual(shows.map { URL(fileURLWithPath: $0.folder).lastPathComponent }, ["Saturday", "Friday"])
    }
}
#endif
