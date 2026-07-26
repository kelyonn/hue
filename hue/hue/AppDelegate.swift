import AppKit
import Combine

// MARK: - AppDelegate

/// Stops ScreenCaptureKit before the process exits, and quits when the last
/// window closes. Without this, closing the window left the MenuBarExtra
/// alive with an active `SCStream` — which is what keeps macOS's purple
/// "Screen Recording / Screen Sharing" indicator lit after the user thinks
/// they've quit.
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Set from `HueApp` once the capture manager exists, so terminate can
    /// tear the stream down before the process is gone.
    weak var captureManager: AudioCaptureManager?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        captureManager?.stopAndWait()
    }
}
