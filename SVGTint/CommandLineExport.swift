import AppKit

/// `SVG Tint --export in.svg out.png [--width N | --height N] [--dpi 96] [--background #FFFFFF] [--quality 0.9]`
/// Uses the same renderer as the Export sheet. The format comes from the output extension.
@MainActor
enum CommandLineExport {
    static func run() {
        Task {
            do {
                try await export(Array(CommandLine.arguments.drop(while: { $0 != "--export" }).dropFirst()))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("svg-tint: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
    }

    private static func export(_ args: [String]) async throws {
        guard args.count >= 2 else { throw failure("usage: --export in.svg out.png [--width N | --height N] [--dpi D] [--background #RRGGBB] [--quality Q]") }
        let input = URL(fileURLWithPath: args[0]), output = URL(fileURLWithPath: args[1])
        var options = [String: String]()
        var i = 2
        while i + 1 < args.count { options[args[i]] = args[i + 1]; i += 2 }

        let ext = output.pathExtension.lowercased()
        guard let format = ExportFormat.allCases.first(where: { $0.type.preferredFilenameExtension == ext || $0.rawValue == ext || (ext == "jpg" && $0 == .jpeg) || (ext == "tif" && $0 == .tiff) }) else {
            throw failure("unknown output format .\(ext)")
        }

        let model = EditorModel()
        model.show(try String(contentsOf: input, encoding: .utf8))
        for _ in 0..<200 where model.doc == nil && model.loadError == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        if let error = model.loadError { throw failure(error) }
        guard let doc = model.doc else { throw failure("timed out loading \(input.lastPathComponent)") }

        let aspect = doc.width / doc.height
        var width = Int(doc.width.rounded()), height = Int(doc.height.rounded())
        if let w = options["--width"].flatMap(Int.init) { width = w; height = max(1, Int((Double(w) / aspect).rounded())) }
        else if let h = options["--height"].flatMap(Int.init) { height = h; width = max(1, Int((Double(h) * aspect).rounded())) }

        let background = options["--background"].flatMap { $0 == "none" ? nil : CSSColor(parsing: $0) }
        let settings = ExportSettings(format: format, width: width, height: height,
                                      dpi: options["--dpi"].flatMap(Double.init) ?? 96,
                                      background: background,
                                      quality: options["--quality"].flatMap(Double.init) ?? 0.9)
        try await Exporter.export(model, settings, to: output)
        print("\(output.path): \(format.label) \(width)×\(height)")
    }

    private static func failure(_ message: String) -> Error {
        NSError(domain: "SVGTint", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
