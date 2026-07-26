/*
 Copyright © 2026 kelyonn. All rights reserved.

 This file is part of Hue. See the LICENSE at the repository root.
 Unauthorized copying, modification, or reuse in another product is prohibited.
*/
import Accelerate
import Foundation

// MARK: - AudioProcessor

/// Transforms raw PCM audio samples into structured `AudioFeatures` using
/// Apple's Accelerate framework (vDSP).
///
/// ## v2 additions
/// - **Beat detection**: onset detection via bass energy spike tracking
/// - **Genre analysis**: lowMidRatio, spectralSpread, harmonicComplexity
/// - **Wider dynamic range**: better empirical scale factors, less over-smoothing
///
/// All processing happens on the audio capture queue (not main thread).
final class AudioProcessor: ObservableObject {

    // MARK: - Published Output

    /// SwiftUI-observed copy of the latest features (`DiagnosticHUD`,
    /// `ContentView`'s flat-color mode) — throttled to roughly display-refresh
    /// cadence (`publishIntervalSeconds`) rather than published on every audio
    /// callback. Every `@Published` write fires `objectWillChange` for every
    /// observer, including `MetalView`'s `NSViewRepresentable` — publishing
    /// once per callback meant SwiftUI re-diffed the whole view tree that
    /// often (potentially well above screen refresh rate, and for no visual
    /// benefit since the Metal renderer doesn't go through Combine at all —
    /// see `rawLatestFeatures`).
    @Published private(set) var latestFeatures = AudioFeatures()

    /// Same content as `latestFeatures`, but updated on *every* audio callback
    /// with no throttling and no `@Published` overhead. `MetalRenderer` polls
    /// this directly once per `draw(in:)` call — it wants the freshest
    /// possible value every frame and has no use for a Combine subscription.
    private(set) var rawLatestFeatures = AudioFeatures()

    /// Wall-clock (audio-time) gate for how often `latestFeatures` actually
    /// publishes; see its doc comment.
    private var lastPublishTime: Double = 0
    private let publishIntervalSeconds: Double = 1.0 / 60.0

    // MARK: - Configuration

    private let fftSize     = 4096
    private let sampleRate  = 48_000.0
    private let smoothing   = Float(0.35)       // Higher = more responsive (was 0.25)

    // MARK: - vDSP Resources (pre-allocated)

    private let log2n: vDSP_Length
    private let fftSetup: vDSP.FFT<DSPSplitComplex>
    private var hannWindow: [Float]
    private var ringBuffer: [Float]
    private var ringHead   = 0
    private var ringFull   = false

    /// Even-odd packed FFT *input* (filled by `vDSP_ctoz`). Must be a
    /// different buffer from `realPart`/`imagPart` — `vDSP.FFT.forward` is
    /// out-of-place (`vDSP_fft_zrop`) and forbids overlapping source/dest.
    private var fftInputReal: [Float]
    private var fftInputImag: [Float]
    /// FFT *output* spectrum (split-complex, length `fftSize / 2`).
    private var realPart: [Float]
    private var imagPart: [Float]
    private var magnitudes: [Float]
    private var previousMagnitudes: [Float]

    // MARK: - Beat Detection State
    //
    // `runFFT` fires once per `process()` call, i.e. once per SCStream audio
    // callback — and ScreenCaptureKit does not guarantee those callbacks land
    // at 60/sec (that's a AVFoundation/CoreAudio buffering detail, not
    // something this app configures). The previous implementation baked a
    // "60fps" assumption into the bass-history window size, the beat cooldown,
    // the BPM formula, and the beat-phase accumulator, all as callback counts
    // ("frames"). Whenever the real callback rate differed, all four drifted
    // by exactly that ratio. Everything below is keyed off `secondsProcessed`
    // — real elapsed audio time, computed from actual sample counts — instead.

    /// Accumulated duration, in seconds, of audio actually processed so far.
    /// The clock every beat-timing calculation below uses instead of a
    /// callback/frame count.
    private var secondsProcessed: Double = 0
    /// `secondsProcessed` as of the previous `runFFT` call — the difference
    /// is `dt`, the real time elapsed since the last beat-detection pass.
    private var lastFFTTime: Double = 0

