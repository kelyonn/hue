# Chromesthesia Engine — Authenticity Plan

> A research-grounded redesign of Hue's perceptual mapping layer, so the visuals
> track how sound *actually* evokes color in documented synesthetes and in the
> shared cross-modal wiring of the general population.
>
> Companion to [PRD.md](PRD.md). This document covers **what to map and why**;
> the PRD covers the app architecture.

---

## 1. What the science actually says

Four findings dominate the literature. They should be the load-bearing walls of
the engine. Ranked by strength of evidence:

### 1.1 Pitch → Lightness *(the one universal law)*
Higher pitch → lighter/brighter color; lower pitch → darker. This holds for
**both synesthetes and non-synesthetes**, which is why it feels "correct" to
everyone, not just the ~4% with chromesthesia. This is the most robust
correspondence in the field and should be the **primary driver of lightness** —
not hue. (Marks 1974; Ward et al. 2006.)

### 1.2 Emotion mediates music → color *(the biggest gap in the current build)*
Palmer et al. (2013, PNAS) showed music→color choices are mediated by shared
**emotional associations**, with correlations of **0.89 < r < 0.99** between the
emotion of the music and the emotion of the chosen colors — across two cultures.
Concretely:

| Music | Color response |
|---|---|
| Faster + **major** mode | more **saturated, lighter, yellower** |
| Slower + **minor** mode | **desaturated, darker, bluer** |

This is arguably the single most important thing for authenticity, and the
current engine models none of it. It requires estimating **mode (major/minor)**
and **tempo**, then routing them through a valence/arousal model into saturation
and hue.

### 1.3 Timbre → Hue-warmth + Saturation
Recent timbre studies (Frontiers 2024; *Rainbows in my ears* 2024) give
acoustic-feature rules we can implement directly:

- **Brighter/sharper timbre** (high spectral centroid) → **warm hues**
  (red/orange/yellow). Timbral brightness predicts warm-color choice even more
  strongly than semantic "warmth" does.
- **Softer/darker timbre** → **cool hues** (blue/green).
- **Heavier/darker/lower** timbre → **more saturated**; brighter/higher →
  **desaturated** (toward white). Reported in ~26% of music-color synesthetes and
  as a population trend.

Elegantly, timbre-brightness and major-mode **push in the same direction** (warm,
light) — so the two hue drivers reinforce rather than fight.

### 1.4 Loudness → Intensity, Roughness → Texture
Louder → greater visual presence/scale (already in the build). Harmonic
roughness / inharmonicity → geometric roughness (already in the build via
`harmonicComplexity`). Keep both.

### 1.5 What is *not* universal — and the authenticity trap
Note→color systems like **Scriabin's** (C=red, G=orange-pink, D=yellow…, which
trace the circle of fifths) and **Rimsky-Korsakov's** are **idiosyncratic to the
individual** and may be partly learned, not innate. Hardcoding Scriabin as the
default — a common mistake in "synesthesia" apps — is *less* authentic, not more,
because it presents one person's private mapping as universal. The honest default
is the **population-level, emotion-mediated model** above; Scriabin/Rimsky-Korsakov
belong behind an optional **profile picker** (§6).

---

## 2. Gap analysis vs. the current build

`AudioProcessor` already extracts: bass, mids, treble, rms, spectralCentroid,
spectralFlux, beatIntensity, beatPhase, lowMidRatio, spectralSpread,
harmonicComplexity, and a 128-bin spectrum. Good foundation. Missing for
authenticity:

| Need | Status | Why it matters |
|---|---|---|
| **Chromagram** (12 pitch classes) | ❌ missing | Prerequisite for key/mode detection |
| **Key + mode (major/minor)** | ❌ missing | Drives **valence** → Palmer's hue/saturation effect |
| **Tempo / arousal** | ⚠️ rough `estimatedBPM` only | Drives motion + saturation |
| **Valence/Arousal model** | ❌ missing | The emotion-mediation layer (§1.2) |
| **Perceptually-uniform color space** | ❌ HSL in shader | HSL "lightness" ≠ perceived lightness; corrupts §1.1 |
| **Spatial pitch mapping** | ❌ missing | Higher pitch → higher in field (documented) |

