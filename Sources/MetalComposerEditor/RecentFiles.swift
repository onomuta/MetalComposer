#if os(macOS)
import AppKit

/// The compositions opened or saved most recently, for File › Open Recent.
///
/// Each file is kept as a security-scoped bookmark, so the sandboxed Mac App Store build can open
/// (and save) it again after a relaunch without asking the user to choose it.
final class RecentFiles: ObservableObject {
    static let limit = 10
    private static let defaultsKey = "recentCompositions"

    struct Item: Codable, Equatable, Identifiable {
        var path: String
        var bookmark: Data
        var id: String { path }
        var name: String { URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
        /// The folder, shown when two files have the same name.
        var folder: String { (URL(fileURLWithPath: path).deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath }
    }

    @Published private(set) var items: [Item] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved
        }
    }

    /// Puts `url` first (after it was opened or saved). Also tells macOS, for the Dock's list.
    func add(_ url: URL) {
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                                   relativeTo: nil) else { return }
        let item = Item(path: url.standardizedFileURL.path, bookmark: bookmark)
        items.removeAll { $0.path == item.path }
        items.insert(item, at: 0)
        items = Array(items.prefix(Self.limit))
        save()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    func remove(_ item: Item) {
        items.removeAll { $0 == item }
        save()
    }

    func clear() {
        items = []
        save()
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    /// The file, with sandbox access started (the caller stops it when done). Nil when the file is
    /// gone or its bookmark no longer resolves.
    func resolve(_ item: Item) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: item.bookmark, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        guard FileManager.default.fileExists(atPath: url.path) else {
            url.stopAccessingSecurityScopedResource()
            return nil
        }
        if stale { add(url) } // renew the bookmark (the file moved or was replaced)
        return url
    }

    /// Two items with the same name show their folders too.
    func needsFolder(_ item: Item) -> Bool {
        items.filter { $0.name == item.name }.count > 1
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(items), forKey: Self.defaultsKey)
    }
}
#endif