    /// Rolling window of (timestamp, bass energy) samples for onset detection,
    /// spanning the last `bassHistoryWindowSeconds` of real audio time.
    private let bassHistoryWindowSeconds: Double = 0.7
    private var bassHistory: [(time: Double, energy: Float)] = []

    private var beatCooldownUntil: Double = 0        // secondsProcessed timestamp
    private let beatCooldownSeconds: Double = 0.150  // minimum gap between onsets
    private var currentBeatIntensity: Float = 0
    private var beatPhaseAccumulator: Float = 0
    private var estimatedBPM: Float = 120      // Default estimate

    // Beat interval tracking for BPM estimation
    private var lastBeatTime: Double = 0
    private var frameCounter = 0               // Callback count — only used to throttle key detection, not a time unit.
    private var beatIntervals: [Double] = []   // Seconds between consecutive onsets

    // MARK: - Key Detection State (Chromesthesia Engine v3)

    /// Krumhansl-Kessler key profiles — the classic tonal-hierarchy weights used
    /// for Krumhansl-Schmuckler key finding. Index 0 = tonic's own pitch class.
    private static let majorKeyProfile: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let minorKeyProfile: [Float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    /// Key detection is correlation-heavy (24 hypotheses/frame); throttle it —
    /// the chromagram itself is still refreshed every frame.
    private let keyDetectionIntervalFrames = 6
    private var lastKeyPitchClass = 0
    private var lastKeyIsMajor = true
    private var lastKeyConfidence: Float = 0

    /// Seconds-long integration of the chromagram, used only for key detection
    /// (see the comment at its use site in `runFFT`). Separate from the fast
    /// `AudioFeatures.chroma` used for real-time note color.
    private var slowChroma: [Float] = Array(repeating: 0, count: 12)

    // MARK: - Frequency Band Bin Ranges

    private var subBassRange: ClosedRange<Int> { binRange(lo: 20,    hi: 80)   }
    private var bassRange:    ClosedRange<Int> { binRange(lo: 20,    hi: 250)   }
    private var midsRange:    ClosedRange<Int> { binRange(lo: 250,   hi: 4_000) }
    private var trebleRange:  ClosedRange<Int> { binRange(lo: 4_000, hi: 20_000) }

    private func binRange(lo: Double, hi: Double) -> ClosedRange<Int> {
        let loIdx = max(1, Int((lo * Double(fftSize)) / sampleRate))
        let hiIdx = min(fftSize / 2 - 1, Int((hi * Double(fftSize)) / sampleRate))
        return loIdx...hiIdx
    }

    // MARK: - Init

    init() {
        let n = fftSize
        log2n  = vDSP_Length(log2(Double(n)))
        fftSetup = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)!
        hannWindow = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)

