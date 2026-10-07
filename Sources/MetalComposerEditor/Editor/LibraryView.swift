#if os(macOS)
import AppKit
import Carbon
#endif
import SwiftUI
import MetalComposerKit

struct LibraryView: View {
    // Not observed: the list doesn't depend on the document, and re-diffing every row on each
    // document change was a large part of the cost of editing a value.
    let composition: Composition
    /// Changes whenever ⌘↩ asks for the search field.
    var searchRequest: Int
    /// Called after Return adds the highlighted patch (the window closes the library).
    var onAddedFromSearch: () -> Void = {}
    /// Where new patches go; nil places them near the middle of the editor.
    var insertionPoint: CGPoint?
    /// Called after any patch is added.
    var onAdd: () -> Void = {}

    #if os(macOS)
    private static let searchPrompt = "Search patches  (⌘↩)"
    #else
    private static let searchPrompt = "Search patches"
    #endif

    @State private var search = ""
    @State private var highlighted = 0
    @FocusState private var searchFocused: Bool
    #if os(macOS)
    /// The input source in use before the search field switched to alphanumeric input.
    @State private var inputSourceBeforeSearch: TISInputSource?
    #endif

    /// Matching patches. Without a query: sections in registry order. With one: best matches first
    /// (title prefix, then title contains, then description), so Return picks the obvious patch.
    private var results: [Patch.Type] {
        let all = PatchRegistry.sections.flatMap { section in PatchRegistry.all.filter { $0.librarySection == section } }
        guard !search.isEmpty else { return all }
        func rank(_ t: Patch.Type) -> Int? {
            if t.title.lowercased().hasPrefix(search.lowercased()) { return 0 }
            if t.title.localizedCaseInsensitiveContains(search) { return 1 }
            if t.summary.localizedCaseInsensitiveContains(search) { return 2 }
            return nil
        }
        return all.compactMap { t in rank(t).map { (t, $0) } }
            .enumerated().sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }
            .map(\.element.0)
    }

    var body: some View {
        let results = results
        VStack(spacing: 0) {
            TextField(loc(Self.searchPrompt), text: $search)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .padding(8)
                .onChange(of: search) { _, _ in highlighted = 0 }
                .onSubmit { addHighlighted(results) }
                .onKeyPress(.downArrow) { moveHighlight(1, count: results.count) }
                .onKeyPress(.upArrow) { moveHighlight(-1, count: results.count) }
                #if os(macOS)
                .onExitCommand { finishSearch() }
                #else
                .onKeyPress(.escape) { finishSearch(); return .handled }
                // Patch names are English.
                .keyboardType(.asciiCapable)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #endif
            ScrollViewReader { proxy in
                List {
                    if search.isEmpty {
                        ForEach(PatchRegistry.sections, id: \.self) { section in
                            Section(loc(section)) {
                                ForEach(results.filter { $0.librarySection == section }, id: \.typeID) { type in
                                    row(type, isHighlighted: searchFocused && results.firstIndex { $0 == type } == highlighted)
                                        .id(type.typeID)
                                }
                            }
                        }
                    } else {
                        Section("Results") {
                            ForEach(Array(results.enumerated()), id: \.element.typeID) { i, type in
                                row(type, isHighlighted: i == highlighted).id(type.typeID)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: highlighted) { _, i in
                    if results.indices.contains(i) { proxy.scrollTo(results[i].typeID) }
                }
            }
        }
        // Patch names are English: type them without the IME, then go back to the previous input.
        .onChange(of: searchFocused) { _, focused in
            if focused { switchToASCIIInput() } else { restoreInputSource() }
        }
        // Adding a patch from the search closes the library, possibly before focus moves.
        .onDisappear { restoreInputSource() }
        .onAppear { if searchRequest > 0 { focusSearch() } }
        .onChange(of: searchRequest) { _, _ in focusSearch() }
    }

    private func switchToASCIIInput() {
        #if os(macOS)
        inputSourceBeforeSearch = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        if let ascii = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue() {
            TISSelectInputSource(ascii)
        }
        #endif
    }

    private func restoreInputSource() {
        #if os(macOS)
        guard let previous = inputSourceBeforeSearch else { return }
        TISSelectInputSource(previous)
        inputSourceBeforeSearch = nil
        #endif
    }

    private func row(_ type: Patch.Type, isHighlighted: Bool) -> some View {
        Button { add(type) } label: {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(type.category.color).frame(width: 4, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(type.title).foregroundStyle(.primary)
                    Text(loc(type.summary)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(isHighlighted ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Add \(type.title)")
    }

    private func focusSearch() {
        highlighted = 0
        // After the panel has appeared and SwiftUI has settled focus for this event.
        DispatchQueue.main.async {
            searchFocused = true
            #if os(macOS)
            (NSApp.keyWindow?.firstResponder as? NSText)?.selectAll(nil)
            #endif
        }
    }

    private func moveHighlight(_ delta: Int, count: Int) -> KeyPress.Result {
        guard count > 0 else { return .ignored }
        highlighted = (highlighted + delta + count) % count
        return .handled
    }

    /// Return adds the highlighted patch, then hands the keyboard back to the graph.
    private func addHighlighted(_ results: [Patch.Type]) {
        guard results.indices.contains(highlighted) else { return }
        add(results[highlighted])
        finishSearch()
        onAddedFromSearch()
    }

    private func finishSearch() {
        search = ""
        searchFocused = false
        #if os(macOS)
        NSApp.keyWindow?.makeFirstResponder(nil)
        #endif
    }

    private func add(_ type: Patch.Type) {
        if let insertionPoint {
            composition.add(type, at: insertionPoint)
        } else {
            let jitter = CGFloat(composition.graph.nodes.count % 6) * 16
            let c = composition.visibleCenter
            composition.add(type, at: CGPoint(x: c.x + jitter, y: c.y + jitter))
        }
        onAdd()
    }
}
