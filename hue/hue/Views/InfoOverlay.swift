import SwiftUI

// MARK: - InfoOverlay

/// Plain-language guide to Hue — why it exists, how listening works, the three
/// window states, the three Fields, the three Profiles, and exactly which
/// colors mean what. Opened from the small "i" in the top bar; dismissed with
/// the X, Esc, or a click on the scrim.
///
/// Sizing is clamped against the window's own bounds (see `body`) so the panel
/// keeps identical proportions and type sizes at every window size instead of
/// reflowing or clipping — long content scrolls rather than stretching.
struct InfoOverlay: View {
    let onClose: () -> Void

    /// Design size. The panel renders at exactly this size whenever the window
    /// can fit it, and shrinks only as far as the window forces.
    private let idealWidth: CGFloat = 620
    private let idealHeight: CGFloat = 660
    private let outerInset: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            let width  = min(idealWidth,  max(320, geo.size.width  - outerInset * 2))
            let height = min(idealHeight, max(260, geo.size.height - outerInset * 2))

            ZStack {
                Color.black.opacity(0.72)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)

                panel
                    .frame(width: width, height: height)
                    .background(Color.black.opacity(0.94))
                    .overlay {
                        Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1)
                    }
                    // Solid hit target so empty panel chrome doesn't fall
                    // through to the scrim's dismiss gesture.
                    .contentShape(Rectangle())
                    .allowsHitTesting(true)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(true)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 30) {
                    whySection
                    listeningSection
                    viewsSection
                    colorsSection
                    legendSection
                    fieldsSection
                    profilesSection
                    metersSection
                    privacySection
                }
                .padding(.horizontal, 32)
                .padding(.top, 10)
                .padding(.bottom, 36)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("ABOUT HUE")
                    .font(.archivo(.semibold, size: 11))
                    .tracking(11 * 0.28)
                    .foregroundStyle(Color.white.opacity(0.45))
                Text("Seeing music")
                    .font(.archivo(.semibold, size: 22))
                    .foregroundStyle(.white)
            }
            Spacer(minLength: 12)
            Button(action: onClose) {
                ZStack {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 32, height: 32)
                    LucideShape(paths: LucideIcon.x)
                        .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
                        .frame(width: 13, height: 13)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Close")
            // Beat any sibling gestures (scroll/scrim) for this control.
            .highPriorityGesture(TapGesture().onEnded { onClose() })
        }
        .padding(.horizontal, 32)
        .padding(.top, 22)
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
        }
        .zIndex(1)
    }

    // MARK: - Sections

    private var whySection: some View {
        section(title: "Why this exists") {
            bodyText("Hue is a passion project. It was built by someone who loves music, read about synesthesia — where one sense involuntarily triggers another — and wanted to know what their favourite songs would actually look like.")
            bodyText("About 4% of people have chromesthesia: they hear a sound and genuinely see a colour. Most of us don’t. Hue is an attempt to borrow that experience for a while, and to do it as scientifically as possible rather than just making pretty shapes move to a beat.")
            bodyText("So every colour you see here is chosen by rules taken from published research on how humans link sound to colour — not by taste, and not at random. Where the science is genuinely uncertain, Hue says so instead of pretending.")
        }
    }

    private var listeningSection: some View {
        section(title: "How it listens") {
            bodyText("Hue reads the audio already playing on your Mac — Spotify, Apple Music, YouTube, a game, anything. No cables, no extra audio drivers, no setup.")
            bodyText("macOS files system-audio capture under “Screen & Audio Recording”, which is why it asks for that permission once. Your screen is never captured, and no audio is ever recorded or sent anywhere.")
            bodyText("The canvas is the whole window. Move your pointer inside and the controls fade in; move away and they fade out so nothing competes with the picture.")
        }
    }

    private var viewsSection: some View {
        section(title: "The three views") {
            bodyText("There is only one window, and it is always in one of three states:")
            termRow(title: "Live", body: "Music is playing. The field is being painted in real time and the meters track what Hue is hearing.")
            termRow(title: "Idle", body: "Everything is silent, so “nothing is playing” appears and the colour slowly drains away instead of freezing in place.")
            termRow(title: "Permission", body: "Before access is granted. The explanation sits over a dimmed version of the same live field, with one button to allow it.")
        }
    }

    private var colorsSection: some View {
        section(title: "How sound becomes colour") {
            bodyText("Three properties of the music control three properties of the colour. That’s the whole engine:")
            termRow(title: "Pitch → brightness", body: "High notes make the colour lighter, bass makes it darker. This is the one link that shows up in almost everyone, synesthete or not, so Hue makes it the backbone.")
            termRow(title: "Mood → warm or cool", body: "Major keys and bright, sharp timbres pull the hue toward warm yellow. Minor keys and softer, darker timbres pull it toward deep blue.")
            termRow(title: "Energy → intensity", body: "Faster, louder, more excited music becomes strongly saturated. Slow or quiet music stays muted and washed out.")
            bodyText("The colours are computed in OkLCh, a colour space built so that “brighter” means brighter to your eye rather than just a larger number. Ordinary RGB or HSL would break the pitch-to-brightness rule that everything else rests on.")
        }
    }

    private var legendSection: some View {
        section(title: "What the colours mean") {
            bodyText("Every colour Hue can produce lies on one continuous path: deep blue → cyan → green → warm yellow. Cool means low and sad, warm means high and happy. These swatches are generated by the same function that paints the window, so they are exactly what you would see:")
            VStack(spacing: 10) {
                legendRow(
                    centroid: 0.05, valence01: 0.05, arousal: 0.20, rms: 0.15,
                    title: "Deep slate blue",
                    body: "The coolest end — bass-heavy music in a minor key, played quietly. Sad and still."
                )
                legendRow(
                    centroid: 0.25, valence01: 0.15, arousal: 0.90, rms: 0.80,
                    title: "Electric cyan",
                    body: "Still low and minor, but loud and fast. Sad and intense at the same time."
                )
                legendRow(
                    centroid: 0.50, valence01: 0.50, arousal: 0.55, rms: 0.50,
                    title: "Green",
                    body: "The exact middle — ambiguous key, mid-range sound, moderate energy."
                )
                legendRow(
                    centroid: 0.80, valence01: 0.85, arousal: 0.85, rms: 0.70,
                    title: "Warm yellow / gold",
                    body: "The warmest end — major key, airy treble, high energy. Bright and joyful."
                )
                legendRow(
                    centroid: 0.78, valence01: 0.70, arousal: 0.15, rms: 0.20,
                    title: "Pale yellow-green",
                    body: "High and happy, but soft and slow. The hue stays warm while saturation drops away."
                )
            }
            bodyText("You will rarely see a flat swatch on screen. The window is a fluid simulation, so these colours are injected as moving dye and then blend, stretch, and fade into each other.")
            bodyText("When the window looks nearly black, that isn’t a dark colour — it means little or no sound is arriving, so almost no dye is being added and what’s left has decayed away.")
        }
    }

    private var fieldsSection: some View {
        section(title: "The three Fields") {
            bodyText("Field changes how the colour moves — the physics of the paint, not the palette. Switch it at the bottom of the window.")
            termRow(title: "Diffuse", body: "Ink loosed in still water. Soft curling drift with no fixed direction — calm and dreamlike.")
            termRow(title: "Ascend", body: "Rising veils. Higher pitches sit higher in the frame, so the picture lifts like heat or smoke.")
            termRow(title: "Radiate", body: "Pressure from the centre. Each beat pushes a ring of colour outward — best for rhythmic, punchy tracks.")
        }
    }

    private var profilesSection: some View {
        section(title: "The three Profiles") {
            bodyText("Profile changes how individual notes nudge the hue. This is where Hue is careful to be honest:")
            termRow(title: "Emotion", body: "The default, and the only one backed by population-level research. Colour follows the emotion of the music — key, mode, and timbre — rather than a fixed colour per note.")
            termRow(title: "Scriabin", body: "Composer Alexander Scriabin’s own note-to-colour wheel from around 1911. Fascinating, but it was one man’s private experience, not a universal rule.")
            termRow(title: "Rimsky", body: "Rimsky-Korsakov’s documented key-to-colour associations. Another individual system — and it disagrees with Scriabin’s, which is precisely the point.")
            bodyText("Many “synesthesia” apps ship a composer’s wheel as the truth. Hue keeps them as optional lenses, because presenting one person’s private mapping as fact would be the least authentic choice available.")
        }
    }

    private var metersSection: some View {
        section(title: "Reading the meters") {
            bodyText("The strip along the bottom shows what Hue is hearing right now:")
            termRow(title: "L ← Pitch", body: "Lightness — how bright the colour currently is.")
            termRow(title: "H ← Warmth", body: "Where the hue sits between cool blue and warm yellow.")
            termRow(title: "C ← Arousal", body: "How vivid and saturated the colour is.")
            termRow(title: "Key · Tempo · Valence", body: "The detected musical key, an estimated tempo in BPM, and whether the mood reads major and bright or minor and dark.")
            bodyText("Key detection listens over several seconds, so it settles in shortly after a song starts rather than jumping around on every chord.")
        }
    }

    private var privacySection: some View {
        section(title: "Privacy") {
            bodyText("Everything happens on your Mac. No account, no network calls, no analytics, nothing stored. Hue reads the audio stream, draws it, and forgets it.")
        }
    }

    // MARK: - Building blocks

    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title.uppercased())
                .font(.archivo(.semibold, size: 10))
                .tracking(10 * 0.22)
                .foregroundStyle(Color.hueAccent)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bodyText(_ text: String) -> some View {
        Text(text)
            .font(.archivo(.regular, size: 13))
            .lineSpacing(5)
            .foregroundStyle(Color.white.opacity(0.72))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func termRow(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.archivo(.semibold, size: 13))
                .foregroundStyle(Color.white.opacity(0.92))
            Text(body)
                .font(.archivo(.regular, size: 13))
                .lineSpacing(4)
                .foregroundStyle(Color.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.white.opacity(0.16)).frame(width: 2)
        }
    }

    /// A swatch rendered straight from `PerceptualMapper` — the same function
    /// the renderer calls each frame — so the legend cannot drift out of sync
    /// with what the field actually paints.
    private func legendRow(
        centroid: Float,
        valence01: Float,
        arousal: Float,
        rms: Float,
        title: String,
        body: String
    ) -> some View {
        let swatch = PerceptualMapper.color(
            centroid: centroid,
            valence01: valence01,
            arousal: arousal,
            rms: rms
        )

        return HStack(alignment: .top, spacing: 14) {
            Rectangle()
                .fill(swatch.swiftUIColor)
                .frame(width: 46, height: 46)
                .overlay {
                    Rectangle().stroke(Color.white.opacity(0.16), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.archivo(.semibold, size: 13))
                    .foregroundStyle(Color.white.opacity(0.92))
                Text(body)
                    .font(.archivo(.regular, size: 12.5))
                    .lineSpacing(4)
                    .foregroundStyle(Color.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - InfoButton

/// Small circular "i" control for the top chrome.
struct InfoButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            LucideShape(paths: LucideIcon.info)
                .stroke(
                    isHovering ? Color.white : Color.white.opacity(0.5),
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 15, height: 15)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("About Hue")
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.16), value: isHovering)
    }
}
