import SwiftUI
import AppKit

// MARK: - MiniContentView

/// Always-on-top corner widget — the Metal field only. Hover reveals a thin
/// status strip and a way back to the main window. Permission, meters, and
/// Field/Profile controls stay on the main canvas.
struct MiniContentView: View {

    @EnvironmentObject private var captureManager: AudioCaptureManager
    @EnvironmentObject private var audioProcessor: AudioProcessor
    @EnvironmentObject private var colorProfileStore: ColorProfileStore
    @Environment(\.openWindow) private var openWindow

    @State private var isHovering = false

    private var isGranted: Bool { captureManager.permissionState == .granted }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            MetalView(
                audioProcessor: audioProcessor,
                colorProfileStore: colorProfileStore,
                dimmed: !isGranted,
                preferredFramesPerSecond: 30
            )
            .ignoresSafeArea()

            hoverChrome
        }
        .background(
            HoverTrackingArea { hovering in
                isHovering = hovering
            }
            .ignoresSafeArea()
        )
        .background(WindowButtonsFader(visible: isHovering))
        .background(FloatingWindowConfigurator())
    }

    // MARK: - Hover chrome

    private var hoverChrome: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("HUE")
                .font(.archivo(.semibold, size: 10))
                .tracking(10 * 0.42)
                .foregroundStyle(Color.white.opacity(0.78))

            Spacer(minLength: 0)

            statusChip

            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Text(isGranted ? "OPEN MAIN" : "ALLOW")
                    .font(.archivo(.semibold, size: 9))
                    .tracking(9 * 0.16)
                    .foregroundStyle(Color.white.opacity(0.72))
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(isGranted ? "Open the main Hue window" : "Open Hue to grant Screen Recording")
        }
        .padding(.top, 8)
        .padding(.leading, 72)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .top)
        .opacity(isHovering ? 1 : 0)
        .animation(.easeInOut(duration: 0.26), value: isHovering)
        .allowsHitTesting(isHovering)
    }

    private var statusChip: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(statusDotColor)
                .frame(width: 5, height: 5)
            Text(statusLabel)
                .font(.archivo(.semibold, size: 9))
                .tracking(9 * 0.18)
                .foregroundStyle(Color.white.opacity(0.5))
        }
    }

    private var statusLabel: String {
        guard isGranted else { return "SETUP" }
        return audioProcessor.latestFeatures.isSilent ? "NO AUDIO" : "LISTENING"
    }

    private var statusDotColor: Color {
        guard isGranted else { return Color.white.opacity(0.3) }
        return audioProcessor.latestFeatures.isSilent ? Color.white.opacity(0.3) : Color.hueAccent
    }
}
