#if os(macOS)
import AppKit
#endif
import Combine
import Metal
import SwiftUI
import UniformTypeIdentifiers
import MetalComposerKit

extension UTType {
    /// `.mcomp`. Looked up by extension so it matches files on disk both in the bundled app (which
    /// declares `dev.metalcomposer.composition`) and when run as a bare SwiftPM executable (where
    /// the system only has a dynamic type for the extension).
    static let metalComposition = UTType(filenameExtension: "mcomp") ?? .json
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
    /// A problem to show the user (iOS shows it as an alert; the Mac uses NSAlert directly).
    @Published var alert: AppAlert?
    var keyMonitor: Any?
    private var documentFolder: AnyCancellable?

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal is not supported on this device") }
        do {
            let resources = try RenderResources(device: device)
            renderer = Renderer(resources: resources, composition: composition, playback: playback)
        } catch {
            fatalError("Failed to build Metal pipelines: \(error)")
        }
        playback.onRestart = { [composition] in composition.root.nodes.forEach { $0.restart() } }
        composition.loadDemo(.basics)
        #if os(macOS)
        installDeleteKey()
        #endif
        exporter.onBusyChange = { [renderer] busy in renderer.isSuspended = busy }
        // Relative image paths resolve against the open document's folder.
        documentFolder = composition.$fileURL.sink { [renderer] url in
            renderer.resources.baseDirectory = url?.deletingLastPathComponent()
        }
    }

    /// ⌘↩ toggles: opens the patch library with the cursor in its search field, or closes it
    /// (handing the keyboard back to the graph) when it is already open.
    func findPatch() {
        if showLibrary {
            showLibrary = false
            #if os(macOS)
            NSApp.keyWindow?.makeFirstResponder(nil)
            #endif
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

    /// Writes the composition to `url` and makes it the document's file.
    func write(to url: URL) {
        do {
            try composition.encoded().write(to: url, options: .atomic)
            composition.fileURL = url
        } catch {
            show(AppAlert(error))
        }
    }

    #if !os(macOS)
    /// Renders the composition to a movie in the temporary folder; the sheet then offers to share it.
    func exportMovie() {
        let codec = exporter.settings.codec
        let name = composition.fileURL?.deletingPathExtension().lastPathComponent ?? "Metal Composer"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).\(codec.fileExtension)")
        try? FileManager.default.removeItem(at: url)
        exporter.start(record: composition.root.record(), resources: renderer.resources, to: url)
    }
    #endif

    func show(_ alert: AppAlert) {
        #if os(macOS)
        let panel = NSAlert()
        panel.alertStyle = .warning
        panel.messageText = alert.title
        panel.informativeText = alert.message
        panel.runModal()
        #else
        self.alert = alert
        #endif
    }

    func loadDemo(_ demo: Demo) {
        composition.loadDemo(demo)
        playback.restart()
    }

    /// Opens a composition file (from the Open panel, Finder or the Dock).
    func open(_ url: URL) {
        do {
            let unknown = try composition.load(Data(contentsOf: url), url: url)
            playback.restart()
            if !unknown.isEmpty {
                show(AppAlert(title: "Some patches couldn't be loaded",
                              message: "This composition uses patches this version of Metal Composer doesn't know: "
                                + unknown.joined(separator: ", ")
                                + ". They were skipped along with their connections. It was probably saved by a newer version; saving it here will drop them."))
            }
        } catch {
            show(AppAlert(error))
        }
    }


}

struct ContentView: View {
    @ObservedObject var state: AppState
    @ObservedObject var composition: Composition
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    // Fixed column widths (remembered between launches); only the editor flexes, so showing or
    // hiding the library never changes the right column.
    @AppStorage("libraryWidth") private var libraryWidth = 220.0
    @AppStorage("rightColumnWidth") private var rightColumnWidth = 460.0
    // The viewer's height is fixed too (a split view would re-balance whenever the inspector's
    // content changes, e.g. on every selection).
    @AppStorage("viewerHeight") private var viewerHeight = 380.0
    private static let inspectorMinHeight = 200.0
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
                VStack(spacing: 0) {
                    if state.viewerPoppedOut {
                        #if os(macOS)
                        PoppedOutViewerBar()
                        #endif
                    } else {
                        // Shrink the viewer only when the window is too short to fit it.
                        let height = min(viewerHeight,
                                         max(240, geo.size.height - RowResizeHandle.height - Self.inspectorMinHeight))
                        ViewerPanel(renderer: state.renderer, playback: state.playback, onTogglePopOut: popOutViewer)
                        .frame(height: height)
                        RowResizeHandle(height: $viewerHeight, shown: height, range: 240...1200)
                    }
                    InspectorView(composition: composition)
                        .frame(minHeight: Self.inspectorMinHeight, maxHeight: .infinity)
                }
                .frame(width: rightWidth)
            }
        }
        .navigationTitle(composition.fileURL?.deletingPathExtension().lastPathComponent ?? "Metal Composer")
        .alert(item: $state.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
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

extension ContentView {
    /// Moves the viewer into its own window (the Mac only).
    private var popOutViewer: (() -> Void)? {
        #if os(macOS)
        return {
            state.viewerPoppedOut = true
            openWindow(id: "viewer")
        }
        #else
        return nil
        #endif
    }
}

/// A column divider that resizes the column on one side by dragging.
struct ColumnResizeHandle: View {
    static let width: CGFloat = 7

    @Binding var width: Double
    var range: ClosedRange<Double>
    /// True when the column is to the right of the handle (dragging left makes it wider).
    var growsLeftward = false

    @State private var dragStart: Double?

    var body: some View {
        ZStack {
            Color.clear
            Rectangle().fill(Color.separatorLine).frame(width: 1)
        }
        .frame(width: Self.width)
        .contentShape(Rectangle())
        .onHover(perform: ResizeCursor.leftRight.set)
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

/// Like `ColumnResizeHandle`, between two views stacked vertically; resizes the one above.
struct RowResizeHandle: View {
    static let height: CGFloat = 7

    @Binding var height: Double
    /// The height actually shown, which is smaller than `height` when the window is short.
    var shown: Double
    var range: ClosedRange<Double>

    @State private var dragStart: Double?

    var body: some View {
        ZStack {
            Color.clear
            Rectangle().fill(Color.separatorLine).frame(height: 1)
        }
        .frame(height: Self.height)
        .contentShape(Rectangle())
        .onHover(perform: ResizeCursor.upDown.set)
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { g in
                    let start = dragStart ?? shown
                    dragStart = start
                    height = min(max(start + g.translation.height, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in dragStart = nil }
        )
    }
}

/// A message for the user: an error, or a warning about the opened file.
struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String

    init(title: String, message: String) {
        self.title = title
        self.message = message
    }

    /// Like NSAlert(error:): the description as the title, the recovery suggestion below.
    init(_ error: Error) {
        self.init(title: error.localizedDescription, message: (error as NSError).localizedRecoverySuggestion ?? "")
    }
}
