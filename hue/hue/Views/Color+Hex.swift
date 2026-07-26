import SwiftUI

// MARK: - Color + Hex

/// Exact hex colours used by the chrome. The live field's dye is computed in
/// OkLCh by `PerceptualMapper` — these are only for UI accents and overlays.
extension Color {
    /// Soft amber accent — status dot, active underlines, section labels,
    /// permission CTA. Chosen to sit at the warm end of the chromesthesia
    /// blue→yellow path without the previous alert-red.
    static let hueAccent = Color(hex: "d4a24a")
    /// Slightly darker amber for hover states on filled buttons.
    static let hueAccentHover = Color(hex: "b8893a")

    /// - Parameter hex: `"RRGGBB"` or `"#RRGGBB"`, 6 hex digits, no alpha.
    init(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r = Double((value & 0xFF0000) >> 16) / 255
        let g = Double((value & 0x00FF00) >> 8) / 255
        let b = Double(value & 0x0000FF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
