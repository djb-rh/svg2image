import AppKit
import UniformTypeIdentifiers

/// Finder's "open with" default for .svg files.
enum DefaultHandler {
    private static let dontAskKey = "DontOfferDefaultHandler"

    static var currentHandler: URL? {
        NSWorkspace.shared.urlForApplication(toOpen: .svg)
    }

    static var isDefault: Bool {
        guard let url = currentHandler else { return false }
        return Bundle(url: url)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    static func offerIfNeeded() {
        guard !isDefault, !UserDefaults.standard.bool(forKey: dontAskKey) else { return }
        let alert = NSAlert()
        alert.messageText = "Open SVG files with SVG Tint?"
        alert.informativeText = "Double-clicking an .svg file in Finder will open it here"
            + (currentHandler.map { " instead of in \(appName($0))" } ?? "")
            + ". You can change this later from the SVG Tint menu."
        alert.addButton(withTitle: "Make Default")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again"
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: dontAskKey)
        }
        if response == .alertFirstButtonReturn {
            makeDefault(confirm: false)
        }
    }

    static func makeDefault(confirm: Bool = true) {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: .svg) { error in
            DispatchQueue.main.async {
                guard confirm || error != nil else { return }
                let alert = NSAlert()
                if let error {
                    alert.alertStyle = .warning
                    alert.messageText = "Couldn’t change the default app"
                    alert.informativeText = error.localizedDescription
                } else {
                    alert.messageText = "SVG Tint now opens SVG files"
                    alert.informativeText = "Double-click any .svg in Finder to open it here."
                }
                alert.runModal()
            }
        }
    }

    private static func appName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