        ringBuffer         = [Float](repeating: 0, count: n)
        fftInputReal       = [Float](repeating: 0, count: n / 2)
        fftInputImag       = [Float](repeating: 0, count: n / 2)
        realPart           = [Float](repeating: 0, count: n / 2)
        imagPart           = [Float](repeating: 0, count: n / 2)
        magnitudes         = [Float](repeating: 0, count: n / 2)
        previousMagnitudes = [Float](repeating: 0, count: n / 2)
    }

    // MARK: - Public API

    /// - Parameter samples: Mono Float32 PCM, already downmixed by
    ///   `AudioCaptureManager.extractMonoSamples` (which knows the real
    ///   interleaved/planar layout — this layer no longer needs to guess it).
    func process(_ samples: [Float]) {
        guard !samples.isEmpty else { return }

        // Real elapsed audio time — the clock for all beat/BPM timing below.
        secondsProcessed += Double(samples.count) / sampleRate

        for sample in samples {
            ringBuffer[ringHead] = sample
            ringHead = (ringHead + 1) % fftSize
            if ringHead == 0 { ringFull = true }
        }

        guard ringFull else { return }

        var window = [Float](repeating: 0, count: fftSize)
        let tail = fftSize - ringHead
        window[0..<tail] = ringBuffer[ringHead..<fftSize]
        window[tail..<fftSize] = ringBuffer[0..<ringHead]

        runFFT(on: window)
    }

    // MARK: - Private — DSP

    private func runFFT(on samples: [Float]) {
        frameCounter += 1

        // Real time elapsed since the previous FFT/beat-detection pass — see
        // the MARK: Beat Detection State comment above for why this replaces
        // a fixed "1/60s per frame" assumption.
        let dt = max(0, secondsProcessed - lastFFTTime)
        lastFFTTime = secondsProcessed

        // Apply Hann window.
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP.multiply(samples, hannWindow, result: &windowed)

        // Real FFT via even-odd split packing → out-of-place `zrop`.
        // Source and destination *must* be distinct buffers; the previous
        // code packed and transformed in the same `realPart`/`imagPart`,
        // which is undefined for `vDSP_fft_zrop`. That scrambled the
        // spectrum enough that chromagrams were near-noise and
        // Krumhansl-Schmuckler fell through to its default: C major.
        windowed.withUnsafeBufferPointer { wPtr in
            fftInputReal.withUnsafeMutableBufferPointer { inR in
                fftInputImag.withUnsafeMutableBufferPointer { inI in
                    realPart.withUnsafeMutableBufferPointer { outR in
                        imagPart.withUnsafeMutableBufferPointer { outI in
                            var input = DSPSplitComplex(realp: inR.baseAddress!, imagp: inI.baseAddress!)
                            var output = DSPSplitComplex(realp: outR.baseAddress!, imagp: outI.baseAddress!)
                            wPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { cPtr in
                                vDSP_ctoz(cPtr, 2, &input, 1, vDSP_Length(fftSize / 2))
                            }
                            fftSetup.forward(input: input, output: &output)
                            // Power spectrum. Bin 0 packs DC in realp[0] and
                            // Nyquist in imagp[0] — don't let zvmags sum them.
                            vDSP_zvmags(&output, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
                            magnitudes[0] = outR[0] * outR[0]
                        }
                    }
                }
            }
        }

        // Normalise magnitudes.
        var scale = Float(1.0 / Double(fftSize))
        var normalised = [Float](repeating: 0, count: fftSize / 2)
        vDSP_vsmul(&magnitudes, 1, &scale, &normalised, 1, vDSP_Length(fftSize / 2))
        magnitudes = normalised

        // ── Extract all features ──

        let bass   = bandEnergy(magnitudes, range: bassRange)
        let mids   = bandEnergy(magnitudes, range: midsRange)
        let treble = bandEnergy(magnitudes, range: trebleRange)

        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(fftSize))

        let centroidHz = spectralCentroidHz(magnitudes)
        let centroid   = normalizedBrightness(centroidHz)
        let flux       = spectralFlux(current: magnitudes, previous: previousMagnitudes)
        previousMagnitudes = magnitudes

        // ── Beat detection ──
        let beatResult = detectBeat(bassEnergy: bass, dt: dt)

        // ── Genre analysis ──
        let lowMidR   = mids > 0.0001 ? min(bass / mids, 2.0) / 2.0 : 0.5
        let spread    = computeSpectralSpread(magnitudes, centroidHz: centroidHz)
        let harmonic  = computeHarmonicComplexity(magnitudes)

        // ── Downsample to 128 log-spaced bins ──
        let bins = downsampleLogSpaced(magnitudes, outputBins: 128)

        // ── Chromagram + key/mode detection (Chromesthesia Engine v3) ──
        //
        // `chroma` is the fast, per-instant vector (~100-200ms smoothing) —
        // used for moment-to-moment note color. Key/mode detection needs a
        // completely different timescale: a single 4096-sample FFT window is
        // one chord, not "the key of the song," and running Krumhansl-Schmuckler
        // on something that noisy makes the mode (and therefore valence — happy
        // vs. sad) flip on transient chord changes instead of tracking the
        // song's actual tonal center. `slowChroma` integrates over several
        // seconds specifically to give key detection a stable input.
        let chroma = computeChromagram(magnitudes)
        // 0.02 (was 0.98 retention) made key detection so glacial it effectively
        // never caught up to a real song within a normal listening session,
        // contributing to the "freezes and never changes" symptom. 0.05 still
        // integrates over several seconds (not one chord), just gets there
        // in a reasonable amount of real time.
        for i in 0..<12 { slowChroma[i] = 0.05 * chroma[i] + 0.95 * slowChroma[i] }

        if frameCounter % keyDetectionIntervalFrames == 0 {
            let key = detectKey(chroma: slowChroma)
            // Refuse weak matches — Pearson≈0 (flat/noise chroma) remaps to
            // confidence 0.5 and the search's initial guess is C major, which
            // is how every track used to read as "C major". Only commit a
            // new key when the correlation is actually decisive.
            if key.confidence >= 0.62 {
                lastKeyPitchClass = key.pitchClass
                lastKeyIsMajor    = key.isMajor
                lastKeyConfidence = key.confidence
            } else {
                // Decay displayed confidence so the UI doesn't keep advertising
                // a stale key as if it were still sure.
                lastKeyConfidence *= 0.92
            }
        }
        let tempoNorm = clamp01((estimatedBPM - 60) / 120)
        let rawSpectralFlux = clamp01(flux * 15)
        let rawRMS = clamp01(rms * 8)

        // Emotion layer (Palmer et al. 2013): major mode → happier/lighter/warmer;
        // minor → sadder/darker/cooler. Confidence-weighted so an ambiguous key
        // pulls valence toward neutral rather than snapping unpredictably.
        let rawValence = 0.5 + 0.5 * (lastKeyIsMajor ? 1 : -1) * lastKeyConfidence
        let rawArousal = clamp01(0.4 * tempoNorm + 0.3 * rawRMS + 0.3 * rawSpectralFlux)

        // ── Compose features ──
        var raw = AudioFeatures()
        raw.bass               = clamp01(bass   * 60)
        raw.mids               = clamp01(mids   * 35)
        raw.treble             = clamp01(treble * 50)
        raw.rms                = rawRMS
        raw.spectralCentroid   = clamp01(centroid)
        raw.spectralFlux       = rawSpectralFlux
        raw.beatIntensity      = beatResult.intensity
        raw.beatPhase          = beatResult.phase
        raw.lowMidRatio        = clamp01(lowMidR)
        raw.spectralSpread     = clamp01(spread)
        raw.harmonicComplexity = clamp01(harmonic)
        raw.frequencyBins      = bins
        raw.chroma             = chroma
        raw.keyPitchClass      = lastKeyPitchClass
        raw.isMajor            = lastKeyIsMajor
        raw.keyConfidence      = clamp01(lastKeyConfidence)
        raw.tempoNorm          = tempoNorm
        raw.valence            = clamp01(rawValence)
        raw.arousal            = rawArousal

        // EMA smoothing — but NOT for beatIntensity (it should snap). Smooths
        // against `rawLatestFeatures`, not the throttled `latestFeatures`, so
        // the EMA chain stays anchored to the actual previous callback's
        // values regardless of the publish throttle below.
        let smoothed = smooth(raw, against: rawLatestFeatures)
        rawLatestFeatures = smoothed

        // Throttle the `@Published` copy to ~60 Hz — see its doc comment.
        if secondsProcessed - lastPublishTime >= publishIntervalSeconds {
            lastPublishTime = secondsProcessed
            DispatchQueue.main.async { [weak self] in
                self?.latestFeatures = smoothed
            }
        }
    }

    // MARK: - Beat Detection

    private struct BeatResult {
        var intensity: Float
        var phase: Float
    }

    private func detectBeat(bassEnergy: Float, dt: Double) -> BeatResult {
        // Push current bass into the rolling window, then evict anything
        // older than `bassHistoryWindowSeconds` of real audio time.
        let scaledBass = clamp01(bassEnergy * 60)
        bassHistory.append((time: secondsProcessed, energy: scaledBass))
        let cutoff = secondsProcessed - bassHistoryWindowSeconds
        while let oldest = bassHistory.first, oldest.time < cutoff {
            bassHistory.removeFirst()
        }

        // Compute mean and standard deviation of the window.
        let energies = bassHistory.map(\.energy)
        var mean: Float = 0
        var stdDev: Float = 0
        vDSP_meanv(energies, 1, &mean, vDSP_Length(energies.count))

        var diff = energies.map { ($0 - mean) * ($0 - mean) }
        var variance: Float = 0
        vDSP_meanv(&diff, 1, &variance, vDSP_Length(diff.count))
        stdDev = sqrt(variance)

        // Beat fires when bass exceeds adaptive threshold.
        let threshold = mean + 1.4 * max(stdDev, 0.05)
        var didBeat = false

        if scaledBass > threshold && scaledBass > 0.15 && secondsProcessed >= beatCooldownUntil {
            currentBeatIntensity = 1.0
            beatCooldownUntil = secondsProcessed + beatCooldownSeconds
            didBeat = true

            // Track beat intervals (seconds) for BPM estimation.
            let intervalSeconds = secondsProcessed - lastBeatTime
            lastBeatTime = secondsProcessed
            if intervalSeconds > 0.08 && intervalSeconds < 3.0 { // ~20–750 BPM sanity range
                beatIntervals.append(intervalSeconds)
                if beatIntervals.count > 16 { beatIntervals.removeFirst() }
                let avgIntervalSeconds = beatIntervals.reduce(0, +) / Double(beatIntervals.count)
                estimatedBPM = Float(60.0 / avgIntervalSeconds)
            }
        }

        // Exponential decay of beat intensity, expressed as a continuous
        // per-second rate — calibrated so it reproduces the original
        // "×0.85 every callback" feel at a 60 Hz callback rate — so the pulse
        // decays at the same real-world speed regardless of how often
        // ScreenCaptureKit's audio callback actually fires.
        if !didBeat {
            let decayRatePerSecond: Float = 60.0 * log(0.85)  // ≈ -9.75
            currentBeatIntensity *= exp(decayRatePerSecond * Float(dt))
            if currentBeatIntensity < 0.01 { currentBeatIntensity = 0 }
        }

        // Advance beat phase accumulator using estimated BPM and real elapsed
        // time (`dt`), then wrap into [0, 1) — a plain subtraction (the old
        // per-frame version) isn't enough here since `dt` can occasionally
        // exceed one full beat period.
        let beatsPerSecond = estimatedBPM / 60.0
        beatPhaseAccumulator += beatsPerSecond * Float(dt)
        beatPhaseAccumulator = beatPhaseAccumulator.truncatingRemainder(dividingBy: 1.0)
        if beatPhaseAccumulator < 0 { beatPhaseAccumulator += 1.0 }

        return BeatResult(intensity: currentBeatIntensity, phase: beatPhaseAccumulator)
    }

    // MARK: - Spectral Analysis Helpers

    private func bandEnergy(_ magnitudes: [Float], range: ClosedRange<Int>) -> Float {
        guard range.lowerBound < magnitudes.count,
              range.upperBound < magnitudes.count else { return 0 }
        let slice = Array(magnitudes[range])
        var mean: Float = 0
        vDSP_meanv(slice, 1, &mean, vDSP_Length(slice.count))
        return mean
    }

    /// Magnitude-weighted mean frequency, in Hz — unnormalized. Kept separate from
    /// the perceptual [0,1] mapping below because other calculations (spectral
    /// spread) need the real Hz value, not a normalized score.
    private func spectralCentroidHz(_ mags: [Float]) -> Float {
        let halfN = mags.count
        var weightedSum: Float = 0
        var totalWeight: Float = 0
        for i in 1..<halfN {
            let freq = Float(i * Int(sampleRate)) / Float(fftSize)
            weightedSum += freq * mags[i]
            totalWeight += mags[i]
        }
        guard totalWeight > 0 else { return 0 }
        return weightedSum / totalWeight
    }

    /// Maps a centroid in Hz to a perceptual [0,1] "brightness" score.
    ///
    /// Deliberately logarithmic, not linear-to-Nyquist: frequency perception is
    /// logarithmic (mel/Bark scales, octave-based pitch), and — critically —
    /// real music's magnitude-weighted centroid almost never exceeds a few kHz
    /// even for bright mixes, because bass/mid energy dominates the sum. A
    /// linear ratio to Nyquist (24 kHz at our 48 kHz sample rate) pins nearly
    /// all real audio below ~0.15, starving every mapping that depends on this
    /// value (hue-warmth, lightness, GPU pitch-height bias, particle color).
    /// This range (150 Hz dark/bassy … 6 kHz bright/airy) is calibrated so
    /// ordinary music actually spans the full output range.
    private func normalizedBrightness(_ hz: Float) -> Float {
        let minHz: Float = 150
        let maxHz: Float = 6000
        guard hz > minHz else { return 0 }
        let t = log2(hz / minHz) / log2(maxHz / minHz)
        return clamp01(t)
    }

    /// Spectral spread: standard deviation of frequency distribution around centroid.
    private func computeSpectralSpread(_ mags: [Float], centroidHz: Float) -> Float {
        let halfN = mags.count
        var weightedVariance: Float = 0
        var totalWeight: Float = 0
        for i in 1..<halfN {
            let freq = Float(i * Int(sampleRate)) / Float(fftSize)
            let diff = freq - centroidHz
            weightedVariance += mags[i] * diff * diff
            totalWeight += mags[i]
        }
        guard totalWeight > 0 else { return 0 }
        let spreadHz = sqrt(weightedVariance / totalWeight)
        return min(spreadHz / 8000.0, 1.0) // Normalise to [0,1]
    }

    /// Rough harmonic complexity measure: ratio of top-N peak magnitudes to total energy.
    /// Tonal sounds have a few strong peaks; noisy sounds have energy spread evenly.
    private func computeHarmonicComplexity(_ mags: [Float]) -> Float {
        let halfN = mags.count
        guard halfN > 10 else { return 0 }
        var sorted = mags
        sorted.sort(by: >)
        let topN = min(10, halfN)
        let topSum = sorted[0..<topN].reduce(0, +)
        var total: Float = 0
        vDSP_sve(mags, 1, &total, vDSP_Length(halfN))
        guard total > 0 else { return 0 }
        return min(topSum / total, 1.0)
    }

    private func spectralFlux(current: [Float], previous: [Float]) -> Float {
        var diff = [Float](repeating: 0, count: current.count)
        vDSP_vsub(previous, 1, current, 1, &diff, 1, vDSP_Length(current.count))
        var halfRectified = diff.map { max(0, $0) }
        var sum: Float = 0
        vDSP_sve(&halfRectified, 1, &sum, vDSP_Length(halfRectified.count))
        return sum / Float(current.count)
    }

    private func downsampleLogSpaced(_ mags: [Float], outputBins: Int) -> [Float] {
        let halfN = mags.count
        let minFreq = 20.0
        let maxFreq = sampleRate / 2.0
        let logMin  = log10(minFreq)
        let logMax  = log10(maxFreq)

        var output = [Float](repeating: 0, count: outputBins)
        for i in 0..<outputBins {
            let t = Float(i) / Float(outputBins - 1)
            let freqHz = pow(10.0, Float(logMin) + t * Float(logMax - logMin))
            let binIdx = Int((freqHz * Float(fftSize)) / Float(sampleRate))
            let clamped = min(max(0, binIdx), halfN - 1)
            // Average a small window around the bin for smoother output.
            let lo = max(0, clamped - 1)
            let hi = min(halfN - 1, clamped + 1)
            var avg: Float = 0
            for j in lo...hi { avg += mags[j] }
            avg /= Float(hi - lo + 1)
            output[i] = clamp01(avg * 150)
        }
        return output
    }

    /// Exponential moving average. beatIntensity is NOT smoothed (must snap).
    private func smooth(_ current: AudioFeatures, against previous: AudioFeatures) -> AudioFeatures {
        let α = smoothing
        let β = 1 - α
        var result = current
        result.bass               = α * current.bass               + β * previous.bass
        result.mids               = α * current.mids               + β * previous.mids
        result.treble             = α * current.treble             + β * previous.treble
        result.rms                = α * current.rms                + β * previous.rms
        result.spectralCentroid   = α * current.spectralCentroid   + β * previous.spectralCentroid
        result.spectralFlux       = α * current.spectralFlux       + β * previous.spectralFlux
        // Beat intensity is NOT smoothed — must be snappy.
        result.beatIntensity      = current.beatIntensity
        result.beatPhase          = current.beatPhase
        result.lowMidRatio        = 0.1 * current.lowMidRatio        + 0.9 * previous.lowMidRatio  // slow transition
        result.spectralSpread     = 0.1 * current.spectralSpread     + 0.9 * previous.spectralSpread
        result.harmonicComplexity = 0.1 * current.harmonicComplexity + 0.9 * previous.harmonicComplexity
        result.frequencyBins      = zip(current.frequencyBins, previous.frequencyBins).map { α * $0 + β * $1 }

        // Chromesthesia engine v3 — key/mode pass through at the throttled rate;
        // valence and tempo drift slowly (a "mood" shouldn't flicker frame to frame).
        result.chroma        = zip(current.chroma, previous.chroma).map { 0.25 * $0 + 0.75 * $1 }
        result.keyPitchClass = current.keyPitchClass
        result.isMajor       = current.isMajor
        result.keyConfidence = 0.15 * current.keyConfidence + 0.85 * previous.keyConfidence
        result.tempoNorm     = 0.10 * current.tempoNorm     + 0.90 * previous.tempoNorm
        // Sped up from 0.08 — at 0.08 the mood signal converged and sat still,
        // which was part of why the visual froze after a few seconds. 0.2 still
        // reads as a slow "mood," not per-frame jitter, but actually keeps moving
        // as a song progresses instead of settling to one value and staying there.
        result.valence       = 0.20 * current.valence       + 0.80 * previous.valence
        result.arousal       = α * current.arousal + β * previous.arousal
        return result
    }

    // MARK: - Chromagram & Key Detection

    /// Folds FFT magnitude bins into a 12-element pitch-class energy vector
    /// (C, C#, D, … B), weighting by frequency-bin energy and L1-normalizing.
    ///
    /// Uses √power (amplitude) rather than raw power so a single loud bass
    /// partial can't dominate the vector, and stops at 5 kHz — above that
    /// bin density per semitone explodes and the fold turns into noise that
    /// Krumhansl-Schmuckler happily misreads as a key.
    private func computeChromagram(_ mags: [Float]) -> [Float] {
        var chroma = [Float](repeating: 0, count: 12)
        let minBin = max(1, Int((55.0 * Double(fftSize)) / sampleRate))   // ~A1
        let maxBin = min(mags.count, Int((5_000.0 * Double(fftSize)) / sampleRate))

        for i in minBin..<maxBin {
            let freq = Double(i) * sampleRate / Double(fftSize)
            let midi = 69.0 + 12.0 * log2(freq / 440.0)
            let pc = ((Int(midi.rounded()) % 12) + 12) % 12
            // Amplitude, not power — keeps the vector closer to musical weight.
            chroma[pc] += sqrt(max(0, mags[i]))
        }

        var total: Float = 0
        vDSP_sve(chroma, 1, &total, vDSP_Length(chroma.count))
        guard total > 0 else { return chroma }
        var scale = Float(1.0) / total
        var normalized = [Float](repeating: 0, count: 12)
        vDSP_vsmul(chroma, 1, &scale, &normalized, 1, vDSP_Length(12))
        return normalized
    }

    private struct KeyResult {
        var pitchClass: Int
        var isMajor: Bool
        var confidence: Float
    }

    /// Krumhansl-Schmuckler key finding: correlate the chroma vector against all
    /// 24 rotated major/minor tonal-hierarchy profiles, keep the best match.
    private func detectKey(chroma: [Float]) -> KeyResult {
        var bestScore: Float = -.infinity
        var bestPC = 0
        var bestIsMajor = true

        for pc in 0..<12 {
            let majorScore = pearsonCorrelation(chroma, rotateProfile(Self.majorKeyProfile, tonic: pc))
            if majorScore > bestScore { bestScore = majorScore; bestPC = pc; bestIsMajor = true }

            let minorScore = pearsonCorrelation(chroma, rotateProfile(Self.minorKeyProfile, tonic: pc))
            if minorScore > bestScore { bestScore = minorScore; bestPC = pc; bestIsMajor = false }
        }

        // Pearson r is in [-1, 1]; remap to a [0, 1] confidence.
        let confidence = clamp01((bestScore + 1) / 2)
        return KeyResult(pitchClass: bestPC, isMajor: bestIsMajor, confidence: confidence)
    }

    /// Rotates a tonic-relative profile so its peak (index 0) lands on pitch class `tonic`.
    private func rotateProfile(_ profile: [Float], tonic: Int) -> [Float] {
        (0..<12).map { profile[(($0 - tonic) % 12 + 12) % 12] }
    }

    private func pearsonCorrelation(_ a: [Float], _ b: [Float]) -> Float {
        var meanA: Float = 0, meanB: Float = 0
        vDSP_meanv(a, 1, &meanA, vDSP_Length(a.count))
        vDSP_meanv(b, 1, &meanB, vDSP_Length(b.count))

        var num: Float = 0, denomA: Float = 0, denomB: Float = 0
        for i in 0..<a.count {
            let da = a[i] - meanA
            let db = b[i] - meanB
            num += da * db
            denomA += da * da
            denomB += db * db
        }
        let denom = sqrt(denomA * denomB)
        return denom > 0.0001 ? num / denom : 0
    }

    private func clamp01(_ v: Float) -> Float { min(1, max(0, v)) }
}
