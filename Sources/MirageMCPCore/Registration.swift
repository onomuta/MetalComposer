import Foundation

/// Whether an AI client starts this mirage-mcp (ADR 0002, "登録の方法").
package enum RegistrationStatus: Equatable {
    case notRegistered
    /// Registered with this server.
    case registered
    /// Registered, but with another path (an older copy or a moved app).
    case otherPath(String)
    /// The client's settings can't be read.
    case unknown(String)
}

/// Claude Desktop: its settings file is edited directly, changing only `mcpServers.mirage`.
package struct ClaudeDesktopConfig {
    package let url: URL
    /// Where copies are kept before each change.
    package let backups: URL
    package static let serverName = "mirage"
    static let backupLimit = 5

    package init(url: URL, backups: URL) {
        self.url = url
        self.backups = backups
    }

    package static func standard(backups: URL) -> ClaudeDesktopConfig {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return ClaudeDesktopConfig(url: base.appendingPathComponent("Claude/claude_desktop_config.json"), backups: backups)
    }

    private func read() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return object
    }

    package func status(server: String) -> RegistrationStatus {
        do {
            guard let entry = (try read()["mcpServers"] as? [String: Any])?[Self.serverName] as? [String: Any] else {
                return .notRegistered
            }
            let command = entry["command"] as? String ?? ""
            return command == server ? .registered : .otherPath(command)
        } catch {
            return .unknown("Claude Desktop's settings can't be read (\(url.path)).")
        }
    }

    /// The entry that registering would write.
    package static func entry(server: String) -> [String: Any] { ["command": server, "args": [String]()] }

    /// Adds or updates `mcpServers.mirage`. Returns the backup of the previous file, if there was one.
    @discardableResult
    package func register(server: String) throws -> URL? {
        try change { servers in servers[Self.serverName] = Self.entry(server: server) }
    }

    /// Removes `mcpServers.mirage`. Returns the backup of the previous file.
    @discardableResult
    package func unregister() throws -> URL? {
        try change { servers in servers[Self.serverName] = nil }
    }

    /// Reads the file again right before writing, changes only `mcpServers`, and writes it in one go
    /// with the same permissions, after keeping a private copy of the previous version.
    private func change(_ edit: (inout [String: Any]) -> Void) throws -> URL? {
        var config = try read()
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        edit(&servers)
        config["mcpServers"] = servers
        let backup = try backUp()
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int ?? 0o600
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        return backup
    }

    /// A copy of the current file (readable only by the user); only the newest few are kept.
    private func backUp() throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let fm = FileManager.default
        try fm.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let copy = backups.appendingPathComponent("claude_desktop_config-\(stamp)-\(UUID().uuidString.prefix(4)).json")
        try fm.copyItem(at: url, to: copy)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
        let old = ((try? fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("claude_desktop_config-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .dropLast(Self.backupLimit)
        old.forEach { try? fm.removeItem(at: $0) }
        return copy
    }
}

/// Claude Code: registered with its own `claude mcp` command; its settings file (~/.claude.json) is
/// only read, never written, because Claude Code writes it too and it holds other servers' secrets.
package struct ClaudeCode {
    /// Claude Code's settings, read for the registration status only.
    package let settingsURL: URL
    /// The `claude` command, if found.
    package let cli: URL?

    package init(settingsURL: URL, cli: URL?) {
        self.settingsURL = settingsURL
        self.cli = cli
    }

    package static var standard: ClaudeCode {
        ClaudeCode(settingsURL: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json"),
                   cli: findCLI())
    }

    /// The `claude` command in the usual install locations. Copies inside other apps (e.g. the
    /// Claude desktop app's own) are not used.
    package static func findCLI(home: String = NSHomeDirectory()) -> URL? {
        let candidates = [
            "\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    /// The command that registers the server for all projects.
    package static func addCommand(server: String) -> String {
        "claude mcp add --scope user \(ClaudeDesktopConfig.serverName) -- \(shellQuoted(server))"
    }

    package static var removeCommand: String { "claude mcp remove --scope user \(ClaudeDesktopConfig.serverName)" }

    static func shellQuoted(_ s: String) -> String {
        s.allSatisfy { $0.isLetter || $0.isNumber || "/._-".contains($0) } ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The user-scope registration in ~/.claude.json (read only; nothing else is looked at).
    package func status(server: String) -> RegistrationStatus {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return .notRegistered }
        guard let data = try? Data(contentsOf: settingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unknown("Claude Code's settings can't be read.")
        }
        guard let entry = (object["mcpServers"] as? [String: Any])?[ClaudeDesktopConfig.serverName] as? [String: Any] else {
            return .notRegistered
        }
        let command = entry["command"] as? String ?? ""
        return command == server ? .registered : .otherPath(command)
    }

    /// Runs `claude mcp add` / `remove` (user scope). Returns the command's output.
    package func run(register: Bool, server: String) throws -> String {
        guard let cli else { throw CocoaError(.fileNoSuchFile) }
        let process = Process()
        process.executableURL = cli
        process.arguments = register
            ? ["mcp", "add", "--scope", "user", ClaudeDesktopConfig.serverName, "--", server]
            : ["mcp", "remove", "--scope", "user", ClaudeDesktopConfig.serverName]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ClaudeCode", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: output.isEmpty ? "claude exited with \(process.terminationStatus)" : output])
        }
        return output
    }
}
