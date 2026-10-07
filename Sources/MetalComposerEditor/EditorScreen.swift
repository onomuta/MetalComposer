#if !os(macOS)
import SwiftUI
import MetalComposerKit

/// The whole editor (library, graph, viewer, inspector) for an iPad app: opens `url`, or a new
/// composition when it is nil, and saves back to it. New compositions are saved in the app's
/// Documents folder. `onClose` gets the file the composition was saved to.
public struct EditorScreen: View {
    private let url: URL?
    private let onClose: (URL?) -> Void
    @StateObject private var state = AppState()
    @State private var accessing: URL?

    public init(url: URL?, onClose: @escaping (URL?) -> Void) {
        self.url = url
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack {
            ContentView(state: state, composition: state.composition)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            save()
                            onClose(state.composition.fileURL)
                        }
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { state.showExport = true } label: { Label("Export Movie", systemImage: "film") }
                        Button { save() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                            .keyboardShortcut("s")
                    }
                }
                .modifier(EditCommands(state: state))
        }
        .onAppear(perform: load)
        .onDisappear {
            accessing?.stopAccessingSecurityScopedResource()
            accessing = nil
        }
    }

    private func load() {
        guard let url else {
            state.newComposition()
            return
        }
        // Files from the picker or another app are only reachable while access is held, and
        // saving writes back to them, so keep it until the editor closes.
        if url.startAccessingSecurityScopedResource() { accessing = url }
        state.open(url)
    }

    private func save() {
        if let url = state.composition.fileURL {
            state.write(to: url)
        } else if let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            state.write(to: Self.unusedURL(in: folder))
        }
    }

    /// "Untitled.mcomp", or "Untitled 2.mcomp" and so on when that exists.
    private static func unusedURL(in folder: URL) -> URL {
        var n = 1
        while true {
            let name = n == 1 ? "Untitled.mcomp" : "Untitled \(n).mcomp"
            let url = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            n += 1
        }
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
