import SwiftUI
import WebKit

struct SelectionInfo: Decodable, Equatable {
    var path: [Int]
    var tag: String
    var name: String
    var layer: String?
    var isGroup: Bool
    var shapeCount: Int
    var fill: String
    var stroke: String
    var fillOpacity: Double
    var strokeOpacity: Double
    var mixedFill: Bool
    var mixedStroke: Bool
}

struct TreeNode: Decodable, Identifiable, Hashable {
    var path: [Int]
    var name: String
    var tag: String
    var layer: Bool
    var swatch: String?
    var children: [TreeNode]?
    var id: [Int] { path }
}

struct DocInfo: Decodable {
    var width: Double
    var height: Double
    var unit: String
    var physWidth: Double
    var physHeight: Double
    var tree: [TreeNode]
    var palette: [String]
}

enum PaintTarget: String, CaseIterable, Identifiable {
    case fill, stroke
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum CanvasBackground: String, CaseIterable, Identifiable {
    case checker = "", white, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .checker: "Checkerboard"
        case .white: "White"
        case .dark: "Dark"
        }
    }
}

/// Owns the WKWebView that shows the SVG and talks to editor.js.
@MainActor
final class EditorModel: NSObject, ObservableObject, WKScriptMessageHandler {
    let webView: WKWebView

    @Published private(set) var selection: SelectionInfo?
    @Published private(set) var doc: DocInfo?
    @Published private(set) var palette: [String] = []
    @Published private(set) var loadError: String?
    @Published var background: CanvasBackground = .checker {
        didSet { run("setBackground(mode)", ["mode": background.rawValue]) }
    }

    /// The text the page is showing; edits from the page update it before reaching the document.
    private(set) var shownText: String?
    var onEdit: ((String) -> Void)?

    private var pageReady = false
    private var pendingText: String?

    override init() {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        let proxy = MessageProxy(self)
        for name in ["ready", "loaded", "selected", "changed", "error"] {
            config.userContentController.add(proxy, name: name)
        }
        webView.allowsMagnification = true
        webView.setValue(false, forKey: "drawsBackground")
        let page = Bundle.main.url(forResource: "editor", withExtension: "html")!
        webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    }

    // MARK: Page → Swift

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let data = Data(((message.body as? String) ?? "null").utf8)
        let decoder = JSONDecoder()
        switch message.name {
        case "ready":
            pageReady = true
            run("setBackground(mode)", ["mode": background.rawValue])
            if let text = pendingText { pendingText = nil; show(text) }
        case "loaded":
            if let info = try? decoder.decode(DocInfo.self, from: data) {
                doc = info
                palette = info.palette
                loadError = nil
            }
        case "selected":
            selection = try? decoder.decode(SelectionInfo.self, from: data)
        case "changed":
            struct Change: Decodable { var text: String; var palette: [String]; var tree: [TreeNode] }
            guard let change = try? decoder.decode(Change.self, from: data) else { return }
            palette = change.palette
            doc?.tree = change.tree
            shownText = change.text
            onEdit?(change.text)
        case "error":
            struct Failure: Decodable { var message: String }
            loadError = (try? decoder.decode(Failure.self, from: data))?.message ?? "Couldn’t read this SVG."
        default:
            break
        }
    }

    // MARK: Swift → page

    /// Shows new text, keeping the current selection if the same element still exists.
    func show(_ text: String) {
        shownText = text
        guard pageReady else { pendingText = text; return }
        var args: [String: Any] = ["text": text]
        args["path"] = selection?.path ?? NSNull()
        run("load(text, path)", args)
    }

    func select(path: [Int]?) {
        if let path { run("selectPath(p)", ["p": path]) } else { run("select(null)") }
    }

    func selectParent() { run("selectParent()") }

    func setColor(_ value: String, on target: PaintTarget) {
        run("setColor(prop, value)", ["prop": target.rawValue, "value": value])
    }

    func setOpacity(_ value: Double, on target: PaintTarget) {
        run("setOpacity(prop, value)", ["prop": target.rawValue, "value": value])
    }

    /// Sends any edit still waiting on the page's short debounce.
    func flush() async { _ = try? await call("commit()") }

    func normalize(_ color: String) async -> CSSColor? {
        guard let rgb = try? await call("return normalizeColor(s)", ["s": color]) as? String else { return nil }
        return CSSColor(parsing: rgb)
    }

    func zoom(by factor: Double) {
        webView.setMagnification(min(max(webView.magnification * factor, 0.25), 16), centeredAt: .zero)
    }

    func zoomToFit() { webView.magnification = 1 }

    // MARK: Export helpers

    /// PNG bytes of the drawing at exactly `width` × `height` pixels.
    func pngData(width: Int, height: Int, background: String?) async throws -> Data {
        let result = try await call("return await rasterize(w, h, bg)",
                                    ["w": width, "h": height, "bg": background ?? NSNull()])
        guard let base64 = result as? String, let data = Data(base64Encoded: base64) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    /// The drawing as SVG markup with an explicit size, for the PDF renderer.
    func svgMarkup(width: Double, height: Double) async throws -> String {
        guard let s = try await call("return svgAt(w, h)", ["w": width, "h": height]) as? String else {
            throw CocoaError(.fileWriteUnknown)
        }
        return s
    }

    // MARK: Plumbing

    private func run(_ body: String, _ args: [String: Any] = [:]) {
        guard pageReady else { return }
        webView.callAsyncJavaScript(body, arguments: args, in: nil, in: .page, completionHandler: nil)
    }

    private func call(_ body: String, _ args: [String: Any] = [:]) async throws -> Any? {
        try await withCheckedThrowingContinuation { cont in
            webView.callAsyncJavaScript(body, arguments: args, in: nil, in: .page) { result in
                cont.resume(with: result.map { $0 as Any? })
            }
        }
    }
}

/// WKUserContentController holds its handlers strongly; this breaks the cycle.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}

struct WebCanvas: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
