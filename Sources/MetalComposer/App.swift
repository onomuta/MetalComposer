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
    @Published var showExport = false
    /// The viewer lives in its own window. Only one viewer renders at a time: rendering twice per
    /// frame would advance time and stateful patches (particles, queues…) twice as fast.
    @Published var viewerPoppedOut = false
    /// Bumped each time the viewer moves, so it gets a fresh Metal view instead of a reused one.
    @Published var viewerGeneration = 0
    let exporter = MovieExporter()
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
        playback.onRestart = { [composition] in composition.root.nodes.forEach { $0.restart() } }
        composition.loadDemo(.basics)
        installDeleteKey()
        exporter.onBusyChange = { [renderer] busy in renderer.isSuspended = busy }
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

    /// Asks where to save, then renders the composition to a movie with the sheet's settings.
    func exportMovie() {
        let codec = exporter.settings.codec
        let panel = NSSavePanel()
        panel.allowedContentTypes = [codec.fileType == .mp4 ? .mpeg4Movie : .quickTimeMovie]
        let name = composition.fileURL?.deletingPathExtension().lastPathComponent ?? "Metal Composer"
        panel.nameFieldStringValue = "\(name).\(codec.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporter.start(record: composition.root.record(), resources: renderer.resources, to: url)
    }

    /// ⌘↩ toggles: opens the patch library with the cursor in its search field, or closes it
    /// (handing the keyboard back to the graph) when it is already open.
    func findPatch() {
        if showLibrary {
            showLibrary = false
            NSApp.keyWindow?.makeFirstResponder(nil)
        } else {
            showLibrary = true
            librarySearchRequest += 1
        }
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

        Window("Viewer", id: "viewer") {
            ViewerWindow(state: state)
        }
        .defaultSize(width: 960, height: 540)
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
                Divider()
                Button("Export Movie…") { state.showExport = true }.keyboardShortcut("e", modifiers: [.command, .shift])
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
    @Environment(\.openWindow) private var openWindow

    // Fixed column widths (remembered between launches); only the editor flexes, so showing or
    // hiding the library never changes the right column.
    @AppStorage("libraryWidth") private var libraryWidth = 220.0
    @AppStorage("rightColumnWidth") private var rightColumnWidth = 460.0
    private static let editorMinWidth = 320.0

    var body: some View {
        GeometryReader { geo in
            let libraryShown = state.showLibrary
            let usedByLibrary = libraryShown ? libraryWidth + ColumnResizeHandle.width : 0
            // Shrink the right column only when the window is too narrow to fit it.
            let rightWidth = min(rightColumnWidth,
                                 max(300, geo.size.width - usedByLibrary - ColumnResizeHandle.width - Self.editorMinWidth))
            HStack(spacing: 0) {
                if libraryShown {
                    LibraryView(composition: composition, searchRequest: state.librarySearchRequest,
                                onAddedFromSearch: { state.showLibrary = false })
                        .frame(width: libraryWidth)
                    ColumnResizeHandle(width: $libraryWidth, range: 180...420)
                }
                GraphEditorView(composition: composition)
                    .frame(minWidth: Self.editorMinWidth, maxWidth: .infinity)
                ColumnResizeHandle(width: $rightColumnWidth, range: 300...900, growsLeftward: true)
                VSplitView {
                    if state.viewerPoppedOut {
                        PoppedOutViewerBar()
                    } else {
                        ViewerPanel(renderer: state.renderer, playback: state.playback) {
                            state.viewerPoppedOut = true
                            openWindow(id: "viewer")
                        }
                        .frame(minHeight: 240, idealHeight: 380)
                    }
                    InspectorView(composition: composition)
                        .frame(minHeight: 200)
                }
                .frame(width: rightWidth)
            }
        }
        .navigationTitle(composition.fileURL?.deletingPathExtension().lastPathComponent ?? "Metal Composer")
        .sheet(isPresented: $state.showExport) {
            ExportMovieView(exporter: state.exporter) { state.exportMovie() }
                .interactiveDismissDisabled(state.exporter.isExporting)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { state.showLibrary.toggle() } label: { Image(systemName: "sidebar.left") }
                    .help(state.showLibrary ? "Hide Patch Library (⌥⌘L)" : "Show Patch Library (⌥⌘L)")
            }
        }
    }
}

/// The viewer in its own resizable window (use the green button or ⌃⌘F for full screen).
private struct ViewerWindow: View {
    @ObservedObject var state: AppState
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ViewerPanel(renderer: state.renderer, playback: state.playback, isPoppedOut: true) {
            dismissWindow(id: "viewer")
        }
        .id(state.viewerGeneration)
        .frame(minWidth: 320, minHeight: 200)
        .onAppear {
            state.viewerPoppedOut = true
            state.viewerGeneration += 1
        }
        .onDisappear {
            state.viewerPoppedOut = false
            state.viewerGeneration += 1
        }
    }
}

/// Stands in for the viewer in the main window while it is popped out.
private struct PoppedOutViewerBar: View {
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        HStack {
            Image(systemName: "macwindow").foregroundStyle(.secondary)
            Text("The viewer is in its own window.").foregroundStyle(.secondary)
            Spacer()
            Button("Bring Back") { dismissWindow(id: "viewer") }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxHeight: 40)
    }
}

private struct LibraryCommands: View {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Button(state.viewerPoppedOut ? "Bring Back Viewer" : "Pop Out Viewer") {
            if state.viewerPoppedOut {
                dismissWindow(id: "viewer")
            } else {
                state.viewerPoppedOut = true
                openWindow(id: "viewer")
            }
        }
        .keyboardShortcut("v", modifiers: [.command, .option])
        Button(state.showLibrary ? "Hide Patch Library" : "Show Patch Library") { state.showLibrary.toggle() }
            .keyboardShortcut("l", modifiers: [.command, .option])
        Button(state.showLibrary ? "Close Patch Library" : "Find Patch…") { state.findPatch() }
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

/// A column divider that resizes the column on one side by dragging.
private struct ColumnResizeHandle: View {
    static let width: CGFloat = 7

    @Binding var width: Double
    var range: ClosedRange<Double>
    /// True when the column is to the right of the handle (dragging left makes it wider).
    var growsLeftward = false

    @State private var dragStart: Double?

    var body: some View {
        ZStack {
            Color.clear
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
        }
        .frame(width: Self.width)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            // Global coordinates: the handle itself moves while dragging.
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { g in
                    let start = dragStart ?? width
                    dragStart = start
                    let delta = growsLeftward ? -g.translation.width : g.translation.width
                    width = min(max(start + delta, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in dragStart = nil }
        )
    }
}
