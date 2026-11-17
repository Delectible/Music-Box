#include <flutter/runtime_effect.glsl>
// iTunes-style glowing nebula: domain-warped noise lit by the music.
uniform vec2 uSize;
uniform float uTime;
uniform float uBass;
uniform float uMid;
uniform float uTreble;
uniform float uBeat;
uniform vec3 uColA;
uniform vec3 uColB;
out vec4 fragColor;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}
float fbm(vec2 p) {
  float v = 0.0, a = 0.5;
  for (int i = 0; i < 5; i++) { v += a * noise(p); p = p * 2.03 + 11.0; a *= 0.5; }
  return v;
}
void main() {
  vec2 uv = (FlutterFragCoord().xy - 0.5 * uSize) / min(uSize.x, uSize.y);
  float t = uTime * 0.15;
  float r = length(uv);
  float ang = atan(uv.y, uv.x);
  // Swirl: faster with the mids.
  float sw = ang + (0.6 + uMid * 1.4) / (r + 0.35) + t * 2.0;
  vec2 q = vec2(cos(sw), sin(sw)) * r * (2.2 - uBass * 0.6);
  vec2 w = vec2(fbm(q + t), fbm(q - t + 4.0));
  float n = fbm(q * 1.4 + w * (1.6 + uTreble * 2.0));
  float core = exp(-r * (3.2 - uBass * 1.6 - uBeat * 0.8));
  float glow = pow(n, 2.2) * (0.8 + uBass * 1.6) + core * (0.5 + uBeat);
  vec3 col = mix(uColA, uColB, smoothstep(0.2, 0.9, n + uTreble * 0.3));
  col = col * glow + vec3(1.0) * pow(core, 3.0) * (0.3 + uBeat * 0.7);
  col *= smoothstep(1.4, 0.2, r);
  fragColor = vec4(col, 1.0);
}
