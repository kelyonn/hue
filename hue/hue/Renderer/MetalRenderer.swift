import MetalKit
import simd

// MARK: - MetalRenderer

/// `MTKViewDelegate` that owns the GPU dye-field simulation + composite
/// render pipeline.
///
/// ## Architecture — curl-noise dye field (Hue.dc.html design handoff)
///
/// **Compute pass** (1 kernel, dispatched every frame):
///   `fieldSim` — velocity computed analytically per-pixel from curl(fbm(p))
///   (no pressure projection, no iteration), advects + decays the previous
///   frame's dye, injects new dye per the active `FieldMode`.
///
/// **Render pass** (fullscreen triangle):
///   `hue_fragment` tone-maps the field: ambient wash → exposure/Reinhard/
///   gamma → treble sparks → vignette → grain → `dim`.
///
/// **Persistence**: two `fieldA`/`fieldB` textures ping-pong every frame — the
/// dye field itself carries the "trail" persistence (unlike the previous
/// architecture, there's no separate feedback-texture blit from the drawable).
final class MetalRenderer: NSObject, MTKViewDelegate {

    // MARK: - Metal Core

    let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?

    private var renderPipeline: MTLRenderPipelineState?
    private var fieldPipeline: MTLComputePipelineState?

    // MARK: - Field Textures (ping-pong)

    private var fieldA: MTLTexture?
    private var fieldB: MTLTexture?
    private var fieldIndex = 0  // 0 = read A / write B, 1 = read B / write A
    private var fieldWidth = 1
    private var fieldHeight = 1

    // MARK: - Performance Budget (Apple Silicon)
    //
    // The field simulation is a single analytic compute pass (no iterative
    // solve), so the only cost knob left is threadgroup size. Tuned for
    // sustained 60 FPS on Apple Silicon (the app's only supported target —
    // see PRD.md §8 for the Intel LOD-fallback option this deliberately skips).

