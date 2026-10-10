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

    // Registration with AI clients (ADR 0002, step 3).
    lazy var desktop = ClaudeDesktopConfig.standard(backups: support.folder.appendingPathComponent("backups", isDirectory: true))
    let code = ClaudeCode.standard
    @Published private(set) var desktopStatus = RegistrationStatus.notRegistered
    @Published private(set) var codeStatus = RegistrationStatus.notRegistered
    @Published var notice: String?

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
        refreshRegistrations()
    }

    func refreshRegistrations() {
        guard let server = serverURL?.path else { return }
        desktopStatus = desktop.status(server: server)
        codeStatus = code.status(server: server)
    }

    func registerDesktop(_ register: Bool) {
        guard let server = serverURL?.path else { return }
        do {
            let backup = register ? try desktop.register(server: server) : try desktop.unregister()
            notice = (register ? "Registered with Claude Desktop." : "Removed from Claude Desktop.")
                + " Quit and reopen Claude Desktop to apply it."
                + (backup.map { " The previous settings were copied to \($0.path)." } ?? "")
        } catch {
            self.error = "Could not change Claude Desktop's settings: \(error.localizedDescription)"
        }
        refreshRegistrations()
    }

    func registerCode(_ register: Bool) {
        guard let server = serverURL?.path else { return }
        do {
            // An existing registration (another path) is removed first: `claude mcp add` won't replace it.
            if codeStatus != .notRegistered { _ = try? code.run(register: false, server: server) }
            if register { _ = try code.run(register: true, server: server) }
            notice = register ? "Registered with Claude Code. New Claude Code sessions can use it." : "Removed from Claude Code."
        } catch {
            self.error = "claude mcp failed: \(error.localizedDescription)"
        }
        refreshRegistrations()
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
    @State private var confirmDesktop: Bool?
    @State private var confirmCode: Bool?

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

            if let server = store.serverURL?.path {
                Section {
                    registrationRow("Claude Desktop", status: store.desktopStatus,
                                    register: { confirmDesktop = true }, remove: { confirmDesktop = false })
                    registrationRow("Claude Code", status: store.codeStatus,
                                    register: store.code.cli == nil ? nil : { confirmCode = true },
                                    remove: store.code.cli == nil ? nil : { confirmCode = false })
                    if store.code.cli == nil {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Claude Code's `claude` command wasn't found. Run this in Terminal to register:")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Text(ClaudeCode.addCommand(server: server)).font(.caption.monospaced()).textSelection(.enabled)
                                Spacer()
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(ClaudeCode.addCommand(server: server), forType: .string)
                                }
                            }
                        }
                    }
                    if let notice = store.notice {
                        Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                } header: {
                    HStack {
                        Text("AI clients")
                        Spacer()
                        Button("Refresh") { store.refreshRegistrations() }.controlSize(.small)
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
        .alert(confirmDesktop == true ? "Register with Claude Desktop?" : "Remove from Claude Desktop?",
               isPresented: Binding(get: { confirmDesktop != nil }, set: { if !$0 { confirmDesktop = nil } })) {
            Button(confirmDesktop == true ? "Register" : "Remove") {
                if let register = confirmDesktop { store.registerDesktop(register) }
                confirmDesktop = nil
            }
            Button("Cancel", role: .cancel) { confirmDesktop = nil }
        } message: {
            Text(desktopChangeDescription)
        }
        .alert(confirmCode == true ? "Register with Claude Code?" : "Remove from Claude Code?",
               isPresented: Binding(get: { confirmCode != nil }, set: { if !$0 { confirmCode = nil } })) {
            Button(confirmCode == true ? "Register" : "Remove") {
                if let register = confirmCode { store.registerCode(register) }
                confirmCode = nil
            }
            Button("Cancel", role: .cancel) { confirmCode = nil }
        } message: {
            Text("This runs:\n" + (confirmCode == true
                ? ClaudeCode.addCommand(server: store.serverURL?.path ?? "")
                : ClaudeCode.removeCommand)
                + "\n\nClaude Code's own settings file is not edited by Mirage MCP.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshRegistrations()
        }
        .alert("Mirage MCP", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: {
            Text(store.error ?? "")
        }
    }

    private var desktopChangeDescription: String {
        let path = store.desktop.url.path
        if confirmDesktop == true {
            let entry = ClaudeDesktopConfig.entry(server: store.serverURL?.path ?? "")
            let json = (try? JSONSerialization.data(withJSONObject: ["mirage": entry], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            return "In \(path), only mcpServers.mirage is set to:\n\(json)\n\nEverything else stays as it is. The current file is copied first. Restart Claude Desktop afterwards."
        }
        return "In \(path), only mcpServers.mirage is removed. Everything else stays as it is. The current file is copied first."
    }

    @ViewBuilder
    private func registrationRow(_ name: String, status: RegistrationStatus,
                                 register: (() -> Void)?, remove: (() -> Void)?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                switch status {
                case .registered:
                    Label("Registered", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                case .notRegistered:
                    Text("Not registered").font(.caption).foregroundStyle(.secondary)
                case .otherPath(let path):
                    Text("Registered with another copy: \(path)").font(.caption).foregroundStyle(.orange).lineLimit(2)
                case .unknown(let reason):
                    Text(reason).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            if let register, status != .registered {
                Button(status == .notRegistered ? "Register…" : "Update…", action: register)
            }
            if let remove, status != .notRegistered {
                Button("Remove…", action: remove)
            }
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
