import CoreGraphics
import Foundation
import ImageIO
import Metal
import MetalComposerKit
import UniformTypeIdentifiers

/// The composition being edited, and the operations the tools perform on it.
final class Session {
    let engine: MetalComposerEngine
    private(set) var root = Graph()
    /// Where the composition was opened from or last saved (relative image paths resolve against its folder).
    private(set) var fileURL: URL?
    /// Folders Image Importer may read from, besides the composition's own folder (`--allow-images`).
    private let imageFolders: [URL]
    /// More folders, from the Mirage MCP app's settings (re-read before every tool call).
    var settingsImageFolders: [URL] = []

    /// Patches that would use the Mac's hardware outside the editor (the microphone).
    static let unavailableTypes: Set<String> = ["audio-input", "audio-spectrum"]
    /// The longest a render call may take.
    static let renderTimeLimit: TimeInterval = 15

    init(imageFolders: [URL] = []) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw ToolError("No Metal device") }
        engine = try MetalComposerEngine(device: device)
        self.imageFolders = imageFolders.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        newComposition(withClear: true)
    }

    // MARK: Documents

    /// Starts an empty composition, with a black Clear unless `withClear` is false. Returns the Clear.
    @discardableResult
    func newComposition(withClear: Bool) -> Patch? {
        root = Graph()
        fileURL = nil
        return withClear ? root.put(ClearPatch.self, 560, 40, ["color": .color(SIMD4(0, 0, 0, 1))]) : nil
    }

    /// Saves as a .mcomp file. Only .mcomp files are written, and an existing file only with `overwrite`.
    func save(to path: String, overwrite: Bool) throws -> URL {
        var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        if url.pathExtension.isEmpty { url.appendPathExtension("mcomp") }
        guard url.pathExtension.lowercased() == "mcomp" else {
            throw ToolError("Compositions are saved as .mcomp files; \(url.lastPathComponent) isn't one")
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else { throw ToolError("\(url.path) is a folder") }
            guard overwrite else { throw ToolError("\(url.path) already exists. Pass overwrite: true to replace it.") }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys] // like the editor
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(root.record()).write(to: url, options: .atomic)
        fileURL = url
        return url
    }

    // MARK: Finding patches

    /// Every graph: the root and the inside of every macro, outermost first.
    private var allGraphs: [Graph] {
        var out: [Graph] = []
        func walk(_ g: Graph) { out.append(g); g.nodes.compactMap(\.subgraph).forEach(walk) }
        walk(root)
        return out
    }

    /// The patch with this ID (or a unique start of one, at least 4 characters) and the graph it is in.
    func locate(_ id: String) throws -> (patch: Patch, graph: Graph) {
        let needle = id.lowercased()
        let matches = allGraphs.flatMap { g in g.nodes.map { (patch: $0, graph: g) } }
            .filter { $0.patch.id.uuidString.lowercased() == needle
                || (needle.count >= 4 && $0.patch.id.uuidString.lowercased().hasPrefix(needle)) }
        guard let first = matches.first else { throw ToolError("No patch with ID \(id)") }
        guard matches.count == 1 else { throw ToolError("\(id) matches \(matches.count) patches; give more of the ID") }
        return first
    }

    /// The graph to add to: the root, or the inside of the given macro (Macro, Iterator, Render In Image…).
    func graph(inside parent: String?) throws -> Graph {
        guard let parent else { return root }
        let macro = try locate(parent).patch
        guard let inner = macro.subgraph else { throw ToolError("\(macro.displayTitle) (\(parent)) can't contain patches") }
        return inner
    }

    static func patchType(_ name: String) throws -> Patch.Type {
        let type = PatchRegistry.byID[name]
            ?? PatchRegistry.all.first { $0.title.caseInsensitiveCompare(name) == .orderedSame }
        guard let type else { throw ToolError("Unknown patch type \"\(name)\". Use list_patches to see the types.") }
        guard !unavailableTypes.contains(type.typeID) else {
            throw ToolError("\(type.title) uses the microphone and isn't available here; use it in the editor.")
        }
        return type
    }

    // MARK: Files Image Importer may read

    /// The image file an Image Importer path refers to, if it may be read: inside the composition's
    /// folder (once saved) or a folder allowed with --allow-images, and an image type.
    func checkedImage(_ path: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let url: URL
        if expanded.hasPrefix("/") {
            url = URL(fileURLWithPath: expanded)
        } else if let folder = fileURL?.deletingLastPathComponent() {
            url = folder.appendingPathComponent(expanded)
        } else {
            throw ToolError("\(path) is relative: save the composition first (it is relative to the composition's folder)")
        }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let folders = imageFolders + settingsImageFolders.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            + [fileURL?.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()].compactMap { $0 }
        guard folders.contains(where: { resolved.path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }) else {
            let allowed = folders.map(\.path)
            throw ToolError("Image Importer may only read images in the composition's folder or folders allowed in the Mirage MCP app or with --allow-images (\(allowed.isEmpty ? "none yet: save the composition first" : allowed.joined(separator: ", "))); \(resolved.path) is outside them")
        }
        guard UTType(filenameExtension: resolved.pathExtension)?.conforms(to: .image) == true else {
            throw ToolError("\(resolved.lastPathComponent) is not an image file")
        }
        return resolved
    }

    /// Checks every Image Importer's file before rendering (the composition may have moved since
    /// the paths were set).
    private func checkImages() throws {
        for g in allGraphs {
            for case let importer as ImageImporterPatch in g.nodes {
                let preset = Int((importer.params["preset"] ?? .number(0)).number)
                let path = importer.params["path"]?.string ?? ""
                if preset == 0, !path.isEmpty { _ = try checkedImage(path) }
            }
        }
    }

    // MARK: Editing

    func addPatch(type name: String, parent: String?, name title: String?, x: Double?, y: Double?,
                  values: [String: Any]) throws -> Patch {
        let type = try Self.patchType(name)
        let graph = try graph(inside: parent)
        // Without a position, providers, processors and consumers go in columns, left to right.
        let column: Double = switch type.category { case .provider: 40; case .processor: 300; case .consumer: 560 }
        let below = graph.nodes.filter { $0.category == type.category && !($0 is CommentPatch) }.map { Double($0.position.y) }.max()
        let position = CGPoint(x: x ?? column, y: y ?? (below.map { $0 + 140 } ?? 40))
        let patch = type.init(position: position)
        if let title, !title.isEmpty { patch.customTitle = title }
        try setValues(values, on: patch)
        graph.nodes.append(patch)
        return patch
    }

    func setValues(_ values: [String: Any], on patch: Patch) throws {
        // Check everything first, so a mistake changes nothing.
        var resolved: [String: Value] = [:]
        for (key, raw) in values {
            guard let spec = patch.allInputs.first(where: { $0.key == key && !$0.hidden }) else {
                let keys = patch.allInputs.filter { !$0.hidden }.map(\.key)
                throw ToolError("\(patch.displayTitle) has no input \"\(key)\". Its inputs: \(keys.joined(separator: ", "))")
            }
            resolved[key] = try JSONValues.value(raw, for: spec)
            if spec.isFilePath, let path = resolved[key]?.string, !path.isEmpty { _ = try checkedImage(path) }
        }
        for (key, value) in resolved { patch.params[key] = value }
    }

    func connect(from: String, output: String, to: String, input: String) throws {
        let (src, graph) = try locate(from)
        let (dst, dstGraph) = try locate(to)
        guard graph === dstGraph else {
            throw ToolError("\(src.displayTitle) and \(dst.displayTitle) are in different graphs. Inside a macro, connect through Macro Input / Macro Output patches.")
        }
        guard let out = src.outputPorts.first(where: { $0.key == output }) else {
            throw ToolError("\(src.displayTitle) has no output \"\(output)\". Its outputs: \(src.outputPorts.map(\.key).joined(separator: ", "))")
        }
        guard let inp = dst.inputPorts.first(where: { $0.key == input }) else {
            let settings = dst.allInputs.filter { !$0.isPort && !$0.hidden }.map(\.key)
            let note = settings.contains(input) ? " (\"\(input)\" is a setting: use set_params)" : ""
            throw ToolError("\(dst.displayTitle) has no connectable input \"\(input)\"\(note). Its inputs: \(dst.inputPorts.map(\.key).joined(separator: ", "))")
        }
        guard graph.connect(from: PortRef(node: src.id, port: output), to: PortRef(node: dst.id, port: input)) else {
            throw ToolError("Can't connect a \(out.type.rawValue) output to a \(inp.type.rawValue) input")
        }
    }

    // MARK: Describing

    func describe(_ patch: Patch) -> [String: Any] {
        var out: [String: Any] = [
            "id": patch.id.uuidString, "type": patch.typeID, "title": patch.displayTitle,
            "inputs": patch.allInputs.filter { !$0.hidden }.map { spec -> [String: Any] in
                var d = JSONValues.json(spec)
                d["value"] = JSONValues.json(patch.params[spec.key] ?? spec.defaultValue, options: spec.options)
                return d
            },
            "outputs": patch.outputPorts.map(JSONValues.json),
        ]
        if let inner = patch.subgraph {
            out["contains"] = inner.nodes.map { ["id": $0.id.uuidString, "type": $0.typeID, "title": $0.displayTitle] }
        }
        return out
    }

    // MARK: Rendering

    struct Frame { var time: Double; var png: Data }

    /// Renders the composition at each time. Stateful patches (Smooth, Integrator, particle
    /// emitters…) are run for up to two seconds before each time, at 30 fps.
    func render(times: [Double], width: Int, height: Int) throws -> (frames: [Frame], problems: [String]) {
        let device = engine.device
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MetalComposerEngine.pixelFormat,
                                                            width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let target = device.makeTexture(descriptor: desc), let queue = device.makeCommandQueue() else {
            throw ToolError("Could not create a render target")
        }
        try checkImages()
        let data = try JSONEncoder().encode(root.record())
        var frames: [Frame] = []
        var problems: [String] = []
        let deadline = Date().addingTimeInterval(Self.renderTimeLimit)
        for time in times {
            let player = try CompositionPlayer(engine: engine, data: data, baseDirectory: fileURL?.deletingLastPathComponent())
            let start = max(0, time - 2)
            let steps = Int(((time - start) * 30).rounded(.down))
            for k in 0...steps {
                guard Date() < deadline else {
                    throw ToolError("Rendering took longer than \(Int(Self.renderTimeLimit)) s and was stopped. The composition is too heavy (e.g. many Iterator passes); simplify it or render fewer times.")
                }
                let t = k == steps ? time : start + Double(k) / 30
                guard let cb = queue.makeCommandBuffer() else { throw ToolError("Could not create a command buffer") }
                player.encode(into: target, time: t, commandBuffer: cb, clearAlpha: 1)
                if k == steps, desc.storageMode == .managed, let blit = cb.makeBlitCommandEncoder() {
                    blit.synchronize(resource: target)
                    blit.endEncoding()
                }
                cb.commit()
                if k == steps { cb.waitUntilCompleted() }
            }
            frames.append(Frame(time: time, png: try Self.png(target)))
            for p in player.problems where !problems.contains(p) { problems.append(p) }
        }
        return (frames, problems)
    }

    private static func png(_ texture: MTLTexture) throws -> Data {
        let w = texture.width, h = texture.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        // BGRA in memory, opaque.
        let image = bytes.withUnsafeMutableBytes { buffer -> CGImage? in
            CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)?
                .makeImage()
        }
        let out = NSMutableData()
        guard let image, let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            throw ToolError("Could not encode the image")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ToolError("Could not encode the image") }
        return out as Data
    }
}
