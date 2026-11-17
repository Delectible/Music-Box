#include <flutter/runtime_effect.glsl>
// Mirrored, ever-folding patterns (after the classic media player's
// Alchemy): the slices turn with the mids, bass pushes the rings out,
// highs add fine lace, beats flash and twist.
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

float hash(vec2 p) { return fract(sin(dot(p, vec2(41.3, 289.1))) * 43758.5453); }
float noise(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}

void main() {
  vec2 uv = (FlutterFragCoord().xy - 0.5 * uSize) / min(uSize.x, uSize.y);
  float t = uTime * (0.12 + uLevel * 0.15);
  float r = length(uv);
  float a = atan(uv.y, uv.x) + t * 0.6 + uBeat * 0.15;
  // Fold into 8 mirrored slices.
  float seg = 6.2832 / 8.0;
  a = mod(a, seg);
  a = abs(a - seg * 0.5);
  vec2 k = vec2(cos(a), sin(a)) * r;
  float n = noise(k * 4.0 + t * 1.5) * 0.6 + noise(k * (9.0 + uTreble * 8.0) - t * 2.0) * 0.4;
  float rings = sin(r * (18.0 - uBass * 8.0) - t * 6.0 + n * 4.0);
  float lace = smoothstep(0.55, 1.0, abs(sin(k.x * 30.0 + n * 6.0 + t * 3.0))) * uTreble;
  vec3 col = mix(uColA, uColB, 0.5 + 0.5 * sin(n * 5.0 + r * 4.0 - t * 2.0));
  float light = (0.5 + 0.5 * rings) * (0.45 + uLevel * 0.9) + lace * 0.6 + uBeat * 0.25 * exp(-r * 2.0);
  col *= light;
  col += vec3(1.0) * pow(max(rings, 0.0), 12.0) * (0.15 + uBeat * 0.5);
  col *= smoothstep(1.3, 0.25, r);
  fragColor = vec4(col, 1.0);
}
