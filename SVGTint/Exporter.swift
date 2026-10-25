import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

enum ExportFormat: String, CaseIterable, Identifiable {
    case png, jpeg, gif, tiff, heic, bmp, pdf

    var id: String { rawValue }

    var label: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .gif: "GIF"
        case .tiff: "TIFF"
        case .heic: "HEIC"
        case .bmp: "BMP"
        case .pdf: "PDF (vector)"
        }
    }

    var type: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .gif: .gif
        case .tiff: .tiff
        case .heic: .heic
        case .bmp: .bmp
        case .pdf: .pdf
        }
    }

    var supportsTransparency: Bool { ![.jpeg, .bmp].contains(self) }
    var hasQuality: Bool { [.jpeg, .heic].contains(self) }
}

struct ExportSettings {
    var format: ExportFormat
    var width: Int
    var height: Int
    var dpi: Double
    /// nil = transparent
    var background: CSSColor?
    var quality: Double
}

enum Exporter {
    @MainActor
    static func export(_ model: EditorModel, _ s: ExportSettings, to url: URL) async throws {
        await model.flush()
        let bg = (s.format.supportsTransparency ? s.background : (s.background ?? CSSColor(r: 255, g: 255, b: 255)))
        if s.format == .pdf {
            // Page size follows the DPI, so a 96 dpi export of a mm document prints at true size.
            let w = Double(s.width) * 72 / s.dpi, h = Double(s.height) * 72 / s.dpi
            let svg = try await model.svgMarkup(width: w, height: h)
            let data = try await PDFRenderer().render(svg: svg, width: w, height: h, background: bg?.hex)
            try data.write(to: url, options: .atomic)
            return
        }
        let png = try await model.pngData(width: s.width, height: s.height, background: bg?.hex)
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if s.format == .png && s.dpi == 72 {
            try png.write(to: url, options: .atomic)
            return
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, s.format.type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnsupportedScheme)
        }
        var props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: s.dpi,
            kCGImagePropertyDPIHeight: s.dpi,
        ]
        if s.format.hasQuality { props[kCGImageDestinationLossyCompressionQuality] = s.quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}

/// Loads the SVG into an offscreen web view at page size and prints it to a vector PDF.
@MainActor
private final class PDFRenderer: NSObject, WKNavigationDelegate {
    private var loaded: CheckedContinuation<Void, Error>?

    func render(svg: String, width: Double, height: Double, background: String?) async throws -> Data {
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{margin:0;padding:0;overflow:hidden;background:\(background ?? "transparent")}
        svg{display:block}
        </style></head><body>\(svg)</body></html>
        """
        try await withCheckedThrowingContinuation { cont in
            loaded = cont
            view.loadHTMLString(html, baseURL: nil)
        }
        let config = WKPDFConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: width, height: height)
        return try await view.pdf(configuration: config)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume(); loaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error); loaded = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error); loaded = nil
    }
}