    private let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)

    // MARK: - GPU Buffers

    private var audioBuffer: MTLBuffer?
    private var uniformsBuffer: MTLBuffer?
    private var fieldUniformsBuffer: MTLBuffer?

    // MARK: - State

    private var startTime = Date()
    private weak var audioProcessor: AudioProcessor?
    private weak var colorProfileStore: ColorProfileStore?

    /// 1.0 normally; 0.5 while the permission overlay's scrim is showing.
    /// Set externally by `MetalView.updateNSView` from `ContentView`'s state.
    var dim: Float = 1.0

    // MARK: - Uniform Layouts

    /// Must mirror `Uniforms` in Composite.metal exactly.
    private struct Uniforms {
        var time: Float
        var dim: Float
        var resolution: SIMD2<Float>
    }

    /// Must mirror `FieldUniforms` in FluidCompute.metal exactly.
    private struct FieldUniforms {
        var time: Float
        var resolution: SIMD2<Float>
        var dt: Float
        var mode: Float
    }

    // MARK: - Init

    init(audioProcessor: AudioProcessor, colorProfileStore: ColorProfileStore = ColorProfileStore()) {
        self.audioProcessor = audioProcessor
        self.colorProfileStore = colorProfileStore
        self.device = MTLCreateSystemDefaultDevice()

        guard let device else {
            self.commandQueue = nil
            super.init()
            print("[MetalRenderer] ⚠️ No Metal device found.")
            return
        }

        self.commandQueue = device.makeCommandQueue()
        super.init()

        buildRenderPipeline(device: device)
        buildComputePipeline(device: device)
        buildTextures(device: device)
        buildBuffers(device: device)
    }

    // MARK: - Pipeline Setup

    private func buildRenderPipeline(device: MTLDevice) {
        guard let library = device.makeDefaultLibrary() else {
            print("[MetalRenderer] ⚠️ Failed to load Metal library.")
            return
        }

        guard let vertexFn   = library.makeFunction(name: "hue_vertex"),
              let fragmentFn = library.makeFunction(name: "hue_fragment") else {
            print("[MetalRenderer] ⚠️ Could not find composite shader functions.")
            return
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.label = "HueCompositePipeline"
        desc.vertexFunction = vertexFn
        desc.fragmentFunction = fragmentFn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm

        // Alpha blending
        desc.colorAttachments[0].isBlendingEnabled           = true
        desc.colorAttachments[0].sourceRGBBlendFactor        = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor   = .oneMinusSourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor      = .sourceAlpha
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            renderPipeline = try device.makeRenderPipelineState(descriptor: desc)
            print("[MetalRenderer] Render pipeline built ✓")
        } catch {
            print("[MetalRenderer] ⚠️ Render pipeline error: \(error)")
        }
    }

    private func buildComputePipeline(device: MTLDevice) {
        guard let library = device.makeDefaultLibrary(),
              let fn = library.makeFunction(name: "fieldSim") else {
            print("[MetalRenderer] ⚠️ Missing kernel: fieldSim")
            return
        }
        do {
            fieldPipeline = try device.makeComputePipelineState(function: fn)
            print("[MetalRenderer] Compute pipeline built ✓")
        } catch {
            print("[MetalRenderer] ⚠️ Compute pipeline error: \(error)")
        }
    }

    // MARK: - Texture Setup

    private func buildTextures(device: MTLDevice) {
        // Placeholder small textures — real size is set by
        // `mtkView(_:drawableSizeWillChange:)`, which fires before the first
        // real frame. This just avoids a nil texture in the meantime.
        fieldA = makeTexture(device, width: fieldWidth, height: fieldHeight, format: .rgba16Float, label: "FieldA")
        fieldB = makeTexture(device, width: fieldWidth, height: fieldHeight, format: .rgba16Float, label: "FieldB")
    }

    private func makeTexture(_ device: MTLDevice, width: Int, height: Int, format: MTLPixelFormat, label: String) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        let tex = device.makeTexture(descriptor: desc)
        tex?.label = label
        return tex
    }

    // MARK: - Buffer Setup

    private func buildBuffers(device: MTLDevice) {
        audioBuffer = device.makeBuffer(
            length: MemoryLayout<AudioDataBuffer>.stride,
            options: .storageModeShared
        )
        uniformsBuffer = device.makeBuffer(
            length: MemoryLayout<Uniforms>.stride,
            options: .storageModeShared
        )
        fieldUniformsBuffer = device.makeBuffer(
            length: MemoryLayout<FieldUniforms>.stride,
            options: .storageModeShared
        )
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard let device else { return }
        fieldWidth  = max(1, Int(size.width))
        fieldHeight = max(1, Int(size.height))

        // The field sim runs at native drawable resolution — a single
        // analytic pass is cheap enough that there's no separate low-res
        // grid the way the old iterative solver needed. Recreate at the
        // correct size on every resize (and once up front, since this
        // callback fires before the first real frame).
        fieldA = makeTexture(device, width: fieldWidth, height: fieldHeight, format: .rgba16Float, label: "FieldA")
        fieldB = makeTexture(device, width: fieldWidth, height: fieldHeight, format: .rgba16Float, label: "FieldB")
        fieldIndex = 0
    }

    func draw(in view: MTKView) {
        guard
            let commandQueue,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let renderDescriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable
        else { return }

        let elapsed = Float(Date().timeIntervalSince(startTime))

        // ── Update all GPU buffers ──
        updateAudioBuffer()
        updateUniformsBuffer(viewportSize: view.drawableSize, time: elapsed)
        updateFieldUniformsBuffer(time: elapsed)

        // ── COMPUTE PASS: Field Simulation ──
        dispatchFieldSim(commandBuffer: commandBuffer)

        // ── RENDER PASS: Composite ──
        if let renderPipeline,
           let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderDescriptor) {

            encoder.setRenderPipelineState(renderPipeline)

            encoder.setFragmentBuffer(audioBuffer,    offset: 0, index: 0)
            encoder.setFragmentBuffer(uniformsBuffer, offset: 0, index: 1)

            // After the compute pass, the "current" field is whichever
            // texture fieldSim just wrote into.
            encoder.setFragmentTexture(fieldIndex == 0 ? fieldA : fieldB, index: 0)

            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Field Simulation Dispatch

    private func dispatchFieldSim(commandBuffer: MTLCommandBuffer) {
        guard let pipe = fieldPipeline,
              let fA = fieldA, let fB = fieldB else { return }

        let threadgroups = MTLSize(
            width:  (fieldWidth  + threadsPerGroup.width  - 1) / threadsPerGroup.width,
            height: (fieldHeight + threadsPerGroup.height - 1) / threadsPerGroup.height,
            depth: 1
        )

        let (readTex, writeTex) = fieldIndex == 0 ? (fA, fB) : (fB, fA)

        if let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.setComputePipelineState(pipe)
            enc.setTexture(readTex,  index: 0)
            enc.setTexture(writeTex, index: 1)
            enc.setBuffer(audioBuffer,          offset: 0, index: 0)
            enc.setBuffer(fieldUniformsBuffer,  offset: 0, index: 1)
            enc.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
            enc.endEncoding()
        }

        fieldIndex = 1 - fieldIndex
    }

    // MARK: - Buffer Updates

    private func updateAudioBuffer() {
        guard let audioBuffer else { return }
        // rawLatestFeatures, not the throttled/@Published latestFeatures: the
        // renderer polls once per draw() and wants the freshest value every
        // time, with no Combine involvement. See AudioProcessor's doc comment.
        let features = audioProcessor?.rawLatestFeatures ?? AudioFeatures()
        let profile = colorProfileStore?.profile ?? .emotion
        let mapped = PerceptualMapper.map(features: features, profile: profile)
        var packed = AudioDataBuffer(from: features, mapped: mapped)
        memcpy(audioBuffer.contents(), &packed, MemoryLayout<AudioDataBuffer>.stride)
    }

    private func updateUniformsBuffer(viewportSize: CGSize, time: Float) {
        guard let uniformsBuffer else { return }
        var u = Uniforms(
            time: time,
            dim: dim,
            resolution: SIMD2<Float>(Float(viewportSize.width), Float(viewportSize.height))
        )
        memcpy(uniformsBuffer.contents(), &u, MemoryLayout<Uniforms>.stride)
    }

    private func updateFieldUniformsBuffer(time: Float) {
        guard let fieldUniformsBuffer else { return }
        let mode = colorProfileStore?.field.shaderIndex ?? 0

        var u = FieldUniforms(
            time: time,
            resolution: SIMD2<Float>(Float(fieldWidth), Float(fieldHeight)),
            dt: 1.0 / 60.0,
            mode: Float(mode)
        )
        memcpy(fieldUniformsBuffer.contents(), &u, MemoryLayout<FieldUniforms>.stride)
    }
}
