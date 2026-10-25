import SwiftUI
import UniformTypeIdentifiers

/// The document is just the SVG text; the editor page is the only thing that changes it.
struct SVGDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.svg] }

    var text: String

    init(text: String = SVGDocument.blank) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }

    static let blank = """
    <?xml version="1.0" encoding="UTF-8"?>
    <svg xmlns="http://www.w3.org/2000/svg" width="200" height="200" viewBox="0 0 200 200">
      <rect x="10" y="10" width="180" height="180" rx="24" fill="#13294B"/>
      <circle cx="100" cy="100" r="60" fill="#4B9CD3"/>
    </svg>

    """
}
