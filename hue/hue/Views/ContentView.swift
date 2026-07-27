import SwiftUI
import AppKit

// MARK: - ContentView

/// Main application window — the Metal canvas IS the UI.
///
/// Single window, three mutually-exclusive states
/// (design_handoff_hue_canvas/README.md, "Screens / views"):
/// - **Live** — chrome (wordmark, status, meters, facts, Field/Profile
///   switchers) fades in only while the pointer is inside the window.
/// - **Idle** — same chrome behaviour; "NOTHING IS PLAYING" shows whenever
///   audio is silent, and the field itself drains via the shader's
///   silence-gated decay (no separate SwiftUI-side idle background needed).
/// - **Permission** — `PermissionOverlay` replaces the live chrome entirely,
///   over the same `MetalView` dimmed to 50%.
struct ContentView: View {

    @EnvironmentObject private var captureManager: AudioCaptureManager
    @EnvironmentObject private var audioProcessor: AudioProcessor
    @EnvironmentObject private var colorProfileStore: ColorProfileStore
    @Environment(\.openWindow) private var openWindow

    /// Pointer inside the window — drives the 260ms chrome fade and the real
    /// traffic-light buttons' alpha (see `WindowButtonsFader`).
    @State private var isHovering = false

    /// Dev-only diagnostic panel (RMS/bass/mids/etc.) — off by default now
    /// that the shipped chrome has its own always-available meters. Still
    /// toggles with `D`.
    @State private var showHUD = false
    @State private var flatColorMode = false
    @State private var showInfo = false

    private var isGranted: Bool { captureManager.permissionState == .granted }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            if flatColorMode {
                // Bypasses Metal/the field sim entirely — fills the whole
                // window with exactly the color PerceptualMapper computed
                // this instant. Unambiguous "is the mapping tracking my
                // music at all" view, with nothing else in the way.
                let mapped = PerceptualMapper.map(
                    features: audioProcessor.latestFeatures,
                    profile: colorProfileStore.profile
                )
                Rectangle()
                    .fill(mapped.swiftUIColor)
                    .ignoresSafeArea()
            } else {
                MetalView(
                    audioProcessor: audioProcessor,
                    colorProfileStore: colorProfileStore,
                    dimmed: !isGranted
                )
                .ignoresSafeArea()
            }

            if isGranted {
                topBar
                if audioProcessor.latestFeatures.isSilent && !showInfo { idleText }
                bottomChrome
            }

