import SwiftUI

struct EditorView: View {
    @Binding var document: SVGDocument
    let fileURL: URL?

    @StateObject private var model = EditorModel()
    @State private var showInspector = true
    @State private var showExport = false
    @State private var treeSelection: [Int]?

    var body: some View {
        NavigationSplitView {
            List(model.doc?.tree ?? [], children: \.children, selection: $treeSelection) { node in
                Label {
                    Text(node.name).lineLimit(1)
                } icon: {
                    TreeIcon(node: node)
                }
                .tag(node.path)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 200)
        } detail: {
            ZStack {
                WebCanvas(webView: model.webView)
                if let error = model.loadError {
                    ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
                }
            }
            .inspector(isPresented: $showInspector) {
                InspectorView(model: model)
                    .inspectorColumnWidth(min: 260, ideal: 290, max: 400)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("Background", selection: $model.background) {
                    ForEach(CanvasBackground.allCases) { Text($0.label).tag($0) }
                }
                .help("Canvas background (not saved)")
                Button { model.zoom(by: 1 / 1.25) } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                Button { model.zoomToFit() } label: { Label("Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
                Button { model.zoom(by: 1.25) } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                Button { showExport = true } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.doc == nil)
                Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
            }
        }
        .sheet(isPresented: $showExport) {
            ExportView(model: model, sourceURL: fileURL)
        }
        .onAppear {
            let doc = $document
            model.onEdit = { doc.wrappedValue.text = $0 }
            model.show(document.text)
        }
        // Undo/Revert change the text from outside the page; show it again.
        .onChange(of: document.text) { _, text in
            if text != model.shownText { model.show(text) }
        }
        .onChange(of: treeSelection) { _, path in
            if path != model.selection?.path { model.select(path: path) }
        }
        .onChange(of: model.selection?.path) { _, path in
            if path != treeSelection { treeSelection = path }
        }
    }
}

private struct TreeIcon: View {
    let node: TreeNode
    var body: some View {
        if node.layer {
            Image(systemName: "square.3.layers.3d")
        } else if node.children != nil {
            Image(systemName: "folder")
        } else if let swatch = node.swatch, let c = CSSColor(parsing: swatch) {
            RoundedRectangle(cornerRadius: 3).fill(c.color)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(0.5)))
                .frame(width: 13, height: 13)
        } else {
            Image(systemName: "scribble")
        }
    }
}
