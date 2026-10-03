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

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal is not supported on this Mac") }
        do {
            let resources = try RenderResources(device: device)
            renderer = Renderer(resources: resources, composition: composition, playback: playback)
        } catch {
            fatalError("Failed to build Metal pipelines: \(error)")
        }
        playback.onRestart = { [composition] in composition.nodes.forEach { $0.reset() } }
        composition.loadDemo()
    }

    func newComposition() {
        composition.fileURL = nil
        composition.replace(nodes: [], connections: [])
        composition.add(ClearPatch.self, at: CGPoint(x: 400, y: 80))
        playback.restart()
    }

    func loadDemo() {
        composition.loadDemo()
        playback.restart()
    }

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.metalComposition, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try composition.load(Data(contentsOf: url))
            composition.fileURL = url
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
                Button("Load Demo") { state.loadDemo() }
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { state.save() }.keyboardShortcut("s")
                Button("Save As…") { state.save(as: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
    }
}

struct ContentView: View {
    let state: AppState
    @ObservedObject var composition: Composition

    var body: some View {
        HSplitView {
            LibraryView(composition: composition)
                .frame(minWidth: 190, idealWidth: 220, maxWidth: 300)
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
    }
}
