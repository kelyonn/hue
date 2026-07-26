/*
 Copyright © 2026 kelyonn. All rights reserved.

 This file is part of Hue. See the LICENSE at the repository root.
 Unauthorized copying, modification, or reuse in another product is prohibited.
*/
import Foundation
import SwiftUI

// MARK: - PerceptualColor

/// A target color in OkLCh — the cylindrical form of Oklab, a perceptually
/// uniform color space. `L` (lightness) and `C` (chroma) here mean what they
/// perceptually say, unlike HSL's "lightness," which is a raw RGB average and
/// does not track perceived brightness. That distinction matters because §1.1
/// of CHROMESTHESIA_ENGINE.md makes pitch→lightness the backbone of the whole
/// mapping — if "lightness" doesn't mean lightness, the one universal law breaks.
struct PerceptualColor {
    var L: Float          // 0...1
    var C: Float          // 0...~0.33 (sRGB-representable range)
    var h: Float          // radians, [0, 2π)

    /// Swift-side twin of `oklch_to_linear_srgb` in `Renderer/OklabColor.h`,
    /// for views that need to render the mapped color directly (diagnostic
    /// HUD swatch, flat-color test mode) without going through Metal. Keep
    /// this matrix in sync with that header if either ever changes.
    var swiftUIColor: Color {
        let a = C * cos(h)
        let b = C * sin(h)

        let l_ = L + 0.3963377774 * a + 0.2158037573 * b
        let m_ = L - 0.1055613458 * a - 0.0638541728 * b
        let s_ = L - 0.0894841775 * a - 1.2914855480 * b

        let l = l_ * l_ * l_
        let m = m_ * m_ * m_
        let s = s_ * s_ * s_

        let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let bl = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s

        // Gamma-encode to match Composite.metal's final pow(x, 0.4545) step,
        // so this swatch looks like what the shader would render for the
        // same (L, C, h) — clamped, not tonemapped, since this is meant as
        // ground truth for "what did the mapper actually compute," not a
        // preview of fluid-accumulated brightness.
        func gammaEncode(_ x: Float) -> Double {
            Double(pow(max(0, min(1, x)), Float(0.4545)))
        }
        return Color(red: gammaEncode(r), green: gammaEncode(g), blue: gammaEncode(bl))
    }
}

// MARK: - PerceptualMapper

/// The perceptual mapping layer between `AudioProcessor` (measured features)
/// and `MetalRenderer` (GPU color). Implements the **literal** color formula
/// from the Hue.dc.html design handoff
/// (design_handoff_hue_canvas/README.md, "Colour — OkLCh" section, ported
/// directly from `hue-engine.js`'s `SIM_FS`) — not an independently-tuned
/// variant. Runs once per frame on the CPU; the result is packed into the GPU
/// audio buffer, where the shader converts OkLCh → linear sRGB as the final step.
enum PerceptualMapper {

    /// sRGB-safe chroma ceiling. The design's own `C` formula already tops out
    /// near 0.255 * 1.0 * 1.0 * 1.2 ≈ 0.31 at the extreme, so this mostly
    /// guards against edge cases rather than doing real clamping work.
    private static let chromaCeiling: Float = 0.33

    static func map(features: AudioFeatures, profile: ColorProfile) -> PerceptualColor {
        let centroid = clamp01(features.spectralCentroid)
        let rms      = clamp01(features.rms)
        let arousal  = clamp01(features.arousal)

        // `AudioFeatures.valence` is already defined (AudioFeatures.swift) as
        // 0...1 — 0 = sad/minor, 1 = happy/major, confidence-weighted around
        // 0.5 — which is exactly the quantity the design calls `valence01`
        // (its own raw `valence` is -1...1; `valence01 = 0.5 + 0.5*valence`
        // derives the same 0...1 value). No further remap needed here.
        let valence01 = clamp01(features.valence)

        return color(
            centroid: centroid,
            valence01: valence01,
            arousal: arousal,
            rms: rms,
            hueOffset: profile.hueOffsetRadians(forPitchClass: features.dominantPitchClass)
        )
    }

    /// The literal design color formula, isolated from `AudioFeatures` so the
    /// in-app explainer (`InfoOverlay`'s legend) can render swatches from the
    /// exact same math the renderer uses, rather than hand-picked colors that
    /// could drift away from what the field actually paints.
    static func color(
        centroid: Float,
        valence01: Float,
        arousal: Float,
        rms: Float,
        hueOffset: Float = 0
    ) -> PerceptualColor {
        // ── L, warmCool, h, C — literal design formula ──
        let L = clamp01(0.40 + 0.46 * centroid + 0.16 * rms)

        let warmCool = 0.6 * centroid + 0.4 * valence01
        // Literal linear lerp 250°(blue) → 60°(yellow) — matches
        // hue-engine.js's `mix(4.3633, 1.0472, warmCool)` exactly. (Earlier
        // revisions of this mapper deliberately routed the *other* way around
        // the wheel to avoid crossing green at the midpoint; the design
        // handoff specifies the direct lerp, so that's what ships.)
        let moodHueDegrees = 250 + (60 - 250) * warmCool
        let h = wrapRadians(moodHueDegrees * .pi / 180 + hueOffset)

        let C = clamp(
            0.255 * (0.4 + 0.6 * valence01) * (0.5 + 0.5 * arousal) * (1.2 - 0.4 * centroid),
            0, chromaCeiling
        )

        return PerceptualColor(L: L, C: C, h: h)
    }

    // MARK: - Helpers

    private static func clamp01(_ v: Float) -> Float { min(1, max(0, v)) }
    private static func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float { min(hi, max(lo, v)) }
    private static func wrapRadians(_ r: Float) -> Float {
        let twoPi: Float = 2 * .pi
        let m = r.truncatingRemainder(dividingBy: twoPi)
        return m < 0 ? m + twoPi : m
    }
}
