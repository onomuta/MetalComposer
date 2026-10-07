#if !os(macOS)
import Combine
import SwiftUI
import UniformTypeIdentifiers
import MetalComposerKit

/// The whole editor (library, graph, viewer, inspector) for an iPad app: opens `url`, or a new
/// composition when it is nil. Changes are saved automatically; new compositions go to the app's
/// Documents folder (Files › On My iPad). The title renames the file, and its menu duplicates,
/// saves elsewhere, shares it or exports a movie; ‹ closes it. `onClose` gets the file the composition ended up in.
public struct EditorScreen: View {
    private let url: URL?
    private let demo: String?
    private let onClose: (URL?) -> Void
    @StateObject private var session = EditorSession()
    @Environment(\.scenePhase) private var scenePhase
    @State private var savingAs = false

    /// `demoNamed` (one of `CompositionPlayer.demoNames`) starts from a built-in demo instead of a
    /// file; it is saved as a new composition named after the demo once it is changed.
    public init(url: URL?, demoNamed demo: String? = nil, onClose: @escaping (URL?) -> Void) {
        self.url = url
        self.demo = demo
        self.onClose = onClose
    }

    public var body: some View {
        let state = session.state
        NavigationStack {
            ContentView(state: state, composition: state.composition)
                .navigationTitle(Binding(get: { session.title }, set: { session.rename(to: $0) }))
                .navigationBarTitleDisplayMode(.inline)
                .toolbarRole(.editor)
                .toolbarTitleMenu {
                    RenameButton()
                    Button { session.duplicate() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    Button { savingAs = true } label: { Label("Save As…", systemImage: "folder") }
                    if let url = state.composition.fileURL {
                        ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
                    }
                    Divider()
                    Button { state.showExport = true } label: { Label("Export Movie…", systemImage: "film") }
                }
                // The editor role's ‹ button closes the editor, like a document app's.
                .modifier(EditCommands(state: state))
                .background {
                    Button("Save") { session.save() }.keyboardShortcut("s").hidden()
                }
                .fileExporter(isPresented: $savingAs, document: CompositionFile(data: session.currentData() ?? Data()),
                              contentType: .metalComposition, defaultFilename: session.title) { result in
                    if case .success(let url) = result { session.adopt(url) }
                }
        }
        .onAppear { session.load(url, demo: demo) }
        // However the editor is closed: save, give back file access, report the file.
        .onDisappear { onClose(session.close()) }
        // Save before the app may be suspended or closed.
        .onChange(of: scenePhase) { _, phase in if phase != .active { session.save() } }
    }
}

/// The editor's link to its file: access to it, saving (automatically, a moment after each
/// change), renaming and copying.
final class EditorSession: ObservableObject {
    let state = AppState()
    /// What the file holds, to skip saving when nothing changed.
    private var savedData: Data?
    /// A file from outside the app's folder, readable and writable only while access is held.
    private var accessing: URL?
    private var subscriptions: Set<AnyCancellable> = []
    /// What a new composition is called when it is first saved.
    private var newName = "Untitled"

    private var composition: Composition { state.composition }

