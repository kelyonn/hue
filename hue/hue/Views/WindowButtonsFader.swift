import SwiftUI
import AppKit

// MARK: - WindowButtonsFader

/// Fades the *real* traffic-light window buttons in sync with hover chrome.
///
/// The design handoff is explicit: "these are the standard macOS
/// hidden-titlebar controls — do not draw them yourself, just let the
/// titlebar reveal." SwiftUI has no direct control over
/// `NSWindow.standardWindowButton(_:)`'s opacity, so this reaches the hosting
/// `NSWindow` via an invisible `NSViewRepresentable` — the standard bridging
/// pattern for exactly this kind of AppKit-only access.
struct WindowButtonsFader: NSViewRepresentable {
    var visible: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // `view.window` is nil until the next runloop tick, before this view
        // has actually been inserted into the real window's view hierarchy.
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: nsView.window)
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.26
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for type in buttonTypes {
                window.standardWindowButton(type)?.animator().alphaValue = visible ? 1 : 0
            }
        }
    }
}
