import SwiftUI
import Combine

// MARK: - ColorProfileStore

/// Holds the user's selected note→color profile (§6 of CHROMESTHESIA_ENGINE.md)
/// and field mode (design_handoff_hue_canvas/README.md). Owned once at the
/// app level and read every frame by `MetalRenderer` (weakly, same pattern as
/// `AudioProcessor`) to drive `PerceptualMapper` and the field shader.
///
/// Both `profile` and `field` persist across launches — the only state this
/// app persists at all, per the design handoff's "State" section.
final class ColorProfileStore: ObservableObject {

    private enum DefaultsKey {
        static let profile = "hue.colorProfile"
        static let field = "hue.fieldMode"
    }

    @Published var profile: ColorProfile {
        didSet { UserDefaults.standard.set(profile.rawValue, forKey: DefaultsKey.profile) }
    }

    @Published var field: FieldMode {
        didSet { UserDefaults.standard.set(field.rawValue, forKey: DefaultsKey.field) }
    }

    init() {
        let defaults = UserDefaults.standard
        profile = defaults.string(forKey: DefaultsKey.profile).flatMap(ColorProfile.init(rawValue:)) ?? .emotion
        field = defaults.string(forKey: DefaultsKey.field).flatMap(FieldMode.init(rawValue:)) ?? .diffuse
    }
}
