/*
 OklabColor.h — Oklab / OkLCh color conversion
 ===============================================

 Perceptually uniform color space (Björn Ottosson). Shared by FluidCompute.metal
 and Composite.metal so the perceptual mapping layer (PerceptualMapper.swift)
 can hand the shaders (L, C, h) and get back correct RGB, instead of routing
 through HSL — whose "lightness" is a raw RGB average, not perceived brightness.
 That distinction matters here specifically because pitch→lightness is the one
 universal law in CHROMESTHESIA_ENGINE.md §1.1.
*/

#ifndef HUE_OKLAB_COLOR_H
#define HUE_OKLAB_COLOR_H

#include <metal_stdlib>
using namespace metal;

inline float3 oklab_to_linear_srgb(float3 lab) {
    float l_ = lab.x + 0.3963377774f * lab.y + 0.2158037573f * lab.z;
    float m_ = lab.x - 0.1055613458f * lab.y - 0.0638541728f * lab.z;
    float s_ = lab.x - 0.0894841775f * lab.y - 1.2914855480f * lab.z;

    float l = l_ * l_ * l_;
    float m = m_ * m_ * m_;
    float s = s_ * s_ * s_;

    float3 rgb;
    rgb.r = +4.0767416621f * l - 3.3077115913f * m + 0.2309699292f * s;
    rgb.g = -1.2684380046f * l + 2.6097574011f * m - 0.3413193965f * s;
    rgb.b = -0.0041960863f * l - 0.7034186147f * m + 1.7076147010f * s;
    return rgb;
}

/// Converts OkLCh (lightness, chroma, hue-in-radians) to linear sRGB.
/// Out-of-gamut components are clamped to 0 rather than negative.
inline float3 oklch_to_linear_srgb(float L, float C, float h) {
    float a = C * cos(h);
    float b = C * sin(h);
    float3 rgb = oklab_to_linear_srgb(float3(L, a, b));
    return max(rgb, float3(0.0));
}

#endif
