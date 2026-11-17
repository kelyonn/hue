/*
 Copyright © 2026 kelyonn. All rights reserved.

 This file is part of Hue. See the LICENSE at the repository root.
 Unauthorized copying, modification, or reuse in another product is prohibited.
*/
import XCTest
@testable import hue

/// Feeds synthetic audio through the real DSP path (ring buffer, FFT,
/// chroma, smoothing) and checks the features that come out.
final class AudioProcessorTests: XCTestCase {

    private let sampleRate: Float = 48_000

    private func sine(_ hz: Float, seconds: Float, amplitude: Float = 0.5) -> [Float] {
        let n = Int(seconds * sampleRate)
        return (0..<n).map { amplitude * sin(2 * .pi * hz * Float($0) / sampleRate) }
    }

    /// Feed in callback-sized chunks, the way ScreenCaptureKit delivers audio.
    private func run(_ samples: [Float]) -> AudioFeatures {
        let p = AudioProcessor()
        stride(from: 0, to: samples.count, by: 1024).forEach {
            p.process(Array(samples[$0..<min($0 + 1024, samples.count)]))
        }
        return p.rawLatestFeatures
    }

    func testSilenceIsSilent() {
        XCTAssertTrue(run([Float](repeating: 0, count: 48_000)).isSilent)
    }

    func testEmptyInputIsIgnored() {
        let p = AudioProcessor()
        p.process([])
        XCTAssertTrue(p.rawLatestFeatures.isSilent)
    }

    func testA440LandsOnPitchClassA() {
        XCTAssertEqual(run(sine(440, seconds: 2)).dominantPitchClass, 9)
    }

    func testMiddleCLandsOnPitchClassC() {
        XCTAssertEqual(run(sine(261.63, seconds: 2)).dominantPitchClass, 0)
    }

    func testHigherToneHasHigherCentroid() {
        let low = run(sine(110, seconds: 2))
        let high = run(sine(3_520, seconds: 2))
        XCTAssertGreaterThan(high.spectralCentroid, low.spectralCentroid)
    }

    func testLouderToneHasHigherRMS() {
        let quiet = run(sine(440, seconds: 2, amplitude: 0.05))
        let loud = run(sine(440, seconds: 2, amplitude: 0.8))
        XCTAssertGreaterThan(loud.rms, quiet.rms)
        XCTAssertFalse(loud.isSilent)
    }

    func testChromaIsNormalised() {
        let f = run(sine(440, seconds: 2))
        XCTAssertEqual(f.chroma.count, 12)
        XCTAssertEqual(f.chroma.reduce(0, +), 1, accuracy: 0.05)
    }
}
