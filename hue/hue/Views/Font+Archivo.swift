import SwiftUI

// MARK: - Font + Archivo

/// The bundled Archivo weights (see `Fonts/`, registered via
/// `Info.plist`'s `ATSApplicationFontsPath`). Google's static (non-variable)
/// build registers each weight under its **own legacy family name**
/// ("Archivo", "Archivo Medium", "Archivo SemiBold" — verified via each
/// file's `name` table) rather than one shared family + weight axis, so
/// `Font.custom("Archivo", size:).fontWeight(.medium)` cannot reliably select
/// the Medium/SemiBold files. Referencing each weight by its own exact
/// PostScript name sidesteps that entirely.
extension Font {
    enum ArchivoWeight: String {
        case regular  = "Archivo-Regular"
        case medium   = "Archivo-Medium"
        case semibold = "Archivo-SemiBold"
    }

    static func archivo(_ weight: ArchivoWeight, size: CGFloat) -> Font {
        .custom(weight.rawValue, size: size)
    }
}
