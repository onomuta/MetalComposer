import SwiftUI

struct LibraryView: View {
    @ObservedObject var composition: Composition
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search patches", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            List {
                ForEach(PatchRegistry.sections, id: \.self) { section in
                    let types = PatchRegistry.all.filter { $0.librarySection == section && matches($0) }
                    if !types.isEmpty {
                        Section(section) {
                            ForEach(types, id: \.typeID) { type in
                                Button { add(type) } label: {
                                    HStack(alignment: .top, spacing: 8) {
                                        RoundedRectangle(cornerRadius: 2).fill(type.category.color).frame(width: 4, height: 28)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(type.title).foregroundStyle(.primary)
                                            Text(type.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Add \(type.title)")
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func matches(_ type: Patch.Type) -> Bool {
        search.isEmpty || type.title.localizedCaseInsensitiveContains(search)
            || type.summary.localizedCaseInsensitiveContains(search)
    }

    private func add(_ type: Patch.Type) {
        let jitter = CGFloat(composition.graph.nodes.count % 6) * 16
        let c = composition.visibleCenter
        composition.add(type, at: CGPoint(x: c.x + jitter, y: c.y + jitter))
    }
}
