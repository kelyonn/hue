/*
 Copyright © 2026 kelyonn. All rights reserved.

 This file is part of Hue. See the LICENSE at the repository root.
 Unauthorized copying, modification, or reuse in another product is prohibited.
*/
import XCTest
@testable import hue

/// The mapping rules from CHROMESTHESIA_ENGINE.md, checked against the formula:
/// pitch height drives lightness, mood drives hue, energy drives chroma.
final class PerceptualMapperTests: XCTestCase {

    private func color(centroid: Float = 0.5, valence: Float = 0.5,
                       arousal: Float = 0.5, rms: Float = 0.5) -> PerceptualColor {
        PerceptualMapper.color(centroid: centroid, valence01: valence, arousal: arousal, rms: rms)
    }

    func testBrighterSoundIsLighter() {
        let dark = color(centroid: 0.1)
        let bright = color(centroid: 0.9)
        XCTAssertGreaterThan(bright.L, dark.L, "pitch height → lightness is the backbone")
    }

    func testHappierSoundIsWarmer() {
        // Sad pulls toward 250° (blue), happy toward 60° (yellow).
        let sad = color(centroid: 0, valence: 0)
        let happy = color(centroid: 0, valence: 1)
        let degrees = { (c: PerceptualColor) in c.h * 180 / .pi }
        XCTAssertEqual(degrees(sad), 250, accuracy: 0.01)
        XCTAssertLessThan(degrees(happy), degrees(sad))
    }

    func testMoreEnergyIsMoreSaturated() {
        XCTAssertGreaterThan(color(arousal: 1).C, color(arousal: 0).C)
    }

    func testOutputStaysInRangeForEveryExtreme() {
        let edges: [Float] = [-5, 0, 0.5, 1, 5]
        for a in edges { for b in edges { for c in edges { for d in edges {
            let p = color(centroid: a, valence: b, arousal: c, rms: d)
            XCTAssert((0...1).contains(p.L), "L out of range: \(p.L)")
            XCTAssert((0...0.33).contains(p.C), "C out of range: \(p.C)")
            XCTAssert(p.h >= 0 && p.h < 2 * .pi, "h not wrapped: \(p.h)")
        }}}}
    }

    func testHueOffsetWrapsAroundTheWheel() {
        let p = PerceptualMapper.color(centroid: 0, valence01: 0, arousal: 0, rms: 0, hueOffset: 2 * .pi)
        XCTAssertEqual(p.h, 250 * .pi / 180, accuracy: 1e-4)
    }

    func testEmotionProfileAddsNoOffset() {
        for pc in 0..<12 {
            XCTAssertEqual(ColorProfile.emotion.hueOffsetRadians(forPitchClass: pc), 0)
        }
    }

    func testComposerProfilesGiveEachPitchClassADistinctHue() {
        for profile in [ColorProfile.scriabin, .rimskyKorsakov] {
            let offsets = Set((0..<12).map { profile.hueOffsetRadians(forPitchClass: $0) })
            XCTAssertEqual(offsets.count, 12, "\(profile) maps two notes to the same hue")
        }
    }
}