The current `frequency → hue` mapping in the PRD is the thing to **replace**:
frequency should drive **lightness**, not hue.

---

## 3. The mapping model (the core IP)

Insert a **perceptual mapping layer** between `AudioProcessor` (features) and
`MetalRenderer` (fluid sim). Do all color math in **OkLCh** (Oklab's cylindrical
form: L = lightness, C = chroma, h = hue) — a perceptually uniform space — then
convert to RGB in the shader's final step. This is essential: because pitch→
lightness is the backbone, "lightness" must mean *perceived* lightness, which HSL
does not provide.

All feature inputs are normalized 0..1. Pseudocode:

```text
// ── Emotion layer (Palmer mediation) ──
valence = keyConfidence * (isMajor ? +1 : -1)          // -1 sad/minor … +1 happy/major
valence01 = 0.5 + 0.5 * valence
arousal  = clamp(0.4*tempoNorm + 0.3*rms + 0.3*flux, 0, 1)

// ── Lightness ← pitch height (universal), lifted by loudness ──
L = clamp(0.35 + 0.50*centroid + 0.15*rms, 0, 1)

// ── Hue ← timbre-warmth + valence, reinforcing on one warm↔cool axis ──
warmCool = 0.6*centroid + 0.4*valence01                // 0 = cool, 1 = warm
h = mix(250°/*blue*/, 60°/*yellow*/, warmCool)
h += profile.pitchClassOffset(dominantChroma)          // 0 unless a profile is active

// ── Chroma/saturation ← major+loud+fast vivid; minor+soft muted; low pitch richer ──
C = Cmax * (0.4 + 0.6*valence01)
         * (0.5 + 0.5*arousal)
         * (1.2 - 0.4*centroid)                         // lower pitch → more saturated

// ── Motion / texture / scale (mostly wiring existing features) ──
fluidForce   ∝ arousal + 1.5*beatIntensity
feedbackDecay ∝ (1 - 0.5*arousal)                       // calm music = longer trails
roughness    ∝ harmonicComplexity                       // smooth glass ↔ fractured
displacement ∝ rms
```

Design properties this gives you, all traceable to §1:
- A quiet minor piano piece → **dark, desaturated, blue-violet, slow** trails.
- A loud major brass fanfare → **bright, saturated, yellow-orange, fast** bursts.
- Same note always yields the same color (deterministic) — mirrors the
  **consistency-over-time** that clinically distinguishes real synesthesia from
  generic reactive visualizers.

---

## 4. DSP additions (`AudioProcessor`)

All cheap on the existing Accelerate/vDSP pipeline; run key detection every
~10–20 frames, not every frame.

1. **Chromagram** — fold the existing FFT magnitude bins into 12 pitch classes
   (`pc = round(12*log2(f/C0)) mod 12`), weighting by bin energy. ~12-element
   output vector.
2. **Key + mode** — correlate the normalized chroma vector against the 24
   **Krumhansl-Schmuckler** key profiles (12 major + 12 minor). Best correlation →
   `(key, isMajor, keyConfidence)`. Standard MIR technique, a few dozen FLOPs.
3. **Tempo → `tempoNorm`** — formalize the existing `estimatedBPM` (map ~60–180
   BPM to 0..1). Optionally refine with autocorrelation of the flux/onset envelope.
4. **Valence/Arousal** — compute per §3 and add to `AudioFeatures`.
5. **Dominant pitch class** — argmax of chroma, for optional note→color profiles.

Extend `AudioFeatures` with: `chroma[12]`, `key`, `isMajor`, `keyConfidence`,
`valence`, `arousal`, `tempoNorm`. Smooth `valence`/`key` slowly (they should
drift, not flicker); keep `beatIntensity` snappy as it is now.

---

## 5. Renderer & shader changes

1. **Add Oklab↔RGB helpers** to the Metal shading code; feed the mapping layer's
   `(L, C, h)` into the composite shader and convert to RGB as the *last* step.
2. **Spatial pitch mapping** — inject dye/color at vertical position `y ∝
   centroid` (or per-onset dominant pitch), so higher notes bloom higher in the
   field. This spatial pitch height is itself documented and adds realism cheaply.
