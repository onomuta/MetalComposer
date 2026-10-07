#if os(macOS)
import AppKit
import SwiftUI
import MetalComposerKit

extension AppState {
    /// Delete / Forward Delete remove the selected patches unless text is being edited.
    /// Handled here rather than as a menu shortcut so it never steals Backspace from text input
    /// (including Japanese IME composition).
    func installDeleteKey() {
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

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.metalComposition, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
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
        write(to: url)
    }
}

extension Notification.Name {
    static let restartViewerDisplayLink = Notification.Name("MetalComposer.restartViewerDisplayLink")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppAppearance.current.apply()
        // Needed when launched as a bare SwiftPM executable (no .app bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Files opened from Finder or dropped on the Dock icon. They can arrive before the window
    /// (and the app state) exists, so they wait until `openHandler` is set.
    var openHandler: ((URL) -> Void)? {
        didSet {
            guard let openHandler else { return }
            pendingURLs.forEach(openHandler)
            pendingURLs = []
        }
    }
    private var pendingURLs: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        // One document at a time: the last file wins.
        guard let url = urls.last else { return }
        if let openHandler { openHandler(url) } else { pendingURLs = [url] }
        // An open event stops the viewer's display link (the view isn't paused, it just stops
        // getting frames); restart it once AppKit is done with the event.
        DispatchQueue.main.async { NotificationCenter.default.post(name: .restartViewerDisplayLink, object: nil) }
    }
}

/// The editor app. Launched by the thin `MetalComposer` executable.
public struct MetalComposerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()

    public init() {}

    public var body: some Scene {
        Window("Metal Composer", id: "main") {
            ContentView(state: state, composition: state.composition)
                .frame(minWidth: 1100, minHeight: 680)
                .onAppear { [state] in delegate.openHandler = { state.open($0) } }
        }
        .defaultSize(width: 1500, height: 900)

        Settings {
            SettingsView()
        }

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
struct PoppedOutViewerBar: View {
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

/// The app's light or dark look, chosen in Settings (or following the system).
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let defaultsKey = "appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Use System Setting"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    static var current: AppAppearance {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(AppAppearance.init) ?? .system
    }

    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

struct SettingsView: View {
    @AppStorage(AppAppearance.defaultsKey) private var appearance = AppAppearance.system

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
        }
        .padding(20)
        .frame(width: 360)
        .onChange(of: appearance) { _, new in new.apply() }
    }
}
#endif
