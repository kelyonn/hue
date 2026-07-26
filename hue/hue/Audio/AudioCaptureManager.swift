/*
 Copyright © 2026 kelyonn. All rights reserved.

 This file is part of Hue. See the LICENSE at the repository root.
 Unauthorized copying, modification, or reuse in another product is prohibited.
*/
import ScreenCaptureKit
import CoreMedia
import AudioToolbox
import Combine

// MARK: - AudioCaptureManager

/// Taps into the macOS system audio output using ScreenCaptureKit.
///
/// Works with **any** audio source on the system (Spotify, Apple Music, Safari, DAWs, etc.)
/// without requiring third-party virtual audio drivers.
///
/// ## Usage
/// 1. Call `requestPermissionAndStart()` on first launch.
/// 2. Assign `onAudioSamples` to receive mono Float32 PCM samples per frame.
///
/// ## ScreenCaptureKit "audio-only" workaround
/// SCKit is fundamentally a screen-capture framework — it requires a content filter.
/// We target the main display with a 2×2 video configuration to minimize overhead,
/// and simply ignore the video callback entirely.
@MainActor
final class AudioCaptureManager: NSObject, ObservableObject {

    // MARK: - Public State

    @Published private(set) var permissionState: PermissionState = .unknown
    @Published private(set) var isCapturing = false

    enum PermissionState {
        case unknown, granted, denied
    }

    /// When false, an unexpected stream stop must not auto-reconnect —
    /// used so intentional `stop()` / quit don't revive the purple indicator.
    private var wantsCapture = false

    // MARK: - Callbacks

    /// Called on the capture's background `audioQueue` for every captured audio
    /// frame — **never on the main thread**. Delivers already-downmixed mono
    /// Float32 PCM (see `extractMonoSamples`), so `AudioProcessor.process`
    /// doesn't need to know or guess about channel layout.
    ///
    /// `nonisolated(unsafe)`: this class is `@MainActor`, but the property is
    /// read from `stream(_:didOutputSampleBuffer:of:)`, which genuinely runs on
    /// `audioQueue` (the `sampleHandlerQueue` passed to `addStreamOutput`) —
    /// hopping to `@MainActor` just to read a closure reference before bouncing
    /// back off it would put the FFT/DSP work the closure triggers back on the
    /// main thread, defeating the whole point of a dedicated audio queue. The
    /// closure is set exactly once from the main actor (`ContentView`, before
    /// capture starts) and never mutated while capture is running, so there is
    /// no concurrent write to race against these reads.
    nonisolated(unsafe) var onAudioSamples: (([Float]) -> Void)?

    // MARK: - Private

    private var stream: SCStream?
    private let audioQueue = DispatchQueue(
        label: "com.hue.audiocapture",
        qos: .userInteractive
    )

    // MARK: - Public API

    /// Check the current permission state and (if granted) start capturing.
    func requestPermissionAndStart() {
        wantsCapture = true
        Task {
            do {
                // Requesting shareable content implicitly triggers the
                // Screen Recording permission dialog on first launch.
                let content = try await SCShareableContent.current
                guard wantsCapture else { return }
                await MainActor.run { self.permissionState = .granted }
                try await startCapture(using: content)
            } catch {
                let scError = error as? SCStreamError
                if scError?.code == .userDeclined {
                    await MainActor.run { self.permissionState = .denied }
                } else {
                    // Permission hasn't been decided yet — treat as unknown
                    print("[AudioCaptureManager] requestPermissionAndStart error: \(error)")
                    await MainActor.run { self.permissionState = .unknown }
                }
            }
        }
    }

    /// Gracefully stop the audio stream (async). Prefer `stopAndWait()` on quit
    /// so the purple Screen Recording indicator clears before the process exits.
    func stop() {
        wantsCapture = false
        let active = stream
        stream = nil
        isCapturing = false
        guard let active else { return }
        Task {
            try? await active.stopCapture()
        }
    }

    /// Stops capture and blocks briefly until ScreenCaptureKit releases the
    /// stream — critical on terminate, otherwise macOS keeps showing the
    /// purple indicator for a dead process.
    func stopAndWait() {
        wantsCapture = false
        let active = stream
        stream = nil
        isCapturing = false
        onAudioSamples = nil
        guard let active else { return }

        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            try? await active.stopCapture()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2.0)
    }

    // MARK: - Private

    private func startCapture(using content: SCShareableContent) async throws {
        guard wantsCapture else { return }
        guard let display = content.displays.first else {
            print("[AudioCaptureManager] No displays found — cannot create content filter.")
            return
        }

        // Target the main display.
        // We exclude all windows so no video frames are meaningfully captured —
        // only the audio pipeline matters.
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()

        // — Audio settings —
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true  // Don't visualize our own audio
        config.sampleRate = 48_000
        config.channelCount = 2  // Stereo; downmixed to mono in extractMonoSamples below

        // — Minimize video overhead —
        // We must provide a video configuration even though we discard all video frames.
        config.width  = 2
        config.height = 2
        // Use a very low frame rate for the dummy video stream
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 FPS video (unused)

        // Replace any leftover stream before starting a new one.
        if let existing = stream {
            stream = nil
            try? await existing.stopCapture()
        }

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await newStream.startCapture()

        guard wantsCapture else {
            try? await newStream.stopCapture()
            return
        }

        self.stream = newStream
        await MainActor.run { self.isCapturing = true }
        print("[AudioCaptureManager] System audio capture started ✓")
    }
}

