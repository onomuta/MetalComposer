import AppKit
import Metal
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let metalComposition = UTType(filenameExtension: "mcomp", conformingTo: .json) ?? .json
}

final class AppState: ObservableObject {
    let composition = Composition()
    let playback = Playback()
    let renderer: Renderer
    @Published var showLibrary = true
    /// Incremented to ask the library to focus its search field.
    @Published var librarySearchRequest = 0
    private var keyMonitor: Any?

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal is not supported on this Mac") }
        do {
            let resources = try RenderResources(device: device)
            renderer = Renderer(resources: resources, composition: composition, playback: playback)
        } catch {
            fatalError("Failed to build Metal pipelines: \(error)")
        }
        playback.onRestart = { [composition] in composition.root.nodes.forEach { $0.reset() } }
        composition.loadDemo(.basics)
        installDeleteKey()
    }

    /// Delete / Forward Delete remove the selected patches unless text is being edited.
    /// Handled here rather than as a menu shortcut so it never steals Backspace from text input
    /// (including Japanese IME composition).
    private func installDeleteKey() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 51 || event.keyCode == 117,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  let window = NSApp.keyWindow, window === NSApp.mainWindow, window.attachedSheet == nil,
                  !Composition.isEditingText, !self.composition.selection.isEmpty else { return event }
            self.composition.deleteSelection()
            return nil
        }
    }

    /// ⌘↩: show the patch library and put the cursor in its search field.
    func findPatch() {
        showLibrary = true
        librarySearchRequest += 1
    }

    func newComposition() {
        let g = Graph()
        g.put(ClearPatch.self, 400, 80)
        composition.replaceDocument(with: g.record(), url: nil)
        playback.restart()
    }

    func loadDemo(_ demo: Demo) {
        composition.loadDemo(demo)
        playback.restart()
    }

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.metalComposition, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try composition.load(Data(contentsOf: url), url: url)
            playback.restart()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func save(as: Bool = false) {
        var url = composition.fileURL
        if url == nil || `as` {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.metalComposition]
            panel.nameFieldStringValue = "Untitled.mcomp"
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        }
        guard let url else { return }
        do {
            try composition.encoded().write(to: url, options: .atomic)
            composition.fileURL = url
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable (no .app bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct MetalComposerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("Metal Composer", id: "main") {
            ContentView(state: state, composition: state.composition)
                .frame(minWidth: 1100, minHeight: 680)
        }
        .defaultSize(width: 1500, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Composition") { state.newComposition() }.keyboardShortcut("n")
                Button("Open…") { state.open() }.keyboardShortcut("o")
                Divider()
                Menu("Demos") {
                    ForEach(Demo.allCases) { demo in
                        Button(demo.rawValue) { state.loadDemo(demo) }
                    }
                }
            }
            CommandGroup(replacing: .undoRedo) {
                UndoCommands(composition: state.composition)
            }
            CommandGroup(replacing: .pasteboard) {
                let c = state.composition
                Button("Cut") { c.perform(#selector(NSText.cut(_:))) { c.cutSelection() } }.keyboardShortcut("x")
                Button("Copy") { c.perform(#selector(NSText.copy(_:))) { c.copySelection() } }.keyboardShortcut("c")
                Button("Paste") { c.perform(#selector(NSText.paste(_:))) { c.paste() } }.keyboardShortcut("v")
                Button("Duplicate") { c.duplicateSelection() }.keyboardShortcut("d")
                Button("Delete") { c.perform(#selector(NSText.delete(_:))) { c.deleteSelection() } }
                Button("Select All") { c.perform(#selector(NSText.selectAll(_:))) { c.selectAll() } }.keyboardShortcut("a")
            }
            CommandGroup(before: .toolbar) {
                LibraryCommands(state: state)
                Divider()
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { state.save() }.keyboardShortcut("s")
                Button("Save As…") { state.save(as: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandMenu("Patch") {
                Button("Group into Macro") { state.composition.groupSelectionIntoMacro() }.keyboardShortcut("g")
                Button("Explode Macro") {
                    if let node = state.composition.singleSelection { state.composition.explodeMacro(node) }
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Add Comment") { state.composition.addComment(at: state.composition.visibleCenter) }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                Divider()
                Button("Open Macro") {
                    if let node = state.composition.singleSelection { state.composition.enter(node) }
                }
                .keyboardShortcut(.downArrow, modifiers: .command)
                Button("Close Macro") {
                    let c = state.composition
                    if !c.path.isEmpty { c.exit(toDepth: c.path.count - 1) }
                }
                .keyboardShortcut(.upArrow, modifiers: .command)
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var state: AppState
    @ObservedObject var composition: Composition

    var body: some View {
        HSplitView {
            if state.showLibrary {
                LibraryView(composition: composition, searchRequest: state.librarySearchRequest)
                    .frame(minWidth: 190, idealWidth: 220, maxWidth: 300)
            }
            GraphEditorView(composition: composition)
                .frame(minWidth: 420)
            VSplitView {
                ViewerPanel(renderer: state.renderer, playback: state.playback)
                    .frame(minHeight: 240, idealHeight: 380)
                InspectorView(composition: composition)
                    .frame(minHeight: 200)
            }
            .frame(minWidth: 340, idealWidth: 460, maxWidth: 800)
        }
        .navigationTitle(composition.fileURL?.deletingPathExtension().lastPathComponent ?? "Metal Composer")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { state.showLibrary.toggle() } label: { Image(systemName: "sidebar.left") }
                    .help(state.showLibrary ? "Hide Patch Library (⌥⌘L)" : "Show Patch Library (⌥⌘L)")
            }
        }
    }
}

private struct LibraryCommands: View {
    @ObservedObject var state: AppState

    var body: some View {
        Button(state.showLibrary ? "Hide Patch Library" : "Show Patch Library") { state.showLibrary.toggle() }
            .keyboardShortcut("l", modifiers: [.command, .option])
        Button("Find Patch…") { state.findPatch() }
            .keyboardShortcut(.return, modifiers: .command)
    }
}

private struct UndoCommands: View {
    @ObservedObject var composition: Composition

    var body: some View {
        let um = composition.undoManager
        Button(um.canUndo ? "Undo \(um.undoActionName)" : "Undo") { composition.undo() }
            .keyboardShortcut("z")
        Button(um.canRedo ? "Redo \(um.redoActionName)" : "Redo") { composition.redo() }
            .keyboardShortcut("z", modifiers: [.command, .shift])
    }
}
