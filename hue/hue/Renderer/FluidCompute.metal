/*
 Copyright © 2026 kelyonn. All rights reserved.

 This file is part of Hue. See the LICENSE at the repository root.
 Unauthorized copying, modification, or reuse in another product is prohibited.
*/
/*
 FluidCompute.metal — Hue GPU Dye Field Simulation
 ==================================================

 Curl-noise dye advection — ported line-for-line from the Hue.dc.html design
 handoff's reference GLSL (design_handoff_hue_canvas/README.md +
 hue-engine.js's SIM_FS). Replaces the previous 6-kernel incompressible
 Navier-Stokes solver (inject/advect/diffuse/divergence/pressure/project,
 20+40 Jacobi iterations): velocity here is computed analytically per-pixel
 each frame from curl(fbm(p)), so there is no separate velocity/pressure/
 divergence texture and no iterative solve — one compute pass, full stop.

 Colour: (L, C, h) arrive precomputed on the CPU by PerceptualMapper.swift,
 which implements the same design formula (see its doc comment), via
 AudioData.mappedL/C/H. This kernel only *uses* that target color for
 injection — it does not re-derive L/C/h itself.

 ## Texture Layout
   texture(0)  fieldIn   (rgba = dye colour, previous frame)   READ (sampled, linear)
   texture(1)  fieldOut  (rgba = dye colour, this frame)       WRITE

 ## Buffer Bindings
   buffer(0) → AudioData
   buffer(1) → FieldUniforms
*/

#include <metal_stdlib>
#include "OklabColor.h"
using namespace metal;

// Must mirror Swift AudioDataBuffer struct
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
    float mappedL;   // PerceptualMapper OkLab lightness target
    float mappedC;   // PerceptualMapper OkLab chroma target
    float mappedH;   // PerceptualMapper OkLab hue target (radians)
};

struct FieldUniforms {
    float time;
    float2 resolution;   // field texture size, in texels
    float dt;
    float mode;          // 0 = Diffuse, 1 = Ascend, 2 = Radiate
};

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Noise (curl-noise velocity field)
// ─────────────────────────────────────────────────────────────────────────────

float hash21(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

float noise2(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + float2(1.0, 0.0)), u.x),
               mix(hash21(i + float2(0.0, 1.0)), hash21(i + float2(1.0, 1.0)), u.x), u.y);
}

float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) { v += a * noise2(p); p *= 2.02; a *= 0.5; }
    return v;
}

