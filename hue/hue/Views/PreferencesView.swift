import SwiftUI

// MARK: - PreferencesView

/// Native macOS Preferences window (Cmd+,) — a radio-list of the three
/// note→color profiles (Emotion/Scriabin/Rimsky-Korsakov). The in-window
/// Field/Profile switcher (ContentView's bottom chrome) covers everyday
/// switching; this is reachable via the menu bar and Cmd-,.
struct PreferencesView: View {
    @ObservedObject var store: ColorProfileStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Color Profile")
                .font(.system(size: 16, weight: .semibold))
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 4)

            Text("Emotion is the population-level default. Named note-color systems are offered, but framed as someone else's private mapping — never the default truth.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)

            VStack(spacing: 0) {
                ForEach(ColorProfile.allCases) { profile in
                    ProfileRow(profile: profile, isSelected: store.profile == profile) {
                        store.profile = profile
                    }
                    if profile != ColorProfile.allCases.last {
                        Divider().padding(.leading, 24)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(width: 460, height: 380)
    }
}

// MARK: - ProfileRow

private struct ProfileRow: View {
    let profile: ColorProfile
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: 1.5)
                    .background(Circle().fill(isSelected ? Color.accentColor : .clear))
                    .frame(width: 14, height: 14)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(profile.rawValue)
                            .font(.system(size: 13, weight: .medium))
                        if profile == .emotion {
                            Text("DEFAULT")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(profile.subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
