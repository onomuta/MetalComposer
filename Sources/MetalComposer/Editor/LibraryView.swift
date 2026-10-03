import AppKit
import SwiftUI

struct LibraryView: View {
    @ObservedObject var composition: Composition
    /// Changes whenever ⌘↩ asks for the search field.
    var searchRequest: Int
    /// Called after Return adds the highlighted patch (the window closes the library).
    var onAddedFromSearch: () -> Void = {}

    @State private var search = ""
    @State private var highlighted = 0
    @FocusState private var searchFocused: Bool

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
            TextField("Search patches  (⌘↩)", text: $search)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .padding(8)
                .onChange(of: search) { _, _ in highlighted = 0 }
                .onSubmit { addHighlighted(results) }
                .onKeyPress(.downArrow) { moveHighlight(1, count: results.count) }
                .onKeyPress(.upArrow) { moveHighlight(-1, count: results.count) }
                .onExitCommand { finishSearch() }
            ScrollViewReader { proxy in
                List {
                    if search.isEmpty {
                        ForEach(PatchRegistry.sections, id: \.self) { section in
                            Section(section) {
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
        .onAppear { if searchRequest > 0 { focusSearch() } }
        .onChange(of: searchRequest) { _, _ in focusSearch() }
    }

    private func row(_ type: Patch.Type, isHighlighted: Bool) -> some View {
        Button { add(type) } label: {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(type.category.color).frame(width: 4, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(type.title).foregroundStyle(.primary)
                    Text(type.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
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
            (NSApp.keyWindow?.firstResponder as? NSText)?.selectAll(nil)
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
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func add(_ type: Patch.Type) {
        let jitter = CGFloat(composition.graph.nodes.count % 6) * 16
        let c = composition.visibleCenter
        composition.add(type, at: CGPoint(x: c.x + jitter, y: c.y + jitter))
    }
}
