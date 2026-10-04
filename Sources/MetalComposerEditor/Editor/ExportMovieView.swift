import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MetalComposerKit

/// Sheet for File › Export Movie: settings, then progress, then the result.
struct ExportMovieView: View {
    @ObservedObject var exporter: MovieExporter
    /// Asks for a destination and starts the export.
    var onExport: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Movie").font(.title2.weight(.semibold))
            switch exporter.state {
            case .exporting(let frame, let total):
                progress(frame: frame, total: total)
            case .finished(let url):
                finished(url)
            default:
                form
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    // MARK: Settings

    private var presetSelection: Binding<String> {
        Binding(
            get: {
                let s = exporter.settings
                return MovieSettings.presets.first { $0.width == s.width && $0.height == s.height }?.name ?? "Custom"
            },
            set: { name in
                guard let p = MovieSettings.presets.first(where: { $0.name == name }) else { return }
                exporter.settings.width = p.width
                exporter.settings.height = p.height
            })
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Form {
                LabeledContent("Duration") {
                    HStack {
                        TextField("", value: $exporter.settings.duration, format: .number.precision(.fractionLength(0...2)))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                        Text("seconds").foregroundStyle(.secondary)
                    }
                }
                Picker("Resolution", selection: presetSelection) {
                    ForEach(MovieSettings.presets, id: \.name) { p in
                        Text(verbatim: "\(p.name)  (\(p.width)×\(p.height))").tag(p.name)
                    }
                    Text("Custom").tag("Custom")
                }
                LabeledContent("Size") {
                    HStack(spacing: 4) {
                        TextField("", value: $exporter.settings.width, format: .number.grouping(.never))
                            .multilineTextAlignment(.trailing).frame(width: 64)
                        Text("×")
                        TextField("", value: $exporter.settings.height, format: .number.grouping(.never))
                            .multilineTextAlignment(.trailing).frame(width: 64)
                        Text("px").foregroundStyle(.secondary)
                    }
                }
                Picker("Frame Rate", selection: $exporter.settings.fps) {
                    ForEach(MovieSettings.frameRates, id: \.self) { Text(verbatim: "\($0) fps").tag($0) }
                }
                Picker("Codec", selection: $exporter.settings.codec) {
                    ForEach(MovieSettings.Codec.allCases) { Text($0.rawValue).tag($0) }
                }
                if exporter.settings.codec.usesBitrate {
                    Picker("Quality", selection: $exporter.settings.quality) {
                        ForEach(MovieSettings.Quality.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: exporter.settings.codec.usesBitrate ? 290 : 250)

            Text(summary).font(.callout).foregroundStyle(.secondary)
            Text("Rendered offline from t = 0 at exact frame times, so it never drops frames. The mouse stays at the center.")
                .font(.caption).foregroundStyle(.tertiary)

            switch exporter.state {
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            case .cancelled:
                Label("Export cancelled.", systemImage: "xmark.circle").foregroundStyle(.secondary).font(.callout)
            default:
                EmptyView()
            }

            HStack {
                Spacer()
                Button("Cancel") { exporter.resetState(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { onExport() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var summary: String {
        let s = exporter.settings.normalized
        var parts = ["\(s.width)×\(s.height)", "\(s.fps) fps", "\(s.frameCount) frames"]
        if s.width != exporter.settings.width || s.height != exporter.settings.height {
            parts[0] += " (adjusted for the codec)"
        }
        if let bytes = exporter.settings.estimatedBytes {
            parts.append("about " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Progress & result

    private func progress(frame: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: Double(frame), total: Double(max(total, 1)))
            Text(verbatim: "Rendering frame \(frame) of \(total)…").monospacedDigit().foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Stop") { exporter.cancel() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    private func finished(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Saved \(url.lastPathComponent)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            HStack {
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Done") { exporter.resetState(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}
