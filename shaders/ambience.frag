#include <flutter/runtime_effect.glsl>
// Soft glowing ribbons of colour flowing into each other (after the
// classic media player's Ambience): bass thickens them, mids bend them,
// the level sets the pace and brightness, beats flash.
uniform vec2 uSize;
uniform float uTime;
uniform float uBass;
uniform float uMid;
uniform float uTreble;
uniform float uBeat;
uniform vec3 uColA;
uniform vec3 uColB;
uniform float uLevel;
out vec4 fragColor;

vec3 pal(float t) {
  vec3 rainbow = 0.5 + 0.5 * cos(6.2832 * (t + vec3(0.0, 0.33, 0.67)));
  return mix(rainbow, mix(uColA, uColB, 0.5 + 0.5 * sin(t * 6.2832)), 0.55);
}

void main() {
  vec2 uv = (FlutterFragCoord().xy - 0.5 * uSize) / min(uSize.x, uSize.y);
  float t = uTime * (0.18 + uLevel * 0.25);
  vec2 p = uv * 1.6;
  vec3 col = vec3(0.0);
  for (int i = 0; i < 4; i++) {
    float fi = float(i);
    p = vec2(
      p.x + (0.45 + uMid * 0.35) * sin(p.y * 1.7 + t * (0.6 + 0.12 * fi) + fi),
      p.y + (0.45 + uMid * 0.35) * cos(p.x * 1.3 - t * (0.5 + 0.1 * fi))
    );
    float d = abs(sin(length(p) * (2.2 + uTreble * 1.5) - t * 1.5 + fi * 1.3));
    col += pal(fi * 0.17 + t * 0.04 + length(p) * 0.08) * (0.05 + uBass * 0.06) / (d + 0.06);
  }
  col *= 0.9 * (0.4 + uLevel * 1.2 + uBeat * 0.35);
  col = col / (1.0 + col);
  col *= smoothstep(1.5, 0.3, length(uv));
  fragColor = vec4(col, 1.0);
}