/// Curl of a scalar fbm field — gives a divergence-free-looking velocity
/// field for free (no pressure projection needed) by construction.
float2 curl(float2 p, float t) {
    float e = 0.06;
    float n1 = fbm(p + float2(0.0, e) + t * 0.04);
    float n2 = fbm(p - float2(0.0, e) + t * 0.04);
    float n3 = fbm(p + float2(e, 0.0) + t * 0.04);
    float n4 = fbm(p - float2(e, 0.0) + t * 0.04);
    return float2(n1 - n2, -(n3 - n4)) / (2.0 * e);
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Field Simulation
// ─────────────────────────────────────────────────────────────────────────────

kernel void fieldSim(
    texture2d<half, access::sample> fieldIn  [[texture(0)]],
    texture2d<half, access::write>  fieldOut [[texture(1)]],
    constant AudioData&             audio    [[buffer(0)]],
    constant FieldUniforms&         uniforms [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    float2 res = uniforms.resolution;
    if (gid.x >= uint(res.x) || gid.y >= uint(res.y)) return;

    float2 uv = (float2(gid) + 0.5) / res;
    float aspect = res.x / res.y;
    float2 p = (uv - 0.5) * float2(aspect, 1.0);

    float time = uniforms.time;
    float mode = uniforms.mode;
    float uSilent = audio.isSilent;
    float act = 1.0 - uSilent;

    float uBass = audio.bass, uMids = audio.mids, uTreble = audio.treble;
    float uRms = audio.rms, uCentroid = audio.spectralCentroid;
    float uBeat = audio.beatIntensity, uArousal = audio.arousal;

    // ── velocity field ──────────────────────────────────────────────────
    float2 c  = curl(p * 1.7, time);
    float2 cf = curl(p * 5.4, time * 1.7);          // fine scale — filaments
    float2 v;
    if (mode < 0.5) {
        // DIFFUSE — free curl-noise drift, ink loosed in still water
        v = c * (0.30 + 0.42 * uArousal) + cf * 0.085 + float2(0.0, 0.035);
    } else if (mode < 1.5) {
        // ASCEND — laminar upward veils, pitch rises through the field
        v = c * 0.15 + cf * 0.055 + float2(0.0, 0.30 + 0.42 * uArousal);
    } else {
        // RADIATE — pressure outward from the centre, beats push the front
        float2 r = p / max(length(p), 0.0012);
        v = r * (0.17 + 0.34 * uRms + 0.55 * uBeat) + c * 0.14 + cf * 0.055;
    }
    v *= 1.0 + 0.7 * uBeat;

    // ── advect + decay ──────────────────────────────────────────────────
    float2 src = uv - v * uniforms.dt / float2(aspect, 1.0);
    float decay = 0.9952 - 0.0042 * uArousal;
    float3 col = float3(fieldIn.sample(s, src).rgb) * decay - 0.0016;
    col = max(col, 0.0);

    // ── dye colour — precomputed on the CPU (see file header) ──────────
    float L = audio.mappedL;
    float C = audio.mappedC;
    float h = audio.mappedH;

    // ── injection ────────────────────────────────────────────────────────
    float yPitch = mix(-0.34, 0.34, uCentroid);      // spatial pitch height
    float energy = (0.14 * uRms + 1.85 * uBeat * uBeat + 0.55 * uBeat) * act;
    float3 inj = float3(0.0);

    if (mode < 0.5) {
        for (int i = 0; i < 3; i++) {
            float fi = float(i);
            float band = (i == 0) ? uBass : ((i == 1) ? uMids : uTreble);
            float2 o = float2(
                sin(time * (0.13 + fi * 0.05) + fi * 2.3) * 0.44 * aspect,
                cos(time * (0.11 + fi * 0.04) + fi * 1.7) * 0.24 + yPitch * 0.75 + (fi - 1.0) * 0.12
            );
            float rad = 0.070 + 0.13 * band + 0.05 * uBeat;
            float w = exp(-pow(length(p - o) / rad, 2.0)) * (0.5 + 0.5 * band)
                    * (0.45 + 0.55 * fbm(p * 3.4 + fi * 7.0 + time * 0.22));
            inj += oklch_to_linear_srgb(clamp(L + (fi - 1.0) * 0.10, 0.06, 0.98),
                                        C * (1.0 + 0.20 * (1.0 - fi)),
                                        h + (fi - 1.0) * 0.30) * w;
        }
        inj *= energy * 1.55;
    } else if (mode < 1.5) {
        float band = exp(-pow((p.y - yPitch) / (0.034 + 0.055 * uRms), 2.0));
        float grain = 0.16 + 0.84 * fbm(float2(p.x * 3.2, p.y * 2.0 + time * 0.45));
        inj  = oklch_to_linear_srgb(L, C, h + p.x * 0.42) * band * grain * energy * 0.42;
        inj += oklch_to_linear_srgb(clamp(L - 0.16, 0.06, 1.0), C * 1.15, h + 0.26)
             * exp(-pow((p.y + 0.42) / 0.065, 2.0)) * uBass * 0.13 * act;
    } else {
        float rr = length(p);
        float ring = 0.07 + 0.42 * uRms;
        float ang = p.y / max(rr, 0.0012);              // never atan2 — it seams at pi
        inj  = oklch_to_linear_srgb(L, C, h + ang * 0.20)
             * exp(-pow((rr - ring) / (0.040 + 0.07 * uBeat), 2.0))
             * (0.20 + 0.80 * fbm(p * 5.2 + time * 0.45)) * energy * 1.00;
        inj += oklch_to_linear_srgb(clamp(L - 0.14, 0.06, 1.0), C * 1.2, h + 0.28)
             * exp(-pow(rr / 0.065, 2.0)) * uBass * 0.15 * act;
    }

    // saturation limit — dye stops piling where the water is already dense
    float room = clamp(1.0 - dot(col, float3(0.36, 0.46, 0.18)), 0.0, 1.0);
    col += inj * (0.28 + 0.72 * room * room);
    // dither — long decay bands badly without it
    col += (hash21(uv * res + fract(time) * 61.0) - 0.5) * 0.0022;

    // outflow at the frame edge — dye must leave, or the field silts up
    float edge = smoothstep(0.34, 0.50, max(abs(uv.x - 0.5), abs(uv.y - 0.5)));
    col *= 1.0 - 0.105 * edge;

    // silence: nothing is added, the field simply empties
    col *= mix(1.0, 0.975, uSilent);

    fieldOut.write(half4(half3(min(col, 1.25)), 1.0h), gid);
}
