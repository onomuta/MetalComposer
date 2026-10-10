import Foundation
import MetalComposerKit

/// The tools the server offers (ADR 0001, step 1), and their dispatch.
final class ToolBox {
    private let session: Session
    /// Settings and activity shared with the Mirage MCP app; nil to use neither (tests).
    private let support: SupportFiles?

    init(session: Session, support: SupportFiles?) {
        self.session = session
        self.support = support
    }

    // MARK: Definitions

    private static func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }

    private static let id: [String: Any] = ["type": "string", "description": "A patch ID (or a unique start of one, 4+ characters)."]

    static let definitions: [[String: Any]] = [
        [
            "name": "list_patches",
            "description": "Lists the patch types. Without `types`: type, title, category and summary of each (filter with `query`). With `types`: their inputs (key, name, type, default, range, menu options; `setting: true` means set it with set_params, it can't be connected) and outputs.",
            "inputSchema": object([
                "query": ["type": "string", "description": "Only types whose title, type or summary contains this."],
                "types": ["type": "array", "items": ["type": "string"], "description": "Type IDs (or titles) to describe in full."],
            ]),
        ],
        [
            "name": "new_composition",
            "description": "Starts a new, empty composition (discarding the current one, unsaved). By default it contains a black Clear, which draws the background; its ID is returned.",
            "inputSchema": object(["clear": ["type": "boolean", "description": "Add a black Clear (default true)."]]),
        ],
        [
            "name": "add_patch",
            "description": "Adds a patch and returns its ID, inputs (with current values) and outputs. Consumers draw in the order they are added. Macros (macro, iterator, render-in-image, 3d-transformation) can contain patches: pass their ID as `parent`.",
            "inputSchema": object([
                "type": ["type": "string", "description": "Type ID from list_patches, e.g. \"billboard\" (a title works too)."],
                "parent": ["type": "string", "description": "ID of the macro to add it inside. Default: the top level."],
                "name": ["type": "string", "description": "A name shown on the patch."],
                "x": ["type": "number", "description": "Position in the editor (layout only)."],
                "y": ["type": "number", "description": "Position in the editor (layout only)."],
                "values": ["type": "object", "description": "Input values to set, by key (as in set_params)."],
            ], required: ["type"]),
        ],
        [
            "name": "connect",
            "description": "Connects an output to an input (replacing what was connected to that input). Both patches must be in the same graph. Number, boolean, color and string convert into each other where it makes sense.",
            "inputSchema": object([
                "from": id, "output": ["type": "string", "description": "Output key of `from`."],
                "to": id, "input": ["type": "string", "description": "Input key of `to`."],
            ], required: ["from", "output", "to", "input"]),
        ],
        [
            "name": "set_params",
            "description": "Sets input values of a patch. Numbers, booleans and strings as JSON; colors as [r, g, b, a] from 0 to 1 or \"#RRGGBB\"; menus by option name or index. Values of connected inputs are used again when disconnected.",
            "inputSchema": object([
                "patch": id,
                "values": ["type": "object", "description": "Values by input key."],
            ], required: ["patch", "values"]),
        ],
        [
            "name": "render",
            "description": "Renders the composition and returns PNG images, one per time, plus any problems (shader errors, missing images…). Image Importer files must be in the composition's folder (after saving) or a folder the user allowed. A render that takes over 15 s is stopped.",
            "inputSchema": object([
                "times": ["type": "array", "items": ["type": "number"], "description": "Times in seconds (default [1]). At most 8."],
                "width": ["type": "integer", "description": "Default 640, at most 1920."],
                "height": ["type": "integer", "description": "Default 360, at most 1920."],
            ]),
        ],
        [
            "name": "save_composition",
            "description": "Saves the composition as a .mcomp file (the extension is added if missing). Open it in Mirage Composer to edit it by hand.",
            "inputSchema": object([
                "path": ["type": "string", "description": "File path ending in .mcomp (added if there is no extension); ~ is expanded."],
                "overwrite": ["type": "boolean", "description": "Replace an existing .mcomp file (default false)."],
            ], required: ["path"]),
        ],
    ]

    // MARK: Dispatch

    /// Runs a tool. Failures come back as a tool result with `isError`, so the model can fix the call.
    /// The app's settings are read first: while AI access is paused (or the settings can't be read),
    /// every call is refused. Each call is added to the activity record.
    func call(name: String, arguments: [String: Any]) -> [String: Any] {
        let (settings, problem) = support?.loadSettings() ?? (SupportFiles.Settings(), nil)
        var entry = SupportFiles.Entry(time: Date(), process: ProcessInfo.processInfo.processIdentifier, tool: name,
                                       arguments: SupportFiles.summarize(arguments), ok: false, message: "",
                                       thumbnails: [], saved: nil)
        defer { support?.record(entry) }
        if settings.paused {
            entry.message = problem ?? "AI access is paused in the Mirage MCP app."
            return ["content": [Self.text(entry.message)], "isError": true]
        }
        session.settingsImageFolders = settings.imageFolders.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        do {
            let content = try run(name, arguments)
            entry.ok = true
            let texts = content.compactMap { $0["text"] as? String }
            entry.message = String((texts.last ?? "").prefix(200))
            if let support {
                entry.thumbnails = content.compactMap { item in
                    guard item["type"] as? String == "image", let b64 = item["data"] as? String,
                          let png = Data(base64Encoded: b64) else { return nil }
                    return support.thumbnail(of: png)
                }
            }
            if name == "save_composition", let saved = session.fileURL { entry.saved = saved.path }
            return ["content": content, "isError": false]
        } catch {
            entry.message = String("\(error)".prefix(300))
            return ["content": [Self.text("\(error)")], "isError": true]
        }
    }

    private static func text(_ s: String) -> [String: Any] { ["type": "text", "text": s] }

    private static func json(_ object: Any) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return text(String(decoding: data, as: UTF8.self))
    }

    private func run(_ name: String, _ a: [String: Any]) throws -> [[String: Any]] {
        switch name {
        case "list_patches":
            if let types = a["types"] as? [String] {
                return [Self.json(try types.map { name -> [String: Any] in
                    let type = try Session.patchType(name)
                    var d = session.describe(type.init())
                    d["id"] = nil
                    d["summary"] = type.summary
                    d["category"] = type.category.rawValue
                    return d
                })]
            }
            let query = (a["query"] as? String)?.lowercased()
            let list = PatchRegistry.all.filter { t in
                guard !Session.unavailableTypes.contains(t.typeID) else { return false }
                guard let query, !query.isEmpty else { return true }
                return [t.typeID, t.title, t.summary].contains { $0.lowercased().contains(query) }
            }
            return [Self.json(list.map { ["type": $0.typeID, "title": $0.title, "category": $0.category.rawValue,
                                          "section": $0.librarySection, "summary": $0.summary] })]

        case "new_composition":
            let clear = session.newComposition(withClear: a["clear"] as? Bool ?? true)
            return [Self.json(clear.map { ["clear": $0.id.uuidString] } ?? [String: Any]())]

        case "add_patch":
            guard let type = a["type"] as? String else { throw ToolError("`type` is required") }
            let patch = try session.addPatch(type: type, parent: a["parent"] as? String, name: a["name"] as? String,
                                             x: (a["x"] as? NSNumber)?.doubleValue, y: (a["y"] as? NSNumber)?.doubleValue,
                                             values: a["values"] as? [String: Any] ?? [:])
            return [Self.json(session.describe(patch))]

        case "connect":
            guard let from = a["from"] as? String, let output = a["output"] as? String,
                  let to = a["to"] as? String, let input = a["input"] as? String
            else { throw ToolError("`from`, `output`, `to` and `input` are required") }
            try session.connect(from: from, output: output, to: to, input: input)
            return [Self.text("Connected.")]

        case "set_params":
            guard let id = a["patch"] as? String, let values = a["values"] as? [String: Any] else {
                throw ToolError("`patch` and `values` are required")
            }
            let patch = try session.locate(id).patch
            try session.setValues(values, on: patch)
            let changed = values.keys.sorted().reduce(into: [String: Any]()) { out, key in
                let spec = patch.allInputs.first { $0.key == key }
                out[key] = JSONValues.json(patch.params[key] ?? .number(0), options: spec?.options)
            }
            return [Self.json(changed)]

        case "render":
            let times = (a["times"] as? [NSNumber])?.map(\.doubleValue) ?? [1]
            guard (1...8).contains(times.count), times.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                throw ToolError("`times` needs 1 to 8 times, 0 or more seconds")
            }
            let width = min(max((a["width"] as? NSNumber)?.intValue ?? 640, 16), 1920)
            let height = min(max((a["height"] as? NSNumber)?.intValue ?? 360, 16), 1920)
            let (frames, problems) = try session.render(times: times, width: width, height: height)
            var content: [[String: Any]] = []
            for f in frames {
                content.append(Self.text("t = \(f.time) s"))
                content.append(["type": "image", "mimeType": "image/png", "data": f.png.base64EncodedString()])
            }
            content.append(Self.text(problems.isEmpty ? "No problems." : "Problems:\n" + problems.joined(separator: "\n")))
            return content

        case "save_composition":
            guard let path = a["path"] as? String else { throw ToolError("`path` is required") }
            return [Self.text("Saved to \(try session.save(to: path, overwrite: a["overwrite"] as? Bool ?? false).path)")]

        default:
            throw ToolError("Unknown tool \(name)")
        }
    }
}
