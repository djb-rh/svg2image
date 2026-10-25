import SwiftUI

@main
struct SVG2ImageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        DocumentGroup(newDocument: SVGDocument()) { file in
            EditorView(document: file.$document, fileURL: file.fileURL)
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Make SVG2Image the Default App for SVG Files…") {
                    DefaultHandler.makeDefault()
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--export") {
            CommandLineExport.run()
            return
        }
        // Let any document windows (or the Open panel) come up first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            DefaultHandler.offerIfNeeded()
        }
    }
}
