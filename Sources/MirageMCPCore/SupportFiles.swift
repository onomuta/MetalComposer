import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Files shared with the Mirage MCP app (ADR 0002): its settings, which mirage-mcp reads before every
/// tool call, and the activity record, which mirage-mcp appends to and only the app trims.
package struct SupportFiles {
    package let folder: URL

    package init(folder: URL) {
        self.folder = folder
    }

    /// ~/Library/Application Support/Mirage MCP
    package static var standard: SupportFiles {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return SupportFiles(folder: base.appendingPathComponent("Mirage MCP", isDirectory: true))
    }

    package var settingsURL: URL { folder.appendingPathComponent("settings.json") }
    package var activityURL: URL { folder.appendingPathComponent("activity.jsonl") }
    package var thumbnailsFolder: URL { folder.appendingPathComponent("thumbnails", isDirectory: true) }

    /// mirage-mcp stops adding to the record past these (the app trims it); it never deletes.
    static let activityByteLimit = 10_000_000
    static let thumbnailLimit = 500

    // MARK: Settings

    package struct Settings: Codable, Equatable {
        /// Folders Image Importer may read from, besides the composition's folder.
        package var imageFolders: [String] = []
        /// While true, every tool call is refused.
        package var paused = false

        package init(imageFolders: [String] = [], paused: Bool = false) {
            self.imageFolders = imageFolders
            self.paused = paused
        }
    }

    /// The settings, or why they couldn't be read. A missing file means the defaults (running,
    /// no extra folders); a file that exists but can't be read means paused, to fail safe.
    package func loadSettings() -> (settings: Settings, problem: String?) {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return (Settings(), nil) }
        do {
            return (try JSONDecoder().decode(Settings.self, from: Data(contentsOf: settingsURL)), nil)
        } catch {
            return (Settings(paused: true), "The Mirage MCP settings can't be read (\(settingsURL.path)), so AI access is paused. Fix or delete the file, or change a setting in the Mirage MCP app.")
        }
    }

    // MARK: Activity

    /// One tool call, as a line of activity.jsonl.
    package struct Entry: Codable, Equatable {
        package var time: Date
        package var process: Int32
        package var tool: String
        /// Arguments with long values shortened.
        package var arguments: String
        package var ok: Bool
        /// The error, or a short summary of the result.
        package var message: String
        /// File names in `thumbnails` (renders).
        package var thumbnails: [String]
        /// A saved composition.
        package var saved: String?
    }

    /// Appends an entry, if the app's folder exists (no app, no record) and the record isn't full.
    func record(_ entry: Entry) {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: activityURL.path)[.size] as? Int) ?? 0
        guard size < Self.activityByteLimit else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        // One write per line, appended: lines from several mirage-mcp processes don't mix.
        let fd = open(activityURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// Writes a small copy of a rendered PNG for the record. Returns its file name, or nil when
    /// there is no app folder or the folder is full.
    func thumbnail(of png: Data) -> String? {
        guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
        let fm = FileManager.default
        // Renders can show images from allowed folders: only the user may open the folder.
        try? fm.createDirectory(at: thumbnailsFolder, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        guard ((try? fm.contentsOfDirectory(atPath: thumbnailsFolder.path))?.count ?? 0) < Self.thumbnailLimit,
              let source = CGImageSourceCreateWithData(png as CFData, nil),
              let small = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 240,
              ] as CFDictionary) else { return nil }
        let name = UUID().uuidString + ".png"
        guard let dest = CGImageDestinationCreateWithURL(thumbnailsFolder.appendingPathComponent(name) as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, small, nil)
        return CGImageDestinationFinalize(dest) ? name : nil
    }

    // MARK: For the app

    /// Saves the settings (only the user can read them). mirage-mcp picks them up on its next call.
    package func saveSettings(_ settings: Settings) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(settings).write(to: settingsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
    }

    /// The recorded calls, oldest first. Lines that can't be read are skipped.
    package func loadEntries() -> [Entry] {
        guard let text = try? String(contentsOf: activityURL, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(Entry.self, from: Data($0.utf8)) }
    }

    /// Keeps the newest `keep` entries and the thumbnails they use; deletes the rest. A call recorded
    /// by mirage-mcp while this runs can be lost (the record is a convenience, not an audit log).
    package func trimActivity(keep: Int = 1000) {
        let entries = loadEntries()
        let kept = Array(entries.suffix(keep))
        if kept.count < entries.count {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = Data()
            for entry in kept {
                guard let line = try? encoder.encode(entry) else { continue }
                data.append(line)
                data.append(0x0A)
            }
            try? data.write(to: activityURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: activityURL.path)
        }
        let used = Set(kept.flatMap(\.thumbnails))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: thumbnailsFolder.path)) ?? [] where !used.contains(name) {
            try? FileManager.default.removeItem(at: thumbnailsFolder.appendingPathComponent(name))
        }
    }

    /// Deletes the whole record and its thumbnails.
    package func clearActivity() {
        try? FileManager.default.removeItem(at: activityURL)
        try? FileManager.default.removeItem(at: thumbnailsFolder)
    }

    /// Arguments for the record: compact JSON, long strings shortened, the whole capped.
    static func summarize(_ arguments: [String: Any]) -> String {
        func shorten(_ value: Any) -> Any {
            switch value {
            case let s as String: return s.count > 120 ? String(s.prefix(100)) + "…(\(s.count) characters)" : s
            case let a as [Any]: return a.prefix(20).map(shorten) + (a.count > 20 ? ["…(\(a.count) items)"] : [])
            case let d as [String: Any]: return d.mapValues(shorten)
            default: return value
            }
        }
        let data = (try? JSONSerialization.data(withJSONObject: shorten(arguments), options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        return text.count > 600 ? String(text.prefix(600)) + "…" : text
    }
}
