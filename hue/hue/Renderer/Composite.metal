/*
 Copyright © 2026 kelyonn. All rights reserved.

 This file is part of Hue. See the LICENSE at the repository root.
 Unauthorized copying, modification, or reuse in another product is prohibited.
*/
/*
 Composite.metal — Hue Display Pass
 ===================================

 Tone-maps and finishes the simulated dye field (FluidCompute.metal's
 `fieldSim` output) into the final on-screen image: ambient wash, exposure,
 Reinhard, gamma, treble sparks, vignette, grain, and `dim` (the 50% dim
 behind the permission overlay's scrim). Ported line-for-line from the
 Hue.dc.html design handoff's reference GLSL (hue-engine.js's DISP_FS).

 ## Buffer Bindings
   buffer(0) → AudioData
   buffer(1) → Uniforms (time, dim, resolution)

 ## Texture Bindings
   texture(0) → field (FluidCompute.metal's fieldSim output)
*/

#include <metal_stdlib>
#include "OklabColor.h"
using namespace metal;

// ── Shared types (must mirror Swift) ──

struct AudioData {
    float bass;
    float mids;
    float treble;
    float rms;
    float spectralCentroid;
    float spectralFlux;
    float beatIntensity;
    float beatPhase;
    float lowMidRatio;
    float spectralSpread;
    float harmonicComplexity;
    float isSilent;
    float valence;
    float arousal;
    float mappedL;
    float mappedC;
    float mappedH;
};

struct Uniforms {
    float  time;
    float  dim;
    float2 resolution;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Vertex Shader
// ─────────────────────────────────────────────────────────────────────────────

vertex VertexOut hue_vertex(uint vid [[vertex_id]]) {
    const float2 positions[6] = {
        {-1, -1}, { 1, -1}, {-1,  1},
        {-1,  1}, { 1, -1}, { 1,  1}
    };
    VertexOut out;
    out.position = float4(positions[vid], 0, 1);
    out.uv = positions[vid] * 0.5 + 0.5;
    return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Noise (ambient wash + dither/grain)
// ─────────────────────────────────────────────────────────────────────────────

float comp_hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

float comp_noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(comp_hash(i), comp_hash(i + float2(1, 0)), u.x),
        mix(comp_hash(i + float2(0, 1)), comp_hash(i + float2(1, 1)), u.x),
        u.y
    );
}

float comp_fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) { v += a * comp_noise(p); p *= 2.02; a *= 0.5; }
    return v;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Fragment Shader — display pass (hue-engine.js DISP_FS)
// ─────────────────────────────────────────────────────────────────────────────

fragment float4 hue_fragment(
    VertexOut                       in       [[stage_in]],
    constant AudioData&             audio    [[buffer(0)]],
    constant Uniforms&              uniforms [[buffer(1)]],
    texture2d<half, access::sample> fieldTex [[texture(0)]]
) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    float2 uv     = in.uv;
    float  time   = uniforms.time;
    float2 res    = uniforms.resolution;
    float  act    = 1.0 - audio.isSilent;
    float  aspect = res.x / res.y;
    float2 p      = (uv - 0.5) * float2(aspect, 1.0);

    float3 c = float3(fieldTex.sample(s, uv).rgb);

    // ── ambient wash — the ground the dye sits in, never black-clipped ──
    // Deliberately its own warm↔cool hue (no profile offset) — a background
    // tint distinct from the profile-tinted dye injections themselves.
    // `audio.valence` already arrives 0..1 (AudioFeatures.valence: 0 = minor/sad,
    // 1 = major/happy), so it is used directly — remapping it again here pinned
    // the wash to 0.5..1.0 and kept the background from ever reading cool.
    float valence01 = audio.valence;
    float warmCool  = 0.6 * audio.spectralCentroid + 0.4 * valence01;
    float wh = mix(4.3633, 1.0472, warmCool);   // 250deg blue -> 60deg yellow, radians
    float n = comp_fbm(uv * float2(2.1 * aspect, 2.1) + time * 0.02);
    c += oklch_to_linear_srgb(0.30 + 0.18 * audio.spectralCentroid, 0.10, wh)
       * (0.014 + 0.038 * audio.rms) * (0.35 + 0.65 * n) * act;

    // ── tone map ──
    c *= 2.25;                            // exposure
    c = c / (1.0 + c);                    // Reinhard
    c = pow(max(c, 0.0), float3(0.4545)); // gamma

    // ── treble sparks — twinkle in place, never advected (they'd smear) ──
    float2 cell = floor(uv * res / 4.0);
    float sp = comp_hash(cell + floor(time * 20.0) * 0.37);
    float spark = step(0.9994 - 0.0030 * audio.treble, sp) * audio.treble * act;
    c += float3(0.95, 0.92, 0.86) * spark * 0.20;

    // ── vignette ──
    c *= 1.0 - smoothstep(0.42, 1.15, length(p) * 1.25);

    // ── grain — breaks up gradient banding across the long decay ──
    c += (comp_hash(uv * res + fract(time) * 97.0) - 0.5) * 0.014;

    // ── dim — 0.5 behind the permission overlay's scrim, 1.0 otherwise ──
    c *= uniforms.dim;

    return float4(max(c, 0.0), 1.0);
}