    init() {
        composition.$fileURL.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        composition.objectWillChange
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] in self?.save() }
            .store(in: &subscriptions)
    }

    var title: String { composition.fileURL?.deletingPathExtension().lastPathComponent ?? newName }

    func load(_ url: URL?, demo: String? = nil) {
        if let url {
            access(url)
            state.open(url)
        } else if let demo = demo.flatMap(Demo.init(rawValue:)) {
            state.loadDemo(demo)
            newName = demo.rawValue
        } else {
            state.newComposition()
        }
        // A new composition gets a file only once it is changed.
        savedData = currentData()
    }

    func currentData() -> Data? { try? composition.encoded() }

    /// Writes the composition if it changed since the last save; a new one goes to Documents.
    func save() {
        guard let data = currentData(), data != savedData else { return }
        guard let url = composition.fileURL ?? Self.unusedURL(named: newName) else { return }
        if state.write(to: url) { savedData = data }
    }

    /// Saves, gives back file access, and returns where the composition is.
    func close() -> URL? {
        save()
        accessing?.stopAccessingSecurityScopedResource()
        accessing = nil
        return composition.fileURL
    }

    /// Renames the file in place (a new composition is saved under the name).
    func rename(to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard !name.isEmpty, name != title else { return }
        guard let url = composition.fileURL else {
            guard let target = Self.unusedURL(named: name), let data = currentData() else { return }
            if state.write(to: target) { savedData = data }
            return
        }
        let target = url.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension("mcomp")
        guard !FileManager.default.fileExists(atPath: target.path) else {
            state.show(AppAlert(title: "“\(name)” already exists", message: "Choose a different name."))
            return
        }
        save()
        // Coordinated, so the Files app and file providers (iCloud Drive…) see the move.
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var moveError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forMoving, writingItemAt: target, options: .forReplacing,
                               error: &coordinationError) { from, to in
            do {
                coordinator.item(at: from, willMoveTo: to)
                try FileManager.default.moveItem(at: from, to: to)
                coordinator.item(at: from, didMoveTo: to)
            } catch {
                moveError = error
            }
        }
        if let error = moveError ?? coordinationError {
            state.show(AppAlert(error))
            return
        }
        composition.fileURL = target
    }

    /// Copies the composition next to its file (or into Documents) as "… copy" and edits the copy.
    func duplicate() {
        save()
        let folder = composition.fileURL?.deletingLastPathComponent() ?? Self.documents
        guard let folder, let data = currentData(),
              let target = Self.unusedURL(named: "\(title) copy", in: folder) else { return }
        if state.write(to: target) { savedData = data }
    }

    /// Continues with a file the composition was just saved to elsewhere (Save As…).
    func adopt(_ url: URL) {
        accessing?.stopAccessingSecurityScopedResource()
        accessing = nil
        access(url)
        composition.fileURL = url
        savedData = currentData()
    }

    private func access(_ url: URL) {
        if url.startAccessingSecurityScopedResource() { accessing = url }
    }

    private static var documents: URL? { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first }

    /// "`name`.mcomp" in `folder`, or "`name` 2.mcomp" and so on when that exists.
    private static func unusedURL(named name: String, in folder: URL? = documents) -> URL? {
        guard let folder else { return nil }
        var n = 1
        while true {
            let url = folder.appendingPathComponent(n == 1 ? name : "\(name) \(n)").appendingPathExtension("mcomp")
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }
}

/// The composition's bytes, for the Save As… file exporter.
private struct CompositionFile: FileDocument {
    static let readableContentTypes: [UTType] = [.metalComposition]
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// The Mac's Edit and Patch menu shortcuts, for a hardware keyboard on iPad. Hold ⌘ to list them.
private struct EditCommands: ViewModifier {
    @ObservedObject var state: AppState

    func body(content: Content) -> some View {
        let c = state.composition
        content.background {
            Group {
                Button("Undo") { c.undo() }.keyboardShortcut("z")
                Button("Redo") { c.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
                Button("Cut") { c.perform(#selector(UIResponderStandardEditActions.cut(_:))) { c.cutSelection() } }
                    .keyboardShortcut("x")
                Button("Copy") { c.perform(#selector(UIResponderStandardEditActions.copy(_:))) { c.copySelection() } }
                    .keyboardShortcut("c")
                Button("Paste") { c.perform(#selector(UIResponderStandardEditActions.paste(_:))) { c.paste() } }
                    .keyboardShortcut("v")
                Button("Duplicate") { c.duplicateSelection() }.keyboardShortcut("d")
                Button("Delete") { c.perform(#selector(UIKeyInput.deleteBackward)) { c.deleteSelection() } }
                    .keyboardShortcut(.delete, modifiers: [])
                Button("Select All") { c.perform(#selector(UIResponderStandardEditActions.selectAll(_:))) { c.selectAll() } }
                    .keyboardShortcut("a")
                Button("Group into Macro") { c.groupSelectionIntoMacro() }.keyboardShortcut("g")
                Button("Find Patch") { state.findPatch() }.keyboardShortcut(.return, modifiers: .command)
                Button("Play / Pause") { state.playback.isPlaying.toggle() }.keyboardShortcut("p", modifiers: [.command, .option])
            }
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
#endif
