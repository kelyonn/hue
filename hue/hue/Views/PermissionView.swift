import SwiftUI
import AppKit

// MARK: - PermissionOverlay

/// The permission screen — replaces the previous 3-step onboarding flow
/// (Welcome → Science → Permission cards). The design has no separate steps:
/// a single dense, flush-left content block over the still-running live
/// field, dimmed to 50% under a dark scrim
/// (design_handoff_hue_canvas/README.md, "3. Permission").
///
/// Unlike the old flow, the system permission dialog is not auto-fired on
/// appear — the design shows one persistent, user-initiated button.
struct PermissionOverlay: View {
    let state: AudioCaptureManager.PermissionState
    let onRequestPermission: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.66)

            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("hue")
                        .font(.archivo(.semibold, size: 52))
                        .tracking(52 * 0.30)
                        .foregroundStyle(.white)
                    Text("SYNESTHESIA SIMULATOR")
                        .font(.archivo(.semibold, size: 10))
                        .tracking(10 * 0.32)
                        .foregroundStyle(Color.white.opacity(0.42))
                }

                Rectangle()
                    .fill(Color.white.opacity(0.22))
                    .frame(height: 1)
                    .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 22) {
                    permissionRow(
                        icon: LucideIcon.audioWaveform,
                        title: "System audio access",
                        body: "Hue reads whatever is already playing on this Mac. Nothing is recorded, stored or sent."
                    )
                    permissionRow(
                        icon: LucideIcon.eyeOff,
                        title: "No screen is captured",
                        body: "macOS files audio capture under Screen Recording. Only the audio signal is read."
                    )
                    permissionRow(
                        icon: LucideIcon.shieldCheck,
                        title: "Entirely on-device",
                        body: "All analysis runs locally. No accounts, no servers, no network calls."
                    )
                }

                PrimaryButton(state: state, onRequestPermission: onRequestPermission)
                    .padding(.top, 4)

                Text(statusLine)
                    .font(.system(size: 11))
                    .tracking(11 * 0.14)
                    .foregroundStyle(Color.white.opacity(0.32))
            }
            .frame(width: 560, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, 96)
            .padding(.trailing, 48)
        }
        .ignoresSafeArea()
    }

    private var statusLine: String {
        state == .denied ? "OPEN SYSTEM SETTINGS TO ALLOW ACCESS" : "WAITING FOR PERMISSION…"
    }

    private func permissionRow(icon: [String], title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            LucideShape(paths: icon)
                .stroke(Color.hueAccent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 18, height: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.archivo(.semibold, size: 14))
                    .foregroundStyle(Color.white.opacity(0.92))
                Text(body)
                    .font(.archivo(.regular, size: 13))
                    .lineSpacing(13 * 0.5)
                    .foregroundStyle(Color.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - PrimaryButton

/// "Allow audio access" — flush-left label, icon pushed to the far edge via
/// `space-between` (Modernist's rule: a wide button's label never centres).
private struct PrimaryButton: View {
    let state: AudioCaptureManager.PermissionState
    let onRequestPermission: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: handleTap) {
            HStack {
                Text("Allow audio access")
                    .font(.archivo(.semibold, size: 14))
                    .foregroundStyle(.white)
                Spacer(minLength: 40)
                LucideShape(paths: LucideIcon.arrowUpRight)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .frame(width: 16, height: 16)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 18)
            .frame(minWidth: 260)
            .background(isHovering ? Color.hueAccentHover : Color.hueAccent)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.16), value: isHovering)
    }

    private func handleTap() {
        if state == .denied {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        } else {
            onRequestPermission()
        }
    }
}
