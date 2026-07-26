import Foundation

// MARK: - AudioFeatures

/// All frequency and amplitude data derived from one FFT frame.
/// This is the primary contract between the DSP layer (AudioProcessor)
/// and the rendering layer (MetalRenderer).
///
/// All values are normalized to [0, 1] unless otherwise noted.
struct AudioFeatures {

    // MARK: - Frequency Bands

    /// Energy in the bass band (20–250 Hz). Deep bass, kick drums, sub-bass.
    var bass: Float = 0

    /// Energy in the midrange band (250–4000 Hz). Vocals, guitars, most instruments.
    var mids: Float = 0

    /// Energy in the treble band (4000–20000 Hz). Cymbals, sibilance, high harmonics.
    var treble: Float = 0

    // MARK: - Amplitude

    /// Overall RMS loudness of the current frame. 0 = silence, 1 = full scale.
    var rms: Float = 0

    // MARK: - Timbre Descriptors

    /// Weighted mean frequency of the spectrum — perceptual "brightness."
    /// Low value = warm/dark sound; High value = bright/airy sound.
    var spectralCentroid: Float = 0

    /// Frame-to-frame change in spectral energy. Detects transients and timbral shifts.
    /// Low value = smooth/sustained tone; High value = percussive/complex/distorted.
    var spectralFlux: Float = 0

    // MARK: - Beat Detection

    /// 0–1 pulse that fires on kick/snare onset. Spikes to 1.0, decays exponentially.
    var beatIntensity: Float = 0

    /// Running beat phase estimate (0–1 cycle). Used for cyclic visual modulation.
    var beatPhase: Float = 0

    // MARK: - Genre / Spectral Shape

    /// Bass-to-mids energy ratio. High = bass-heavy (hip-hop), Low = bright (classical).
    var lowMidRatio: Float = 0

    /// How spread out the frequency content is. Wide = orchestral, Narrow = single-instrument.
    var spectralSpread: Float = 0

    /// Ratio of harmonic to inharmonic content. High = tonal, Low = percussive/noisy.
    var harmonicComplexity: Float = 0

    // MARK: - Chromesthesia Engine (v3): Key, Tempo, Emotion
    //
    // See CHROMESTHESIA_ENGINE.md. These feed the perceptual color mapper,
    // which is where the actual synesthesia research gets applied.

    /// 12-element pitch-class energy distribution (C, C#, D, … B), L1-normalized.
    var chroma: [Float] = Array(repeating: 0, count: 12)

    /// Estimated tonal center, 0 = C … 11 = B. Only meaningful when `keyConfidence` is high.
    var keyPitchClass: Int = 0

    /// Estimated mode: true = major, false = minor.
    var isMajor: Bool = true

    /// Krumhansl-Schmuckler correlation strength for the winning key, normalized to [0, 1].
    var keyConfidence: Float = 0

    /// Normalized tempo estimate (0 ≈ 60 BPM, 1 ≈ 180 BPM).
    var tempoNorm: Float = 0.5

    /// Emotional valence implied by the music (Palmer et al. 2013): 0 = sad/minor,
    /// 1 = happy/major. Drives hue-warmth and saturation, not just key detection directly —
    /// this is the "mediated by emotion" step, the single biggest lever for authenticity.
    var valence: Float = 0.5

    /// Emotional arousal — how energetic the music is right now (tempo + loudness + transients).
    var arousal: Float = 0

    /// Dominant pitch class this instant (argmax of `chroma`). Used by note-color profiles
    /// (Scriabin, Rimsky-Korsakov, Custom) — not used by the default Emotion profile.
    var dominantPitchClass: Int {
        var best = 0
        for i in 1..<chroma.count where chroma[i] > chroma[best] { best = i }
        return best
    }

    // MARK: - Raw Bins

    /// Downsampled magnitude spectrum: 128 bins covering 20 Hz – 20 kHz (log-spaced).
    /// Each bin is normalized to [0, 1]. Used directly by the fragment shader.
    var frequencyBins: [Float] = Array(repeating: 0, count: 128)

    // MARK: - Helpers

    /// True if no meaningful audio is present (used to switch to idle visual state).
    var isSilent: Bool { rms < 0.005 }
}

// MARK: - Metal Buffer Layout

/// C-compatible layout that is memcpy'd into the AudioData MTLBuffer.
/// Must exactly mirror the `AudioData` struct in Composite.metal / FluidCompute.metal.
struct AudioDataBuffer {
    var bass: Float
    var mids: Float
    var treble: Float
    var rms: Float
    var spectralCentroid: Float
    var spectralFlux: Float
    var beatIntensity: Float
    var beatPhase: Float
    var lowMidRatio: Float
    var spectralSpread: Float
    var harmonicComplexity: Float
    var isSilent: Float   // 1.0 = silent, 0.0 = active (Float for GPU alignment)

    // Chromesthesia engine v3 — emotion + perceptual color target.
    var valence: Float
    var arousal: Float
    var mappedL: Float   // OkLab lightness target from PerceptualMapper
    var mappedC: Float   // OkLab chroma target
    var mappedH: Float   // OkLab hue target, in radians [0, 2π)

    init(from features: AudioFeatures, mapped: PerceptualColor) {
        self.bass               = features.bass
        self.mids               = features.mids
        self.treble             = features.treble
        self.rms                = features.rms
        self.spectralCentroid   = features.spectralCentroid
        self.spectralFlux       = features.spectralFlux
        self.beatIntensity      = features.beatIntensity
        self.beatPhase          = features.beatPhase
        self.lowMidRatio        = features.lowMidRatio
        self.spectralSpread     = features.spectralSpread
        self.harmonicComplexity = features.harmonicComplexity
        self.isSilent           = features.isSilent ? 1.0 : 0.0
        self.valence            = features.valence
        self.arousal            = features.arousal
        self.mappedL            = mapped.L
        self.mappedC            = mapped.C
        self.mappedH            = mapped.h
    }
}
