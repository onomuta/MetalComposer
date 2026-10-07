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

    /// Writes the composition to `url` and makes it the document's file. False (after telling the
    /// user) when it couldn't be written.
    @discardableResult
    func write(to url: URL) -> Bool {
        do {
            try composition.encoded().write(to: url, options: .atomic)
            composition.fileURL = url
            return true
        } catch {
            show(AppAlert(error))
            return false
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
    /// Height of the viewer and inspector row under the editor in the compact layout.
    @AppStorage("compactBottomHeight") private var compactBottomHeight = 420.0
    /// The layout in use (tracked for the toolbar).
    @State private var layout = Layout.columns
    /// The library floating over the editor in the compact and phone layouts (the columns'
    /// library is `state.showLibrary`, so each keeps its own).
    @State private var showFloatingLibrary = false
    /// The inspector sheet in the phone layout.
    @State private var showInspectorSheet = false

    enum Layout {
        /// Library, editor, viewer over inspector: the Mac and landscape iPad.
        case columns
        /// Editor over viewer and inspector, library floating: portrait iPad, narrow Split View.
        case compact
        /// Viewer and editor, inspector in a sheet, library floating: iPhone, Slide Over.
        case phone
    }

    private static func layout(for size: CGSize) -> Layout {
        #if os(macOS)
        return .columns
        #else
        if size.width < 600 || size.height < 500 { return .phone }
        if size.width < size.height || size.width < 900 { return .compact }
        return .columns
        #endif
    }

    var body: some View {
        GeometryReader { geo in
            let layout = Self.layout(for: geo.size)
            Group {
                switch layout {
                case .columns: columnsLayout(geo.size)
                case .compact: compactLayout(geo.size)
                case .phone: phoneLayout(geo.size)
                }
            }
            .onChange(of: layout, initial: true) { _, new in self.layout = new }
            // ⌘↩ (Find Patch) opens the floating library outside the columns layout.
            .onChange(of: state.librarySearchRequest) { _, _ in
                if self.layout != .columns { showFloatingLibrary = true }
            }
        }
        #if os(macOS)
        .navigationTitle(composition.fileURL?.deletingPathExtension().lastPathComponent ?? "Metal Composer")
        #endif
        .alert(item: $state.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
        .sheet(isPresented: $state.showExport) {
            ExportMovieView(exporter: state.exporter) { state.exportMovie() }
                .interactiveDismissDisabled(state.exporter.isExporting)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    if layout == .columns { state.showLibrary.toggle() } else { showFloatingLibrary.toggle() }
                } label: { Image(systemName: "sidebar.left") }
                    .help(state.showLibrary ? "Hide Patch Library (⌥⌘L)" : "Show Patch Library (⌥⌘L)")
            }
            if layout == .phone {
                ToolbarItem(placement: .primaryAction) {
                    Button { showInspectorSheet.toggle() } label: {
                        Label("Inspector", systemImage: "slider.horizontal.3")
                    }
                }
            }
        }
    }

    /// The graph editor with the library floating over its top-left corner.
    private func editorWithFloatingLibrary(libraryWidth: CGFloat, libraryHeight: CGFloat) -> some View {
        GraphEditorView(composition: composition)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                if showFloatingLibrary {
                    LibraryView(composition: composition, searchRequest: state.librarySearchRequest,
                                onAddedFromSearch: { showFloatingLibrary = false },
                                onAdd: { showFloatingLibrary = false })
                        .frame(width: libraryWidth, height: max(160, libraryHeight))
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .shadow(radius: 12)
                        .padding(10)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: showFloatingLibrary)
    }

    /// Editor on top at full width; viewer and inspector side by side below it.
    private func compactLayout(_ size: CGSize) -> some View {
        // Keep at least a usable editor above and a usable row below.
        let bottom = min(max(compactBottomHeight, 240), max(240, size.height - 300))
        return VStack(spacing: 0) {
            editorWithFloatingLibrary(libraryWidth: min(320, size.width - 40),
                                      libraryHeight: min(560, size.height - bottom - 40))
            RowResizeHandle(height: $compactBottomHeight, shown: bottom, range: 240...1000, growsUpward: true)
            HStack(spacing: 0) {
                ViewerPanel(renderer: state.renderer, playback: state.playback, onTogglePopOut: popOutViewer)
                    .frame(width: size.width / 2)
                Rectangle().fill(Color.separatorLine).frame(width: 1)
                InspectorView(composition: composition)
                    .frame(maxWidth: .infinity)
            }
            .frame(height: bottom)
        }
    }

    /// Phone: the viewer above the editor (beside it in landscape); the inspector is a sheet that
    /// can stay open at half height while the editor is used, following the selection.
    private func phoneLayout(_ size: CGSize) -> some View {
        let viewer = ViewerPanel(renderer: state.renderer, playback: state.playback, onTogglePopOut: popOutViewer)
        return Group {
            if size.width > size.height {
                HStack(spacing: 0) {
                    editorWithFloatingLibrary(libraryWidth: min(300, size.width * 0.6 - 40), libraryHeight: size.height - 40)
                    Rectangle().fill(Color.separatorLine).frame(width: 1)
                    viewer.frame(width: size.width * 0.4)
                }
            } else {
                VStack(spacing: 0) {
                    // A 16:9 picture plus the viewer's control bar, but never most of the screen.
                    viewer.frame(height: min(size.width * 9 / 16 + 36, size.height * 0.4))
                    Rectangle().fill(Color.separatorLine).frame(height: 1)
                    editorWithFloatingLibrary(libraryWidth: min(320, size.width - 40), libraryHeight: size.height * 0.5)
                }
            }
        }
        .sheet(isPresented: $showInspectorSheet) {
            InspectorView(composition: composition)
                .presentationDetents([.fraction(0.35), .medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
        }
    }

    /// Library, editor, then the viewer above the inspector (the Mac, and iPad in landscape).
    private func columnsLayout(_ size: CGSize) -> some View {
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
    /// Thicker with touch, so a finger can grab it.
    #if os(macOS)
    static let height: CGFloat = 7
    #else
    static let height: CGFloat = 16
    #endif

    @Binding var height: Double
    /// The height actually shown, which is smaller than `height` when the window is short.
    var shown: Double
    var range: ClosedRange<Double>
    /// True when the view being resized is below the handle (dragging up makes it taller).
    var growsUpward = false

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
                    let delta = growsUpward ? -g.translation.height : g.translation.height
                    height = min(max(start + delta, range.lowerBound), range.upperBound)
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
