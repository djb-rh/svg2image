import SwiftUI
import AppKit

/// An sRGB colour as SVG wants it: #RRGGBB plus a separate opacity.
struct CSSColor: Equatable {
    var r: Int, g: Int, b: Int
    var alpha: Double = 1

    var hex: String { String(format: "#%02X%02X%02X", r, g, b) }

    var color: Color {
        Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    init(r: Int, g: Int, b: Int, alpha: Double = 1) {
        self.r = r.clamped(0, 255); self.g = g.clamped(0, 255); self.b = b.clamped(0, 255)
        self.alpha = min(max(alpha, 0), 1)
    }

    init?(_ color: Color) {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(r: Int((c.redComponent * 255).rounded()),
                  g: Int((c.greenComponent * 255).rounded()),
                  b: Int((c.blueComponent * 255).rounded()),
                  alpha: Double(c.alphaComponent))
    }

    /// #RGB, #RGBA, #RRGGBB, #RRGGBBAA (the # is optional), rgb()/rgba() with
    /// commas or spaces, numbers or percentages. Anything else returns nil and the
    /// caller asks WebKit, which knows names and hsl().
    init?(parsing input: String) {
        let s = input.trimmingCharacters(in: .whitespaces).lowercased()
        if let c = CSSColor.parseHex(s) { self = c; return }
        if let c = CSSColor.parseRGB(s) { self = c; return }
        return nil
    }

    private static func parseHex(_ s: String) -> CSSColor? {
        let h = s.hasPrefix("#") ? String(s.dropFirst()) : s
        guard [3, 4, 6, 8].contains(h.count), h.allSatisfy(\.isHexDigit) else { return nil }
        let digits = h.count <= 4 ? h.map { "\($0)\($0)" }.joined() : h
        var v = [Int]()
        var i = digits.startIndex
        while i < digits.endIndex {
            let j = digits.index(i, offsetBy: 2)
            v.append(Int(digits[i..<j], radix: 16)!)
            i = j
        }
        return CSSColor(r: v[0], g: v[1], b: v[2], alpha: v.count > 3 ? Double(v[3]) / 255 : 1)
    }

    private static func parseRGB(_ s: String) -> CSSColor? {
        guard s.hasPrefix("rgb"), let open = s.firstIndex(of: "("), s.hasSuffix(")") else { return nil }
        let body = s[s.index(after: open)..<s.index(before: s.endIndex)]
        let parts = body.split(whereSeparator: { " ,/".contains($0) }).map(String.init)
        guard parts.count == 3 || parts.count == 4 else { return nil }
        func channel(_ p: String) -> Int? {
            if p.hasSuffix("%"), let v = Double(p.dropLast()) { return Int((v * 2.55).rounded()) }
            return Double(p).map { Int($0.rounded()) }
        }
        func alpha(_ p: String) -> Double? {
            if p.hasSuffix("%"), let v = Double(p.dropLast()) { return v / 100 }
            return Double(p)
        }
        guard let r = channel(parts[0]), let g = channel(parts[1]), let b = channel(parts[2]) else { return nil }
        let a = parts.count == 4 ? alpha(parts[3]) : 1
        guard let a else { return nil }
        return CSSColor(r: r, g: g, b: b, alpha: a)
    }
}

private extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.min(Swift.max(self, lo), hi) }
}
