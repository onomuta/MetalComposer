import Metal
import MetalComposerEditor
import MetalComposerKit
import SwiftUI
import UniformTypeIdentifiers

/// The app's translation of `key` from Localizable.strings, formatted with `arguments`.
func loc(_ key: String, _ arguments: CVarArg...) -> String {
    let format = NSLocalizedString(key, comment: "")
    return arguments.isEmpty ? format : String(format: format, arguments: arguments)
}

extension UTType {
    static let metalComposition = UTType("dev.metalcomposer.composition") ?? .json
}

/// GPU state shared by every composition the app plays.
enum Engine {
    static let shared: MetalComposerEngine? = MTLCreateSystemDefaultDevice().flatMap { try? MetalComposerEngine(device: $0) }
    /// One queue for every view, so the GPU runs their frames in the order they were drawn.
    static let queue: MTLCommandQueue? = shared?.device.makeCommandQueue()
}

@main
struct PlayerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = Library()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(library)
                // Files, AirDrop and "Open in…" hand .mcomp files to the app here.
                .onOpenURL { library.open($0) }
                // Compiling the built-in shaders takes a moment; do it before the first demo is opened.
                .task { await Task.detached(priority: .userInitiated) { _ = Engine.shared }.value }
        }
    }
}

/// What to play: a built-in demo or a file.
enum Source: Hashable {
    case demo(String)
    case file(URL)

    var title: String {
        switch self {
        case .demo(let name): return name
        case .file(let url): return url.deletingPathExtension().lastPathComponent
        }
    }
}

/// Recently opened files (kept as bookmarks, so they reopen without the file picker) and the
/// composition being played.
final class Library: ObservableObject {
    @Published var playing: PlayingComposition?
    /// The composition open in the editor (iPad).
    @Published var editing: EditingComposition?
    /// Opened once the player has gone (two full-screen covers can't change places at once).
    var editAfterPlaying: EditingComposition?
    @Published var recents: [URL] = []
    @Published var error: String?

    private static let recentsKey = "recentBookmarks"
    private static let maxRecents = 20

    init() {
        let bookmarks = (UserDefaults.standard.array(forKey: Self.recentsKey) as? [Data]) ?? []
        recents = bookmarks.compactMap { data in
            var stale = false
            return try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
        }
    }

    func play(_ source: Source) {
        guard let engine = Engine.shared else {
            error = loc("This device doesn't support Metal.")
            return
        }
        do {
            switch source {
            case .demo(let name):
                guard let player = CompositionPlayer(engine: engine, demoNamed: name) else { return }
                playing = PlayingComposition(player: player, source: source)
            case .file(let url):
                // Files from the picker or another app are only readable while access is held,
                // and images next to the file are read while playing, so keep it until closed.
                let scoped = url.startAccessingSecurityScopedResource()
                do {
                    let player = try CompositionPlayer(engine: engine, contentsOf: url)
                    playing = PlayingComposition(player: player, source: source) {
                        if scoped { url.stopAccessingSecurityScopedResource() }
                    }
                } catch {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    throw error
                }
                remember(url)
            }
        } catch {
            self.error = loc("Couldn't open %@: %@", source.title, error.localizedDescription)
        }
    }

    func open(_ url: URL) {
        playing = nil
        play(.file(url))
    }

    /// Opens the editor on a file, or on a new composition.
    func edit(_ url: URL?) {
        playing = nil
        guard canEdit else { return }
        editing = EditingComposition(url: url)
    }

    /// The editor needs Metal; say so rather than open it without.
    private var canEdit: Bool {
        if Engine.shared != nil { return true }
        error = loc("This device doesn't support Metal.")
        return false
    }

    /// From the player: closes it, then opens what it was playing in the editor.
    func editPlaying() {
        guard let source = playing?.source, canEdit else { return }
        switch source {
        case .demo(let name): editAfterPlaying = EditingComposition(url: nil, demo: name)
        case .file(let url): editAfterPlaying = EditingComposition(url: url)
        }
        playing = nil
    }

    func playerDismissed() {
        if let next = editAfterPlaying {
            editAfterPlaying = nil
            editing = next
        }
    }

    func forget(_ url: URL) {
        recents.removeAll { $0 == url }
        save()
    }

    func remember(_ url: URL) {
        recents.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        recents.insert(url, at: 0)
        recents = Array(recents.prefix(Self.maxRecents))
        save()
    }

    private func save() {
        let bookmarks = recents.compactMap { try? $0.bookmarkData() }
        UserDefaults.standard.set(bookmarks, forKey: Self.recentsKey)
    }
}

/// A composition open in the editor: a file, a copy of a demo, or (neither) a new one.
struct EditingComposition: Identifiable {
    let id = UUID()
    let url: URL?
    var demo: String?
}

/// A composition on screen. `onClose` gives back resources held while it plays.
final class PlayingComposition: Identifiable {
    let id = UUID()
    let player: CompositionPlayer
    let source: Source
    var title: String { source.title }
    private let onClose: () -> Void

    init(player: CompositionPlayer, source: Source, onClose: @escaping () -> Void = {}) {
        self.player = player
        self.source = source
        self.onClose = onClose
    }

    deinit { onClose() }
}

struct HomeView: View {
    @EnvironmentObject private var library: Library
    @ObservedObject private var external = ExternalDisplay.shared
    @State private var picking = false

    var body: some View {
        NavigationStack {
            List {
                if let size = external.size {
                    Section {
                        Label(loc("External display connected (%ld×%ld). Compositions play on it.", Int(size.width), Int(size.height)),
                              systemImage: "tv")
                    }
                }
                Section("Demos") {
                    ForEach(CompositionPlayer.demoNames, id: \.self) { name in
                        Button { library.play(.demo(name)) } label: {
                            Label(name, systemImage: "play.rectangle")
                        }
                    }
                }
                if !library.recents.isEmpty {
                    Section("Recent") {
                        ForEach(library.recents, id: \.self) { url in
                            Button { library.play(.file(url)) } label: {
                                Label(Source.file(url).title, systemImage: "doc")
                            }
                            .contextMenu {
                                Button { library.play(.file(url)) } label: { Label("Play", systemImage: "play") }
                                Button { library.edit(url) } label: { Label("Edit", systemImage: "square.and.pencil") }
                            }
                            .swipeActions(edge: .leading) {
                                Button { library.edit(url) } label: { Label("Edit", systemImage: "square.and.pencil") }
                                    .tint(.orange)
                            }
                        }
                        .onDelete { $0.map { library.recents[$0] }.forEach(library.forget) }
                    }
                }
            }
            .navigationTitle("Mirage Composer")
            .toolbar {
                Button { library.edit(nil) } label: { Label("New Composition", systemImage: "plus") }
                Button { picking = true } label: { Label("Open", systemImage: "folder") }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.metalComposition]) { result in
                if case .success(let url) = result { library.play(.file(url)) }
            }
            .alert("Couldn't Play", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
                Button("OK") {}
            } message: {
                Text(library.error ?? "")
            }
        }
        .fullScreenCover(item: $library.playing, onDismiss: library.playerDismissed) { PlayerView(composition: $0) }
        .fullScreenCover(item: $library.editing) { editing in
            EditorScreen(url: editing.url, demoNamed: editing.demo) { saved in
                library.editing = nil
                // Renamed or saved elsewhere: the old entry would point at nothing.
                if let old = editing.url, old != saved { library.forget(old) }
                saved.map(library.remember)
            }
        }
    }
}
