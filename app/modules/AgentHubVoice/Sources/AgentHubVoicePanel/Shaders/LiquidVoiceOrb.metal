//
//  LiquidVoiceOrb.metal
//  AgentHubVoicePanel
//
//  Voice-orb adaptation of ShaderKit's Liquid Tech [234] shader (Twigl GLSL
//  inspired). The raymarched field is kept, but the rainbow wave coloring is
//  replaced by a two-color tint (the selected voice's gradient), and the
//  effect is masked by the sampled layer's alpha so it stays inside the orb.
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

static float2x2 orbRotate2D(float angle) {
  float s = sin(angle);
  float c = cos(angle);
  return float2x2(c, -s, s, c);
}

[[stitchable]] half4 liquidVoiceOrb(
  float2 position,
  SwiftUI::Layer layer,
  float2 size,
  float time,
  float intensity,
  half4 colorA,
  half4 colorB
) {
  float2 r = size;

  float2 uv = (position * 2.0 - r) / r.y;
  // Tint span uses disc-space coordinates, captured before the zoom below.
  float radial = clamp(length(uv), 0.0, 1.0);
  // Zoom the field so the liquid sphere fills the disc edge-to-edge instead
  // of leaving a dark ring of base circle around it.
  uv /= 1.5;

  float d = 0.0;
  float s = 0.0;
  float4 o = float4(0.0);

  float2x2 rot = orbRotate2D(time * 0.5);

  for (int i = 0; i < 100; i++) {
    float fi = float(i);
    float2 v = rot * (uv * d);
    float3 p = float3(v.x, v.y, d - 8.0);

    float2 xz = rot * p.xz;
    p.x = xz.x;
    p.z = xz.y;

    float dp = dot(p.yzx, p) / 0.7;
    float m = max(sin(dp), length(p) - 4.0);
    s = 0.012 + 0.08 * abs(m - fi / 100.0);
    d += s;

    float4 wave = 1.3 * sin(float4(3.0, 2.0, 1.0, 1.0) + fi * 0.3) / s;
    float lenPP = length(p * p);
    o += max(wave, float4(-lenPP));
  }

  o = tanh(o * o / 800000.0);

  // Voice tint: colorA at the center flowing to colorB at the rim, driven by
  // the field's luminance, with a whisper of the original chroma so the
  // highlights keep their liquid sparkle.
  float lum = dot(o.rgb, float3(0.299, 0.587, 0.114));
  half3 tint = mix(colorA.rgb, colorB.rgb, half(radial));
  half3 effect = tint * half(lum) * 1.6h + half3(o.rgb) * 0.15h;

  half4 sampled = layer.sample(position);
  half3 added = min(sampled.rgb + effect * sampled.a, half3(1.0));
  half3 blended = mix(sampled.rgb, added, half(intensity));

  return half4(blended, sampled.a);
}
