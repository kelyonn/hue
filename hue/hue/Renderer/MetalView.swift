import MetalKit
import SwiftUI

// MARK: - MetalView

/// Bridges the AppKit `MTKView` into the SwiftUI hierarchy via `NSViewRepresentable`.
///
/// The `MetalRenderer` (coordinator) drives the `MTKViewDelegate` draw loop at 60 FPS
/// and updates GPU buffers with the latest `AudioFeatures` from `AudioProcessor`.
struct MetalView: NSViewRepresentable {

    // MARK: - Dependencies

    /// Observed for new AudioFeatures on every SwiftUI update cycle.
    @ObservedObject var audioProcessor: AudioProcessor

    /// The active note→color profile (§6) and field mode. Read every frame by MetalRenderer.
    @ObservedObject var colorProfileStore: ColorProfileStore

    /// True while the permission overlay's scrim is showing — dims the field
    /// to 50% brightness behind it (design_handoff_hue_canvas/README.md,
    /// "3. Permission").
    var dimmed: Bool = false

    /// Display refresh target. Main canvas stays at 60; the always-on-top mini
    /// window uses 30 so two MTKViews don't double GPU cost for no gain.
    var preferredFramesPerSecond: Int = 60

    // MARK: - NSViewRepresentable

    func makeCoordinator() -> MetalRenderer {
        MetalRenderer(audioProcessor: audioProcessor, colorProfileStore: colorProfileStore)
    }

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()

        guard let device = context.coordinator.device else {
            fatalError("[MetalView] No Metal device available on this machine.")
        }

        mtkView.device                  = device
        mtkView.delegate                = context.coordinator

        // Continuous, timer-driven render loop at the requested refresh rate.
        mtkView.isPaused                = false
        mtkView.enableSetNeedsDisplay   = false
        mtkView.preferredFramesPerSecond = preferredFramesPerSecond

        // Pixel format — standard BGRA8 is universally supported.
        mtkView.colorPixelFormat        = .bgra8Unorm
        mtkView.clearColor              = MTLClearColorMake(0, 0, 0, 1)

        // Framebuffer-only; we don't need depth/stencil for 2D shader art.
        mtkView.depthStencilPixelFormat = .invalid

        // Required for EDR / Pro Display XDR if we later add HDR support.
        mtkView.layer?.wantsExtendedDynamicRangeContent = false

        // Avoid AppKit/SwiftUI fighting over intrinsic size for a full-bleed
        // canvas — the parent ZStack owns sizing.
        mtkView.translatesAutoresizingMaskIntoConstraints = true
        mtkView.autoresizingMask = [.width, .height]

        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        // The coordinator (MetalRenderer) reads AudioProcessor.rawLatestFeatures
        // directly on each draw(in:) call — an un-throttled, un-published copy
        // updated every audio callback, so the renderer always sees the
        // freshest value with no extra hop. It intentionally does NOT read the
        // `@Published latestFeatures` twin, which is throttled to ~60 Hz
        // publish and exists only so SwiftUI observers (DiagnosticHUD,
        // ContentView's flat-color mode) don't re-render on every single
        // audio callback.
        context.coordinator.dim = dimmed ? 0.5 : 1.0
        nsView.preferredFramesPerSecond = preferredFramesPerSecond
    }
}
