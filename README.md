# Hue

### Seeing music.

<p align="center">
  <img src="docs/screenshots/02-listening.png" alt="Hue listening to music — a green fluid field with live meters and Field/Profile controls" width="920" />
</p>

<p align="center"><em>Whatever is playing on your Mac, painted in real time.</em></p>

---

## About the project

Hue is a native macOS app that listens to whatever is already playing on your
Mac — Spotify, Apple Music, YouTube, a game, a podcast — and renders it as a
live fluid field of colour on the GPU, entirely on-device.

The colour mapping is modelled on **chromesthesia**, the form of synesthesia
where sound involuntarily produces colour, and on research into how everyone
else associates music with colour. The findings are surprisingly consistent:
pitch tracks lightness, emotion drives hue — major and happy pull warm, minor
and sad pull cool — and energy drives saturation. Hue implements those
relationships in a perceptually uniform colour space (OkLCh), so equal changes
in the music produce equal changes in what you see, rather than chasing the
beat with an arbitrary palette.

Composer note-wheels — Scriabin’s and Rimsky-Korsakov’s — are included as
optional profiles because they’re historically interesting, but they are one
person’s private associations. The default Emotion profile follows the
population-level data.

> **This software is proprietary.** The source is shared for reading and for
> running Hue — not for forking into your own product. See [`LICENSE`](LICENSE).

---

## What it looks like

### Idle — waiting for sound

<p align="center">
  <img src="docs/screenshots/01-idle.png" alt="Hue idle state — dark canvas with NOTHING IS PLAYING" width="720" />
</p>

When nothing is playing, the field drains. The window stays quiet. Move your
pointer inside and the chrome fades in; move away and it fades out again so
nothing competes with the picture.

### Listening — the field awake

<p align="center">
  <img src="docs/screenshots/02-listening.png" alt="Hue listening — fluid colour field with meters for pitch, warmth, arousal and Field/Profile switchers" width="920" />
</p>

Music arrives. Dye is injected. The meters along the bottom show what Hue is
hearing right now: pitch-driven lightness, warm↔cool balance, arousal, detected
key, tempo, and valence. At the bottom edge you choose how the paint *moves*
(Field) and which colour *story* to tell (Profile).

### How colour is chosen

<p align="center">
  <img src="docs/screenshots/04-color-legend.png" alt="Colour legend — continuous path from deep blue through green to warm yellow" width="920" />
</p>

Hue walks one continuous path: deep blue → cyan → green → warm yellow.

| Music feels like…        | Colour tends toward…   |
|--------------------------|------------------------|
| Low, minor, quiet        | Deep slate blue        |
| Low, minor, loud & fast  | Electric cyan          |
| Mid, ambiguous, moderate | Green                  |
| High, major, energetic   | Warm yellow / gold     |
| High, soft, slow         | Pale yellow-green      |

Almost black isn’t a “dark colour” — it means silence. With no sound arriving,
almost no dye is added, and what remains decays away.

---

## What you can change

### Fields — how the paint moves

| Field | Feel |
|-------|------|
| **Diffuse** | Ink loosed in still water. Soft curl, no fixed direction. |
| **Ascend** | Rising veils. Higher pitches sit higher in the frame. |
| **Radiate** | Pressure from the centre. Beats push rings outward. |

### Profiles — how notes nudge hue

| Profile | Meaning |
|---------|---------|
| **Emotion** | The default. Population-level research: mood and timbre drive colour. |
| **Scriabin** | One composer’s private 1911 note→colour wheel. Optional lens. |
| **Rimsky** | Rimsky-Korsakov’s documented key→colour associations. Also optional — and it disagrees with Scriabin, which is the point. |

Emotion is the honest default. The composer profiles are curiosities, not claims
about how the brain works.

---

## Setup — from zero to seeing music

### What you need

- A Mac running **macOS 14 Sonoma** or later
- Something that plays audio (any app)
- About thirty seconds of patience for one system permission

### Install the app (recommended)

Hue is meant to be used like any other Mac app:

1. Open **`/Applications/Hue.app`** (or drag a fresh Release build there).
2. Launch it from Spotlight, Launchpad, or the Applications folder.
3. When macOS asks for **Screen & Audio Recording**, allow it.
   - Hue uses ScreenCaptureKit only to read the **audio** already leaving your
     speakers. Your screen is not recorded, stored, or sent anywhere.
4. Play music.
5. Watch.

That’s the whole setup. No BlackHole. No Soundflower. No virtual cables. No
account. No network.

> **About the purple menu-bar pill.** While Hue is listening, macOS shows a
> system privacy indicator for Screen Recording. That indicator is owned by
> Apple — apps cannot hide it. Closing Hue’s window quits the app and stops
> capture; the pill should clear. If it stays after Hue is gone, click it —
> another app is sharing or recording.

### Day-to-day use

| Action | How |
|--------|-----|
| Reveal controls | Move the pointer into the window |
| Change Field / Profile | Bottom strip, when chrome is visible |
| Read what Hue hears | Meters + Key / Tempo / Valence |
| Learn the system | Click the small **i** in the top-right |
| Quit | Close the window, or **Quit Hue** from the menu-bar icon, or ⌘Q |

### Building from source (developers only)

Only do this if you are the copyright holder or have written permission.

```bash
# Requires Xcode 16+ and a valid Apple Development team ID in project.yml
cd hue
./regenerate_project.sh
open hue.xcodeproj
# Product → Archive, or:
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -scheme hue -configuration Release \
  -destination 'platform=macOS,arch=arm64' build
```

Then copy the Release `.app` into `/Applications`. Building from Xcode’s
DerivedData folder and re-signing repeatedly can confuse macOS’s permission
store — the Applications install is the stable identity.

---

## How it works (plain language)

```text
  Your speakers' audio
          │
          ▼
  ScreenCaptureKit  ──►  DSP (FFT, chroma, key, tempo, emotion)
          │
          ▼
  Perceptual mapper (OkLCh: pitch→L, mood→hue, energy→chroma)
          │
          ▼
  Metal fluid field  ──►  the window
```

Everything runs on-device. Nothing is uploaded. When you quit, listening stops.

For the research notes behind the mapper, see [`CHROMESTHESIA_ENGINE.md`](CHROMESTHESIA_ENGINE.md).
For product intent, see [`PRD.md`](PRD.md).

---

## Privacy

- Listens to system audio output only
- Does not capture, save, or transmit your screen
- Does not create an account
- Does not phone home
- Does not store the music it hears

The Screen & Audio Recording permission is a macOS requirement for this capture
API. It is not a request to watch your display.

---

## License & ownership

**Copyright © 2026 kelyonn. All rights reserved.**

Hue is **not** open source.

You may run the app. You may read the code to understand this specific project.
You may **not** copy it, fork it into another product, reuse the shaders or
mapping formulas in another codebase, or ship a derivative — commercially or
otherwise — without prior written permission.

The full terms are in [`LICENSE`](LICENSE).

If you came here hoping to bootstrap your own visualizer from this repo: build
your own. The interesting part was never the boilerplate — it was caring enough
about the science to refuse the easy lie.

---

<p align="center">
  <strong>Hue</strong><br/>
  <sub>A passion project about music, colour, and telling the truth about both.</sub>
</p>