            if showHUD {
                DiagnosticHUD(
                    audioProcessor: audioProcessor,
                    captureManager: captureManager,
                    colorProfileStore: colorProfileStore
                )
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            if showInfo {
                InfoOverlay(onClose: { showInfo = false })
                    .zIndex(100)
                    .transition(.opacity)
            }

            if !isGranted {
                PermissionOverlay(
                    state: captureManager.permissionState,
                    onRequestPermission: { captureManager.requestPermissionAndStart() }
                )
                .zIndex(50)
            }

            // Hidden buttons purely to register global keyboard shortcuts —
            // more reliable than manual key-event/focus handling in SwiftUI
            // on macOS, since keyboardShortcut() goes through the responder
            // chain's command system rather than requiring first responder focus.
            // allowsHitTesting(false) so they never steal clicks from the chrome
            // or the info overlay's close button.
            Group {
                Button("") { showHUD.toggle() }
                    .keyboardShortcut("d", modifiers: [])
                Button("") { flatColorMode.toggle() }
                    .keyboardShortcut("t", modifiers: [])
                Button("") { if showInfo { showInfo = false } }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
        // Hover drives chrome + traffic-light fade only. Cursor stays visible
        // so Field/Profile controls remain usable. `ignoresSafeArea` is
        // essential: without it the tracking view is inset by the window's
        // safe area, so moving the pointer down onto the bottom switcher row
        // exited the tracked region and faded the chrome out from under the
        // click. Full-bleed tracking keeps the controls up while you use them.
        .background(
            HoverTrackingArea { hovering in
                isHovering = hovering
            }
            .ignoresSafeArea()
        )
        .background(WindowButtonsFader(visible: isHovering))
        // Wire audio samples from capture → processor.
        .onChange(of: captureManager.isCapturing) { _, capturing in
            if capturing {
                captureManager.onAudioSamples = { [weak audioProcessor] samples in
                    audioProcessor?.process(samples)
                }
            }
        }
        // Set up the wire on first render too (if already capturing).
        .task {
            captureManager.onAudioSamples = { [weak audioProcessor] samples in
                audioProcessor?.process(samples)
            }
        }
    }

    // MARK: - Chrome Group A — top bar

    private var topBar: some View {
        HStack(alignment: .center, spacing: 16) {
            Text("HUE")
                .font(.archivo(.semibold, size: 12))
                .tracking(12 * 0.42)
                .foregroundStyle(Color.white.opacity(0.78))

            Spacer()

            HStack(spacing: 9) {
                Rectangle()
                    .fill(audioProcessor.latestFeatures.isSilent ? Color.white.opacity(0.3) : Color.hueAccent)
                    .frame(width: 6, height: 6)
                Text(audioProcessor.latestFeatures.isSilent ? "NO AUDIO" : "LISTENING")
                    .font(.archivo(.semibold, size: 10))
                    .tracking(10 * 0.20)
                    .foregroundStyle(Color.white.opacity(0.5))
            }

            MiniWindowButton {
                openWindow(id: "mini")
                NSApp.activate(ignoringOtherApps: true)
            }

            InfoButton { showInfo = true }
        }
        .padding(.top, 10)
        .padding(.leading, 108)
        .padding(.trailing, 20)
        .frame(maxWidth: .infinity, alignment: .top)
        .opacity((isHovering || showInfo) ? 1 : 0)
        .animation(.easeInOut(duration: 0.26), value: isHovering)
        .animation(.easeInOut(duration: 0.26), value: showInfo)
        // Never steal clicks while the info overlay is open — its close button
        // lives in the same top-trailing corner as this bar.
        .allowsHitTesting(isHovering && !showInfo)
    }

    // MARK: - Idle text

    private var idleText: some View {
        Text("NOTHING IS PLAYING")
            .font(.archivo(.semibold, size: 11))
            .tracking(11 * 0.34)
            .foregroundStyle(Color.white.opacity(0.17))
            .padding(.leading, 108)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .allowsHitTesting(false)
    }

    // MARK: - Chrome Group B — bottom strip

    private var bottomChrome: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 40) {
                    metersRow
                    Spacer(minLength: 24)
                    factsRow
                }
                VStack(alignment: .leading, spacing: 16) {
                    metersRow
                    factsRow
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 16)

            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(height: 1)
                .padding(.horizontal, 28)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 0) {
                    fieldSwitcherGroup
                    chromeDivider
                    profileSwitcherGroup
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 14) {
                    fieldSwitcherGroup
                    profileSwitcherGroup
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)
            .padding(.bottom, 16)
        }
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.72), Color.black.opacity(0.16)],
                startPoint: .bottom, endPoint: .top
            )
        )
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.16)).frame(height: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .opacity(isHovering ? 1 : 0)
        .animation(.easeInOut(duration: 0.26), value: isHovering)
        .allowsHitTesting(isHovering && !showInfo)
    }

    private var metersRow: some View {
        HStack(spacing: 24) {
            meterView(label: "L ← PITCH", value: meterValues.l)
            meterView(label: "H ← WARMTH", value: meterValues.h)
            meterView(label: "C ← AROUSAL", value: meterValues.c)
        }
    }

    private var factsRow: some View {
        HStack(spacing: 28) {
            factView(label: "KEY", value: keyText)
            factView(label: "TEMPO", value: tempoText)
            factView(label: "VALENCE", value: valenceText)
        }
    }

    private var fieldSwitcherGroup: some View {
        switcherGroup(title: "FIELD") {
            ForEach(FieldMode.allCases) { mode in
                SwitcherButton(
                    label: mode.rawValue.uppercased(),
                    isActive: colorProfileStore.field == mode
                ) {
                    colorProfileStore.field = mode
                }
            }
        }
    }

    private var profileSwitcherGroup: some View {
        switcherGroup(title: "PROFILE") {
            ForEach(ColorProfile.allCases) { profile in
                SwitcherButton(
                    label: profile.chromeLabel,
                    isActive: colorProfileStore.profile == profile
                ) {
                    colorProfileStore.profile = profile
                }
            }
        }
    }

    private var chromeDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(width: 1, height: 28)
            .padding(.horizontal, 28)
    }

    private func switcherGroup<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Text(title)
                .font(.archivo(.semibold, size: 9))
                .tracking(9 * 0.22)
                .foregroundStyle(Color.white.opacity(0.4))
                .fixedSize()
            HStack(spacing: 18) {
                content()
            }
        }
    }

    /// Fixed track width (matches the meter's own frame below) instead of a
    /// `GeometryReader` — a bare `GeometryReader` inside a `ZStack` sibling
    /// reports back whatever height/width is *offered* to it, and in this
    /// ZStack that offer turned out to be effectively unbounded, ballooning
    /// this whole row's height and shoving it up near the top of the window
    /// instead of hugging the 2pt track. The width is already a known
    /// constant here, so there's no need for GeometryReader at all.
    private func meterView(label: String, value: Double) -> some View {
        let trackWidth: CGFloat = 82
        return VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.archivo(.semibold, size: 9))
                .tracking(9 * 0.14)
                .foregroundStyle(Color.white.opacity(0.4))
                .fixedSize()
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.18)).frame(width: trackWidth, height: 2)
                Rectangle()
                    .fill(Color.hueAccent)
                    .frame(width: trackWidth * CGFloat(value), height: 2)
                    .animation(.linear(duration: 0.2), value: value)
            }
            .frame(width: trackWidth, height: 2)
        }
        .frame(width: trackWidth, alignment: .leading)
    }

    private func factView(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.archivo(.semibold, size: 9))
                .tracking(9 * 0.22)
                .foregroundStyle(Color.white.opacity(0.4))
            Text(value)
                .font(.archivo(.medium, size: 14))
                .foregroundStyle(Color.white.opacity(0.9))
                .fixedSize()
        }
    }

    // MARK: - Derived display values
    //
    // Mirrors the exact quantities the design handoff specifies for these
    // readouts (design_handoff_hue_canvas/README.md, "Colour — OkLCh": "the
    // three HUD meters display, in order, L, warmCool and
    // (0.4+0.6*valence01)*(0.5+0.5*arousal)") — not literal re-derivations
    // for their own sake, this is what the spec calls for.

    private var meterValues: (l: Double, h: Double, c: Double) {
        let features = audioProcessor.latestFeatures
        guard !features.isSilent else { return (0, 0, 0) }
        let mapped = PerceptualMapper.map(features: features, profile: colorProfileStore.profile)
        let valence01 = Double(max(0, min(1, features.valence)))
        let centroid  = Double(max(0, min(1, features.spectralCentroid)))
        let arousal   = Double(max(0, min(1, features.arousal)))
        let warmCool  = max(0, min(1, 0.6 * centroid + 0.4 * valence01))
        let energy    = max(0, min(1, (0.4 + 0.6 * valence01) * (0.5 + 0.5 * arousal)))
        return (Double(mapped.L), warmCool, energy)
    }

    private var keyText: String {
        let features = audioProcessor.latestFeatures
        guard !features.isSilent else { return "—" }
        // Below ~0.62 the detector is guessing; don't print a fake key.
        guard features.keyConfidence >= 0.55 else { return "—" }
        return "\(NoteColorTables.noteNames[features.keyPitchClass]) \(features.isMajor ? "major" : "minor")"
    }

    private var tempoText: String {
        let features = audioProcessor.latestFeatures
        guard !features.isSilent else { return "—" }
        return "\(Int(60 + features.tempoNorm * 120)) BPM"
    }

    private var valenceText: String {
        let features = audioProcessor.latestFeatures
        guard !features.isSilent else { return "—" }
        guard features.keyConfidence >= 0.55 else { return "—" }
        return features.isMajor ? "Major · bright" : "Minor · dark"
    }
}

// MARK: - SwitcherButton

/// Field/Profile switcher button — 11pt Archivo 600, 2px bottom border,
/// accent when active, white on hover, no fills/pills/rounded corners
/// anywhere (design_handoff_hue_canvas/README.md, "Switcher buttons").
private struct SwitcherButton: View {
    let label: String
    let isActive: Bool
    let action: () -> Void

    @State private var isHoveringButton = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.archivo(.semibold, size: 11))
                .tracking(11 * 0.13)
                .foregroundStyle(textColor)
                .fixedSize()
                .padding(.horizontal, 2)
                .padding(.vertical, 6)
                .padding(.bottom, 2)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(isActive ? Color.hueAccent : .clear)
                        .frame(height: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHoveringButton = $0 }
        .animation(.easeInOut(duration: 0.16), value: isHoveringButton)
    }

    private var textColor: Color {
        if isActive { return .white }
        return isHoveringButton ? .white : Color.white.opacity(0.42)
    }
}

// MARK: - MiniWindowButton

/// Compact picture-in-picture control — opens the always-on-top mini field.
private struct MiniWindowButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            LucideShape(paths: LucideIcon.pictureInPicture)
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
        .help("Show Mini")
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.16), value: isHovering)
    }
}
