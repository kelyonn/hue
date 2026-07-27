import SwiftUI
import AppKit

// MARK: - MenuBarContentView

/// Menu bar dropdown — status, mini/main window controls, quick profile
/// switch, Preferences, Quit.
///
/// "Now playing" status is deliberately generic ("Listening" / "Idle"), not
/// the design mockup's "Listening — Spotify": system-wide ScreenCaptureKit
/// capture mixes all audio together and has no way to know which app produced
/// it. Naming the app would require the private/undocumented MediaRemote
/// framework — fragile and risky for distribution. Decided with the user.
struct MenuBarContentView: View {
    @ObservedObject var captureManager: AudioCaptureManager
    @ObservedObject var colorProfileStore: ColorProfileStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(captureManager.isCapturing ? "Listening" : "Idle")

        Divider()

        Button("Show Mini") {
            openWindow(id: "mini")
            NSApp.activate(ignoringOtherApps: true)
        }

        Button("Show Main Window") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Menu("Color Profile") {
            ForEach(ColorProfile.allCases) { profile in
                Button {
                    colorProfileStore.profile = profile
                } label: {
                    if colorProfileStore.profile == profile {
                        Label(profile.rawValue, systemImage: "checkmark")
                    } else {
                        Text(profile.rawValue)
                    }
                }
            }
        }

        Divider()

        Button("Preferences…") { openSettings() }
            .keyboardShortcut(",", modifiers: .command)

        Button("Quit Hue") {
            captureManager.stopAndWait()
            NSApplication.shared.terminate(nil)
        }
            .keyboardShortcut("q", modifiers: .command)
    }
}