3. **Onset events** — on beat/onset, emit a discrete colored "splat" at its
   pitch-mapped location using the note's mapped hue, layered over the flowing
   field. Real chromesthesia is event-driven, not just a continuous wash.
4. **Motion coupling** — drive fluid injection force and feedback decay from
   `arousal`/`beatIntensity` per §3 so calm music genuinely moves slowly.

---

## 6. Synesthete profiles (honest handling of idiosyncrasy)

Ship a profile picker; **default = "Emotion" (the population model above)**.
Additional profiles only change `profile.pitchClassOffset(...)` and hue weighting:

- **Emotion** *(default)* — §3 model, no note→color bias. Most broadly "right."
- **Scriabin** — his documented circle-of-fifths note→hue wheel, as a hue offset.
- **Rimsky-Korsakov** — his mapping, with major/minor differentiation.
- **Custom** — let the user pin a hue to each of the 12 pitch classes (a genuine
  nod to how idiosyncratic real synesthesia is).

Framing this as "profiles" is the scientifically honest move: it tells the truth
that there is no single correct note→color map, while still nailing the universal
regularities in every profile.

---

## 7. Phased roadmap

| Phase | Deliverable | Exit criteria |
|---|---|---|
| **A — Emotion core** | Chromagram + K-S key/mode + valence/arousal in `AudioFeatures` | Console shows stable major/minor + valence/arousal that track real songs |
| **B — Perceptual color** | Oklab pipeline + §3 mapping replaces frequency→hue | Minor/slow reads dark-blue-muted; major/fast reads light-yellow-vivid |
| **C — Space & events** | Vertical pitch mapping + onset splats | Melodies visibly rise/fall; hits punctuate the field |
| **D — Profiles** | Profile picker (Emotion default, Scriabin, R-K, Custom) | Switching profiles visibly re-tints note colors; Emotion stays default |
| **E — Validation** | Authenticity tests (§8) | Passes the three-genre + consistency checks |

Phases A→B deliver the bulk of the authenticity gain and can ship first.

---

## 8. Validating "authentic"

Authenticity isn't subjective hand-waving — test it against the literature:

1. **Emotion congruence** — the app's per-track average color, scored for
   emotion, should correlate with the music's emotion the way Palmer found
   (major/fast → light/warm/saturated; minor/slow → dark/cool/muted). Eyeball a
   dozen tracks against the §1.2 table.
2. **Pitch→lightness monotonicity** — sweep a sine from 100 Hz→8 kHz; output
   lightness must rise monotonically. This is the one hard, universal law.
3. **Consistency** — the same track played twice produces the same color
   trajectory (deterministic mapping). This is what separates a synesthesia
   *simulator* from a random visualizer.
4. **Three-genre distinctness** (from the PRD) — classical / electronic /
   hip-hop should look clearly different, and in the *directions* the science
   predicts, not arbitrarily.

---

## 9. Sources

- Palmer, Schloss, Xu, Prado-León (2013). *Music–color associations are mediated
  by emotion.* PNAS 110(22).
  https://www.pnas.org/doi/10.1073/pnas.1212562110
- Whiteford et al. / Frontiers (2024). *Color and tone color: audiovisual
  crossmodal correspondences with musical instrument timbre.*
  https://pmc.ncbi.nlm.nih.gov/articles/PMC11747214/
- *Rainbows in my ears — Synesthetic color perception with partial-reduced and
  morphed musical instrument timbres* (2024).
  https://www.ncbi.nlm.nih.gov/pmc/articles/PMC12673365/
- Ward, Maciel, Rouw, Simner, Root (2025). *Synaesthesia … a distinctive pattern
  of sound-color associations.* Psychology of Music.
  https://journals.sagepub.com/doi/10.1177/03057356241250020
- Overview & Scriabin/Rimsky-Korsakov systems: *Chromesthesia*, Wikipedia.
  https://en.wikipedia.org/wiki/Chromesthesia
- Background on pitch–luminance: Marks (1974); Ward, Huckstep, Tsakanikos (2006),
  *Sound-colour synaesthesia*, Cortex.
```