// MARK: - SCStreamOutput

extension AudioCaptureManager: SCStreamOutput {

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        // Discard video frames entirely.
        guard outputType == .audio else { return }
        guard sampleBuffer.isValid else { return }

        guard let mono = extractMonoSamples(from: sampleBuffer) else { return }

        // Deliver directly on this queue (`audioQueue`, the sampleHandlerQueue
        // passed to `addStreamOutput`) — no actor hop. This is what actually
        // keeps FFT/DSP work off the main thread; see `onAudioSamples`'s doc
        // comment and `AudioProcessor`'s "not main thread" class comment.
        onAudioSamples?(mono)
    }

    /// Extracts a mono Float32 signal from a captured audio `CMSampleBuffer`,
    /// correctly handling **either** interleaved or non-interleaved (planar)
    /// PCM layout.
    ///
    /// The previous implementation reinterpreted the raw `CMBlockBuffer` bytes
    /// as flat interleaved stereo (`stereo[i*2] / stereo[i*2+1]`) with no format
    /// check. ScreenCaptureKit does not guarantee interleaved delivery — if the
    /// buffer is actually planar (non-interleaved: all of channel 0, then all of
    /// channel 1), that indexing silently interleaves *adjacent left-channel*
    /// samples as fake L/R pairs, corrupting the downmix while still looking
    /// "reactive" enough that the bug is easy to miss by ear.
    ///
    /// `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer` is the API
    /// Apple provides specifically to demux a `CMSampleBuffer` into a
    /// correctly-laid-out `AudioBufferList` regardless of the underlying
    /// interleaving — one `AudioBuffer` for interleaved PCM, one per channel
    /// for planar — so we read the real format and branch instead of assuming.
    nonisolated private func extractMonoSamples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return nil }
        let asbd = asbdPointer.pointee

        let channelCount = Int(asbd.mChannelsPerFrame)
        guard channelCount > 0,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        else { return nil }
        let isInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        // Non-interleaved PCM is delivered as one AudioBuffer per channel;
        // interleaved PCM as a single AudioBuffer holding all channels.
        let bufferCount = isInterleaved ? 1 : channelCount
        let audioBufferList = AudioBufferList.allocate(maximumBuffers: bufferCount)
        defer { free(audioBufferList.unsafeMutablePointer) }

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: bufferCount),
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        var mono = [Float](repeating: 0, count: frameCount)
        let invChannelCount = 1.0 / Float(channelCount)

        if isInterleaved {
            guard let data = audioBufferList[0].mData else { return nil }
            let floats = data.assumingMemoryBound(to: Float.self)
            guard Int(audioBufferList[0].mDataByteSize) / MemoryLayout<Float>.size
                    >= frameCount * channelCount else { return nil }
            for frame in 0..<frameCount {
                var sum: Float = 0
                let base = frame * channelCount
                for ch in 0..<channelCount { sum += floats[base + ch] }
                mono[frame] = sum * invChannelCount
            }
        } else {
            var channelPointers: [UnsafePointer<Float>] = []
            channelPointers.reserveCapacity(channelCount)
            for ch in 0..<channelCount {
                guard let data = audioBufferList[ch].mData,
                      Int(audioBufferList[ch].mDataByteSize) / MemoryLayout<Float>.size >= frameCount
                else { return nil }
                channelPointers.append(data.assumingMemoryBound(to: Float.self))
            }
            for frame in 0..<frameCount {
                var sum: Float = 0
                for ch in 0..<channelCount { sum += channelPointers[ch][frame] }
                mono[frame] = sum * invChannelCount
            }
        }

        return mono
    }
}

// MARK: - SCStreamDelegate

extension AudioCaptureManager: SCStreamDelegate {

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[AudioCaptureManager] Stream stopped with error: \(error)")
        Task { @MainActor in
            self.isCapturing = false
            self.stream = nil
            // Only reconnect if the user still wants us listening — never after
            // an intentional stop/quit, which would revive the purple indicator.
            guard self.wantsCapture else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard self.wantsCapture else { return }
            self.requestPermissionAndStart()
        }
    }
}
