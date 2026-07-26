import SwiftUI
import AppKit

// MARK: - HoverTrackingArea

/// A real `NSTrackingArea`-based mouse enter/exit tracker.
///
/// SwiftUI's `.onHover` can drop exit callbacks on macOS for full-bleed,
/// layered content (borderless, `ignoresSafeArea`, Metal underneath, stacked
/// chrome). This uses the AppKit primitive `.onHover` wraps so enter/exit
/// stays reliable for chrome fade and traffic-light opacity.
struct HoverTrackingArea: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var trackingArea: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) { onChange?(true) }
        override func mouseExited(with event: NSEvent) { onChange?(false) }
    }
}
