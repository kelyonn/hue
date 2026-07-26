import Foundation

// MARK: - ColorProfile

/// Which note→hue system governs color, when one applies at all.
///
/// Per CHROMESTHESIA_ENGINE.md §1.5 and §6: fixed note-color wheels (Scriabin,
/// Rimsky-Korsakov) are *idiosyncratic to one historical individual*, not a
/// scientific universal — hardcoding one as "the" synesthesia mapping is a
/// common but dishonest move. `.emotion` (the population-level, emotion-mediated
/// model from Palmer et al. 2013) is the authenticity-correct default; the
/// composer profiles are offered as opt-in, not facts.
enum ColorProfile: String, CaseIterable, Identifiable {
    case emotion         = "Emotion"
    case scriabin        = "Scriabin"
    case rimskyKorsakov  = "Rimsky-Korsakov"

    var id: String { rawValue }

    /// Compact uppercase label for the in-window Profile switcher —
    /// "Rimsky-Korsakov" is too wide for a single chrome row.
    var chromeLabel: String {
        switch self {
        case .emotion:        return "EMOTION"
        case .scriabin:       return "SCRIABIN"
        case .rimskyKorsakov: return "RIMSKY"
        }
    }

    var subtitle: String {
        switch self {
        case .emotion:        return "Population-level — key mode + timbre warmth"
        case .scriabin:       return "Composer's 1911 note-color wheel (Sabaneyev)"
        case .rimskyKorsakov: return "Composer's documented key-color associations"
        }
    }

    /// Hue offset in radians, added on top of the warm↔cool mood hue in
    /// `PerceptualMapper.map`, keyed by pitch class (0 = C … 11 = B). The
    /// literal analytic formula from the Hue.dc.html design handoff
    /// (design_handoff_hue_canvas/README.md, "Colour — OkLCh" section) —
    /// replaces the old full-hue lookup tables.
    func hueOffsetRadians(forPitchClass pc: Int) -> Float {
        switch self {
        case .emotion:
            return 0
        case .scriabin:
            let step = (pc * 7) % 12
            return Float(step) / 12 * 2 * .pi * 0.45
        case .rimskyKorsakov:
            let step = (pc * 5) % 12
            return Float(step) / 12 * 2 * .pi * 0.38
        }
    }
}

// MARK: - Note Names

enum NoteColorTables {
    static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
}
