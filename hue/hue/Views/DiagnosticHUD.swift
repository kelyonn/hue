import SwiftUI

// MARK: - DiagnosticHUD

/// Live readout of everything the chromesthesia engine is detecting and
/// computing. Collapsed by default to a small pill toggle — click to expand
/// the full panel, click again (or the chevron) to collapse. The `D` key
/// still hides/shows the toggle entirely.
struct DiagnosticHUD: View {
    @ObservedObject var audioProcessor: AudioProcessor
    @ObservedObject var captureManager: AudioCaptureManager
    @ObservedObject var colorProfileStore: ColorProfileStore

    @State private var isExpanded = false
    @State private var isHovering = false

    // Brand palette — the same three hues as the wordmark gradient and the
    // app icon's blobs, reused here so bass/mids/treble read as "on-brand"
    // rather than raw debug-primary red/green/cyan.
    private let bassTint   = Color(hue: 0.76, saturation: 0.62, brightness: 0.92)
    private let midsTint   = Color(hue: 0.50, saturation: 0.52, brightness: 0.90)
    private let trebleTint = Color(hue: 0.14, saturation: 0.70, brightness: 0.97)

    var body: some View {
        Group {
            if isExpanded {
                expandedPanel
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
            } else {
                collapsedToggle
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: isExpanded)
    }

    // MARK: - Collapsed

    private var collapsedToggle: some View {
        Button {
            isExpanded = true
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(captureManager.isCapturing ? Color.green : .white.opacity(0.35))
                    .frame(width: 6, height: 6)
                Text("HUD")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(1.2)
            }
            .foregroundStyle(.white.opacity(isHovering ? 0.85 : 0.35))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial.opacity(isHovering ? 0.7 : 0.3))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.2), value: isHovering)
    }

    // MARK: - Expanded

    private var expandedPanel: some View {
        let features = audioProcessor.latestFeatures
        let mapped = PerceptualMapper.map(
            features: features,
            profile: colorProfileStore.profile
        )

        return VStack(alignment: .leading, spacing: 13) {

            // ── Status + collapse ──
            HStack(spacing: 7) {
                Button {
                    isExpanded = false
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)

                Circle()
                    .fill(captureManager.isCapturing ? Color.green : .white.opacity(0.35))
                    .frame(width: 5.5, height: 5.5)
                Text(captureManager.isCapturing ? "LISTENING" : "IDLE")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.65))
                Spacer()
                Text(buildTimestamp)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.25))
            }

            VStack(alignment: .leading, spacing: 7) {
                sectionLabel("SIGNAL")
                level("RMS",   features.rms,               tint: .white.opacity(0.75))
                level("BASS",  features.bass,               tint: bassTint)
                level("MIDS",  features.mids,               tint: midsTint)
                level("TREB",  features.treble,             tint: trebleTint)
                level("BRIGHT", features.spectralCentroid,  tint: .white.opacity(0.5))
            }

            hairline

            VStack(alignment: .leading, spacing: 7) {
                sectionLabel("TONALITY")
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(NoteColorTables.noteNames[features.keyPitchClass])
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                    Text(features.isMajor ? "major" : "minor")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    Text(pct(features.keyConfidence))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                }

                HStack(spacing: 0) {
                    statTile("VALENCE", fmt(features.valence))
                    statTile("AROUSAL", fmt(features.arousal))
                    statTile("TEMPO", "\(Int(60 + features.tempoNorm * 120))")
                }

                Text("dominant note  ·  \(NoteColorTables.noteNames[features.dominantPitchClass])")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.38))
            }

            hairline

            VStack(alignment: .leading, spacing: 7) {
                sectionLabel("MAPPED COLOR")
                HStack(spacing: 10) {
                    Circle()
                        .fill(mapped.swiftUIColor)
                        .frame(width: 24, height: 24)
                        .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("L \(fmt(mapped.L))  C \(fmt(mapped.C))  H \(Int(mapped.h * 180 / .pi))°")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                        Text(colorProfileStore.profile.rawValue)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.48))
                    }
                }
            }

            Text("D  ·  hide          T  ·  flat-color mode")
                .font(.system(size: 8.5))
                .foregroundStyle(.white.opacity(0.2))
        }
        .padding(14)
        .frame(width: 228, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.14), .white.opacity(0.03)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
    }

    // MARK: - Pieces

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .tracking(1.5)
            .foregroundStyle(.white.opacity(0.3))
    }

    private var hairline: some View {
        LinearGradient(
            colors: [.clear, .white.opacity(0.12), .clear],
            startPoint: .leading, endPoint: .trailing
        )
        .frame(height: 1)
    }

    private func level(_ label: String, _ value: Float, tint: Color) -> some View {
        HStack(spacing: 7) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .tracking(0.3)
                .frame(width: 36, alignment: .leading)
                .foregroundStyle(.white.opacity(0.48))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule()
                        .fill(tint)
                        .frame(width: geo.size.width * CGFloat(min(1, max(0, value))))
                }
            }
            .frame(height: 4.5)
            Text(fmt(value))
                .font(.system(size: 9, design: .monospaced))
                .frame(width: 26, alignment: .trailing)
                .foregroundStyle(.white.opacity(0.38))
        }
    }

    private func statTile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 7.5, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(.white.opacity(0.28))
            Text(value)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helpers

    private func fmt(_ v: Float) -> String { String(format: "%.2f", v) }
    private func pct(_ v: Float) -> String { String(format: "%.0f%%", v * 100) }

    /// The running binary's own last-modified time — proves a fresh build is
    /// actually the one running, without needing any build-phase scripting.
    private var buildTimestamp: String {
        guard let url = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else { return "build ?" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
