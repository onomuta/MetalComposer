// mirage-mcp: an MCP server (stdio) that builds and renders Mirage Composer compositions (ADR 0001).
#if os(macOS)
import Foundation
import MirageMCPCore

do {
    try MCPServer(imageFolders: MCPServer.imageFolders(from: CommandLine.arguments)).run()
} catch {
    FileHandle.standardError.write(Data("mirage-mcp: \(error)\n".utf8))
    exit(1)
}
#endif
