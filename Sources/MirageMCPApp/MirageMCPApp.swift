#if os(macOS)
import AppKit
import MirageMCPCore
import SwiftUI

/// Mirage MCP: settings and activity for mirage-mcp, the MCP server bundled inside this app (ADR 0002).
/// The server is started by AI clients, not by this app; the two share files in
/// ~/Library/Application Support/Mirage MCP.
struct MirageMCPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = MCPStore()

    var body: some Scene {
        Window("Mirage MCP", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 560, minHeight: 520)
        }
        .defaultSize(width: 720, height: 680)
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

/// The shared settings and the activity record, kept up to date while the app is open.
@MainActor
final class MCPStore: ObservableObject {
    let support = SupportFiles.standard
    @Published private(set) var settings = SupportFiles.Settings()
    /// Why the settings file couldn't be read (mirage-mcp treats that as paused).
    @Published private(set) var settingsProblem: String?
    /// Newest first.
    @Published private(set) var entries: [SupportFiles.Entry] = []
    @Published var error: String?

    /// The server inside this app, which AI clients should start.
    let serverURL: URL? = Bundle.main.url(forAuxiliaryExecutable: "mirage-mcp")

    private var lastActivityChange: Date?
    private var timer: Timer?

    init() {
        // The folder's existence is what turns on mirage-mcp's activity record.
        try? FileManager.default.createDirectory(at: support.folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        support.trimActivity()
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reloadIfChanged() }
        }
    }

    var paused: Bool { settings.paused || settingsProblem != nil }

    func reload() {
        let (loaded, problem) = support.loadSettings()
        settings = problem == nil ? loaded : settings
        settingsProblem = problem
        entries = support.loadEntries().reversed()
        lastActivityChange = modificationDate(support.activityURL)
    }

    private func reloadIfChanged() {
        if modificationDate(support.activityURL) != lastActivityChange { reload() }
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func save(_ change: (inout SupportFiles.Settings) -> Void) {
        var next = settings
        change(&next)
        do {
            try support.saveSettings(next)
            settings = next
            settingsProblem = nil
        } catch {
            self.error = "Could not save the settings: \(error.localizedDescription)"
        }
    }

    func setPaused(_ paused: Bool) { save { $0.paused = paused } }

    func addFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        save { if !$0.imageFolders.contains(path) { $0.imageFolders.append(path) } }
    }

    func removeFolder(_ path: String) { save { $0.imageFolders.removeAll { $0 == path } } }

    func clearActivity() {
        support.clearActivity()
        reload()
    }

    func thumbnail(_ name: String) -> NSImage? {
        NSImage(contentsOf: support.thumbnailsFolder.appendingPathComponent(name))
    }
}

struct ContentView: View {
    @ObservedObject var store: MCPStore
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { !store.paused }, set: { store.setPaused(!$0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow AI to use Mirage Composer")
                        Text(store.paused
                             ? "Paused: every request from AI clients is refused."
                             : "AI clients that have mirage-mcp registered can build, render and save compositions.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                if let problem = store.settingsProblem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
                LabeledContent("Server") {
                    if let url = store.serverURL {
                        Text(url.path).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
                    } else {
                        Text("Not bundled (run the app built by Scripts/bundle-mcp.sh)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                if store.settings.imageFolders.isEmpty {
                    Text("None. Image Importer can only read images in the folder the composition is saved in.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(store.settings.imageFolders, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder")
                        Text(path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) { store.removeFolder(path) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Stop allowing this folder")
                    }
                }
                Button("Add Folder…") { chooseFolder() }
            } header: {
                Text("Image folders")
            } footer: {
                Text("Image Importer may read images in these folders, besides the composition's own folder.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                if store.entries.isEmpty {
                    Text("No activity yet.").foregroundStyle(.secondary)
                }
                ForEach(Array(store.entries.prefix(300).enumerated()), id: \.offset) { _, entry in
                    ActivityRow(entry: entry, store: store)
                }
            } header: {
                HStack {
                    Text("Activity")
                    Spacer()
                    Button("Clear…") { confirmClear = true }
                        .disabled(store.entries.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .alert("Clear the activity record?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { store.clearActivity() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the recorded tool calls and render thumbnails. Saved compositions are not touched.")
        }
        .alert("Mirage MCP", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: {
            Text(store.error ?? "")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Allow"
        panel.message = "Choose folders whose images Image Importer may read."
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(store.addFolder)
    }
}

private struct ActivityRow: View {
    let entry: SupportFiles.Entry
    @ObservedObject var store: MCPStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: entry.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(entry.ok ? .green : .red)
                Text(entry.tool).font(.body.monospaced())
                Spacer()
                Text(entry.time, format: .dateTime.hour().minute().second()).font(.caption).foregroundStyle(.secondary)
            }
            if !entry.message.isEmpty {
                Text(entry.message).font(.caption).foregroundStyle(entry.ok ? Color.secondary : Color.red).lineLimit(3)
            }
            Text(entry.arguments).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(2).textSelection(.enabled)
            if !entry.thumbnails.isEmpty {
                HStack {
                    ForEach(entry.thumbnails, id: \.self) { name in
                        if let image = store.thumbnail(name) {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                    }
                }
            }
            if let saved = entry.saved {
                HStack {
                    Text(saved).font(.caption).lineLimit(1).truncationMode(.middle)
                    Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: saved)) }
                        .help("Open in Mirage Composer")
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: saved)]) }
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}
#endif
