import SwiftUI

struct InspectorView: View {
    @ObservedObject var model: EditorModel

    @State private var target: PaintTarget = .fill
    @State private var color: Color = .black
    @State private var code = ""
    @State private var opacity = 1.0
    @State private var codeError: String?

    var body: some View {
        Form {
            if let sel = model.selection {
                Section("Selection") {
                    LabeledContent("Name", value: sel.name)
                    LabeledContent("Kind", value: sel.isGroup ? "\(sel.tag) · \(sel.shapeCount) shapes" : sel.tag)
                    if let layer = sel.layer { LabeledContent("Layer", value: layer) }
                    if sel.path.count > 1 {
                        Button("Select Enclosing Group") { model.selectParent() }
                            .help("Or double-click the drawing")
                    }
                }
                Section("Colour") {
                    Picker("Paint", selection: $target) {
                        ForEach(PaintTarget.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 12) {
                        Swatch(value: current(sel))
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(describe(sel)).font(.body.monospaced())
                            if mixed(sel) { Text("Shapes differ; a new colour sets all").font(.caption).foregroundStyle(.secondary) }
                        }
                    }

                    ColorPicker("Colour wheel", selection: $color, supportsOpacity: false)

                    LabeledContent("Code") {
                        TextField("Code", text: $code, prompt: Text("#4B9CD3"))
                            .labelsHidden()
                            .font(.body.monospaced())
                            .multilineTextAlignment(.trailing)
                            .help("Hex (#4B9CD3, #4B9CD380), rgb(75 156 211), rgba(…), a CSS colour name, or none. Press Return to apply.")
                            .onSubmit(applyCode)
                    }
                    if let codeError {
                        Text(codeError).font(.caption).foregroundStyle(.red)
                    }

                    LabeledContent("Opacity") {
                        HStack {
                            Slider(value: $opacity, in: 0...1)
                            Text("\(Int((opacity * 100).rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                        }
                    }

                    Button {
                        model.setColor("none", on: target)
                    } label: {
                        Label("Make Transparent (\(target.rawValue) none)", systemImage: "circle.slash")
                    }
                }
            } else {
                Section {
                    Text("Click any shape in the drawing to select it.")
                    Text("Clicks land on the topmost painted shape; holes in compound paths click through. ⌥-click steps down to the shape underneath, double-click selects the enclosing group, Esc clears.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            if !model.palette.isEmpty {
                Section("Colours in this file") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 28), spacing: 6)], spacing: 6) {
                        ForEach(model.palette, id: \.self) { hex in
                            Button {
                                guard model.selection != nil else { return }
                                model.setColor(hex, on: target)
                            } label: {
                                Swatch(value: hex).frame(width: 28, height: 28)
                            }
                            .buttonStyle(.plain)
                            .help(hex)
                        }
                    }
                    .disabled(model.selection == nil)
                }
            }

            if let doc = model.doc {
                Section("Document") {
                    LabeledContent("Size", value: physical(doc))
                    LabeledContent("At 96 dpi", value: "\(Int(doc.width.rounded())) × \(Int(doc.height.rounded())) px")
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.selection) { _, sel in sync(sel) }
        .onChange(of: target) { _, _ in sync(model.selection) }
        .onChange(of: color) { _, newColor in
            guard let c = CSSColor(newColor), c.hex != code.uppercased(), model.selection != nil else { return }
            code = c.hex
            codeError = nil
            model.setColor(c.hex, on: target)
        }
        .onChange(of: opacity) { _, value in
            guard let sel = model.selection else { return }
            let now = target == .fill ? sel.fillOpacity : sel.strokeOpacity
            if abs(now - value) > 0.0005 { model.setOpacity(value, on: target) }
        }
    }

    private func current(_ sel: SelectionInfo) -> String { target == .fill ? sel.fill : sel.stroke }
    private func mixed(_ sel: SelectionInfo) -> Bool { target == .fill ? sel.mixedFill : sel.mixedStroke }

    private func describe(_ sel: SelectionInfo) -> String {
        let value = current(sel)
        let op = target == .fill ? sel.fillOpacity : sel.strokeOpacity
        return op < 1 && value != "none" ? "\(value) @ \(Int((op * 100).rounded()))%" : value
    }

    private func physical(_ doc: DocInfo) -> String {
        let f: (Double) -> String = { $0.formatted(.number.precision(.fractionLength(0...2))) }
        return "\(f(doc.physWidth)) × \(f(doc.physHeight)) \(doc.unit)"
    }

    /// Pulls the selection's current paint into the controls without writing it back.
    private func sync(_ sel: SelectionInfo?) {
        guard let sel else { return }
        let value = current(sel)
        opacity = target == .fill ? sel.fillOpacity : sel.strokeOpacity
        codeError = nil
        if let c = CSSColor(parsing: value) {
            code = c.hex
            color = c.color
        } else {
            code = value
        }
    }

    private func applyCode() {
        let input = code.trimmingCharacters(in: .whitespaces)
        if ["none", "transparent"].contains(input.lowercased()) {
            model.setColor("none", on: target)
            codeError = nil
            return
        }
        Task {
            var parsed = CSSColor(parsing: input)
            if parsed == nil { parsed = await model.normalize(input) }
            guard let c = parsed else {
                codeError = "Not a colour. Try #4B9CD3, rgb(75 156 211), or a CSS name."
                return
            }
            codeError = nil
            code = c.hex
            color = c.color
            model.setColor(c.hex, on: target)
            if c.alpha < 1 {
                opacity = c.alpha
                model.setOpacity(c.alpha, on: target)
            }
        }
    }
}

/// A colour chip; "none" shows a red slash, anything unparseable a grey "?".
struct Swatch: View {
    let value: String
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        ZStack {
            if let c = CSSColor(parsing: value) {
                shape.fill(c.color)
            } else if value == "none" {
                shape.fill(.white)
                GeometryReader { g in
                    Path { p in
                        p.move(to: CGPoint(x: g.size.width - 3, y: 3))
                        p.addLine(to: CGPoint(x: 3, y: g.size.height - 3))
                    }
                    .stroke(.red, lineWidth: 2)
                }
            } else {
                shape.fill(.quaternary)
                Text("?").foregroundStyle(.secondary)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.secondary.opacity(0.5)))
    }
}
