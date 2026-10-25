import SwiftUI
import AppKit

struct ExportView: View {
    @ObservedObject var model: EditorModel
    let sourceURL: URL?

    private var baseName: String { sourceURL?.deletingPathExtension().lastPathComponent ?? "Untitled" }

    @Environment(\.dismiss) private var dismiss
    @AppStorage("exportFormat") private var format: ExportFormat = .png
    @AppStorage("exportDPI") private var dpi = 96.0
    @AppStorage("exportQuality") private var quality = 0.9
    @AppStorage("exportTransparent") private var transparent = true
    @State private var width = 0
    @State private var height = 0
    @State private var background: Color = .white
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case width, height }
    private static let maxSide = 16384

    private var aspect: Double {
        guard let doc = model.doc, doc.height > 0 else { return 1 }
        return doc.width / doc.height
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Picker("Format", selection: $format) {
                    ForEach(ExportFormat.allCases) { Text($0.label).tag($0) }
                }

                Section {
                    LabeledContent("Width") {
                        HStack {
                            TextField("Width", value: $width, format: .number.grouping(.never))
                                .labelsHidden()
                                .focused($focus, equals: .width)
                                .frame(width: 90)
                            Text("px").foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Height") {
                        HStack {
                            TextField("Height", value: $height, format: .number.grouping(.never))
                                .labelsHidden()
                                .focused($focus, equals: .height)
                                .frame(width: 90)
                            Text("px").foregroundStyle(.secondary)
                            Image(systemName: "lock.fill").foregroundStyle(.secondary)
                                .help("Aspect ratio is locked to the drawing")
                        }
                    }
                    LabeledContent("Quick sizes") {
                        HStack {
                            ForEach([512, 1024, 2048, 4096], id: \.self) { side in
                                Button("\(side)") { setLongSide(side) }
                            }
                        }
                        .controlSize(.small)
                    }
                    LabeledContent("Resolution") {
                        HStack {
                            TextField("DPI", value: $dpi, format: .number.grouping(.never))
                                .labelsHidden()
                                .frame(width: 60)
                            Text("dpi").foregroundStyle(.secondary)
                            if let doc = model.doc, doc.unit != "px" {
                                Button("Actual size") { setActualSize(doc) }
                                    .controlSize(.small)
                                    .help("Pixels for the drawing’s real \(doc.unit) size at this dpi")
                            }
                        }
                    }
                    if let doc = model.doc {
                        Text(printSize(doc)).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    if format.supportsTransparency {
                        Toggle("Transparent background", isOn: $transparent)
                    } else {
                        Text("\(format.label) has no transparency, so a background colour is filled in.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !format.supportsTransparency || !transparent {
                        ColorPicker("Background colour", selection: $background, supportsOpacity: false)
                    }
                    if format.hasQuality {
                        LabeledContent("Quality") {
                            HStack {
                                Slider(value: $quality, in: 0.1...1)
                                Text("\(Int((quality * 100).rounded()))%").monospacedDigit().frame(width: 40)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            if let error {
                Text(error).foregroundStyle(.red).font(.callout).padding(.horizontal, 20)
            }

            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") { export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || !valid)
            }
            .padding(20)
        }
        .frame(width: 440)
        .onAppear {
            if let doc = model.doc {
                width = max(1, Int(doc.width.rounded()))
                height = max(1, Int(doc.height.rounded()))
            }
        }
        // Only the field being typed in drives the other, so rounding never ping-pongs.
        .onChange(of: width) { _, w in
            if focus != .height { height = max(1, Int((Double(w) / aspect).rounded())) }
        }
        .onChange(of: height) { _, h in
            if focus == .height { width = max(1, Int((Double(h) * aspect).rounded())) }
        }
    }

    private var valid: Bool {
        width > 0 && height > 0 && width <= Self.maxSide && height <= Self.maxSide && dpi > 0
    }

    private func setLongSide(_ side: Int) {
        focus = nil
        if aspect >= 1 { width = side; height = max(1, Int((Double(side) / aspect).rounded())) }
        else { height = side; width = max(1, Int((Double(side) * aspect).rounded())) }
    }

    private func setActualSize(_ doc: DocInfo) {
        focus = nil
        let inches = doc.width / 96   // doc.width is CSS px, 96 per inch
        width = max(1, Int((inches * dpi).rounded()))
        height = max(1, Int((Double(width) / aspect).rounded()))
    }

    private func printSize(_ doc: DocInfo) -> String {
        guard dpi > 0 else { return "" }
        let wmm = Double(width) / dpi * 25.4, hmm = Double(height) / dpi * 25.4
        let f: (Double) -> String = { $0.formatted(.number.precision(.fractionLength(1))) }
        var s = "Prints at \(f(wmm)) × \(f(hmm)) mm (\(f(wmm / 25.4)) × \(f(hmm / 25.4)) in) at \(Int(dpi)) dpi."
        if width > Self.maxSide || height > Self.maxSide { s += " Largest side is \(Self.maxSide) px." }
        return s
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = "\(baseName).\(format.type.preferredFilenameExtension ?? format.rawValue)"
        panel.canCreateDirectories = true
        panel.directoryURL = sourceURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let settings = ExportSettings(format: format, width: width, height: height, dpi: dpi,
                                      background: (format.supportsTransparency && transparent) ? nil : CSSColor(background),
                                      quality: quality)
        busy = true
        error = nil
        Task {
            do {
                try await Exporter.export(model, settings, to: url)
                busy = false
                dismiss()
            } catch {
                busy = false
                self.error = "Export failed: \(error.localizedDescription)"
            }
        }
    }
}
