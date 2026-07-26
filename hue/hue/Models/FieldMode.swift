import Foundation

// MARK: - FieldMode

/// Which velocity-field behavior drives the dye simulation — the three
/// "fields" from the Hue.dc.html design handoff
/// (design_handoff_hue_canvas/README.md, "Velocity field — the three fields").
enum FieldMode: String, CaseIterable, Identifiable {
    /// Ink loosed in still water — free curl-noise drift, no axis or centre.
    case diffuse = "Diffuse"
    /// Laminar veils rising through the field — pitch height reads as altitude.
    case ascend  = "Ascend"
    /// Pressure outward from the centre — beats push a ring of dye outward.
    case radiate = "Radiate"

    var id: String { rawValue }

    /// Index passed to the shader's `mode` uniform (0/1/2), matching
    /// `hue-engine.js`'s `uMode` branches.
    var shaderIndex: Int {
        switch self {
        case .diffuse: return 0
        case .ascend:  return 1
        case .radiate: return 2
        }
    }
}
