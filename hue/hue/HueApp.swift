import SwiftUI

// MARK: - HueApp

@main
struct HueApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Top-level owned objects injected into the entire environment.
    @StateObject private var captureManager     = AudioCaptureManager()
    @StateObject private var audioProcessor     = AudioProcessor()
    @StateObject private var colorProfileStore  = ColorProfileStore()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(captureManager)
                .environmentObject(audioProcessor)
                .environmentObject(colorProfileStore)
                // Explicit min size — `.contentMinSize` without a floor fights
                // full-bleed ZStacks (Metal + chrome) and can crash AppKit
                // mid-layout via `_postWindowNeedsUpdateConstraints`.
                .frame(minWidth: 780, minHeight: 520)
                .navigationTitle("")
                .onAppear {
                    // So closing / quitting can tear down ScreenCaptureKit
                    // before the process exits (clears the purple indicator).
                    appDelegate.captureManager = captureManager
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.automatic)
        .defaultSize(width: 960, height: 640)
        .commands {
            // Remove default File menu items that don't apply.
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .saveItem) { }
            CommandGroup(replacing: .printItem) { }
        }

        // Always-on-top corner widget — field only. Single instance via `Window`.
        Window("Mini", id: "mini") {
            MiniContentView()
                .environmentObject(captureManager)
                .environmentObject(audioProcessor)
                .environmentObject(colorProfileStore)
                .frame(width: 320, height: 200)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 320, height: 200)
        .defaultPosition(.bottomTrailing)

        // Standard macOS Preferences window (Cmd+,) — hosts the profile
        // radio list, reachable from the menu bar extra and from the
        // in-window Profile switcher (ContentView's bottom chrome).
        Settings {
            PreferencesView(store: colorProfileStore)
        }

        // A second, independent scene — MenuBarExtra doesn't inherit
        // .environmentObject() from WindowGroup above, so dependencies are
        // passed explicitly rather than via environment.
        MenuBarExtra("Hue", systemImage: "waveform.circle.fill") {
            MenuBarContentView(captureManager: captureManager, colorProfileStore: colorProfileStore)
        }
        .menuBarExtraStyle(.menu)
    }
}
