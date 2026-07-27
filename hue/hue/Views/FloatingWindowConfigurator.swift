import SwiftUI
import AppKit

// MARK: - FloatingWindowConfigurator

/// Pins the hosting `NSWindow` above normal app windows so the mini field
/// can sit in a corner like a widget. Same invisible-representable bridge as
/// `WindowButtonsFader` — SwiftUI has no first-class always-on-top API.
struct FloatingWindowConfigurator: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configure(nsView.window)
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.level = .floating
        window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
        window.isMovableByWindowBackground = true
        // Mini is a glanceable widget — zoom/fullscreen aren't useful here.
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }
}
