import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/visualizer.dart';

/// The GPU-drawn styles (shaders/*.frag), loaded once. Until they're ready
/// (or where they can't load) those styles draw a plainer picture.
class VizShaders {
  static ui.FragmentShader? nebula, ambience, alchemy;
  static Future<void>? _loading;

  static Future<void> load() => _loading ??= () async {
    Future<ui.FragmentShader?> one(String name) async {
      try {
        return (await ui.FragmentProgram.fromAsset('shaders/$name.frag')).fragmentShader();
      } on Object {
        return null;
      }
    }

    nebula = await one('nebula');
    ambience = await one('ambience');
    alchemy = await one('alchemy');
  }();
}

/// Moving parts some styles keep between frames.
class VizScene {
  final feed = VizFeed();
  final _rnd = Random(4);

  /// Stars streaming out of the nebula.
  final stars = <_Star>[];

  /// Particles: x, y, vx, vy (as a share of the short side), group, life.
  final particles = <Float32List>[];
  final attractors = List.generate(3, (_) => Offset.zero);

  /// The last few waveforms, for the scope's afterglow.
  final scopeTrail = <Float32List>[];
  double _trailClock = 0;
  int _lastBeats = 0;

  /// A soft round dot, drawn once, stamped for every particle.
  late final ui.Image glow = _glowSprite();

  void tick(double dt) {
    feed.tick(dt);
    final f = feed;
    // Stars fly outwards, faster with the music; a beat gives a kick.
    if (stars.isEmpty) {
      for (var i = 0; i < 260; i++) {
        stars.add(_Star(_rnd.nextDouble() * pi * 2, _rnd.nextDouble()));
      }
    }
    final speed = 0.05 + f.level * 0.8 + f.beat * 0.9;
    for (final s in stars) {
      s.z += dt * speed * (0.3 + s.z);
      if (s.z > 1) {
        s
          ..z = 0.02 + _rnd.nextDouble() * 0.05
          ..a = _rnd.nextDouble() * pi * 2;
      }
    }
    _particles(dt);
    _trailClock += dt;
    if (_trailClock > 1 / 30) {
      _trailClock = 0;
      scopeTrail.add(Float32List.fromList(f.wave));
      if (scopeTrail.length > 7) scopeTrail.removeAt(0);
    }
  }

  void _particles(double dt) {
    final f = feed;
    while (particles.length < 3600) {
      final a = _rnd.nextDouble() * pi * 2;
      final r = 0.05 + _rnd.nextDouble() * 0.3;
      particles.add(
        Float32List.fromList([cos(a) * r, sin(a) * r, 0, 0, _rnd.nextDouble(), _rnd.nextDouble()]),
      );
    }
    // Three attractors wander around the middle, wider when it's loud.
    final t = f.time;
    final wide = 0.22 + f.level * 0.18;
    for (var k = 0; k < 3; k++) {
      attractors[k] = Offset(
        cos(t * (0.31 + k * 0.07) + k * 2.09) * wide * 1.3,
        sin(t * (0.43 + k * 0.05) + k * 2.09) * wide,
      );
    }
    // A beat throws them outwards.
    final kick = f.beats != _lastBeats ? f.beat : 0.0;
    _lastBeats = f.beats;
    final pull = 0.005 * (0.5 + f.bass * 2.0);
    final spin = 1.4 + f.mid * 3.5;
    final drag = pow(0.93, dt * 60).toDouble();
    final step = dt * 60;
    for (final p in particles) {
      final at = attractors[(p[4] * 3).floor().clamp(0, 2)];
      final dx = at.dx - p[0], dy = at.dy - p[1];
      final d2 = dx * dx + dy * dy + 0.012;
      final g = pull / d2;
      p[2] = (p[2] + (dx * g - dy * g * spin) * step) * drag;
      p[3] = (p[3] + (dy * g + dx * g * spin) * step) * drag;
      if (kick > 0) {
        final d = sqrt(d2);
        p[2] -= dx / d * kick * 0.012;
        p[3] -= dy / d * kick * 0.012;
      }
      p[0] += p[2] * step;
      p[1] += p[3] * step;
      p[5] -= dt * 0.2;
      if (p[5] <= 0 || p[0].abs() > 1.4 || p[1].abs() > 1.4) {
        final a = _rnd.nextDouble() * pi * 2;
        final r = 0.12 + _rnd.nextDouble() * 0.2;
        p
          ..[0] = at.dx + cos(a) * r
          ..[1] = at.dy + sin(a) * r
          ..[2] = 0
          ..[3] = 0
          ..[5] = 0.6 + _rnd.nextDouble() * 0.4;
      }
    }
  }

  static ui.Image _glowSprite() {
    final rec = ui.PictureRecorder();
    Canvas(rec).drawCircle(
      const Offset(32, 32),
      32,
      Paint()
        ..shader = ui.Gradient.radial(
          const Offset(32, 32),
          32,
          [Colors.white, Colors.white.withValues(alpha: 0.3), Colors.white.withValues(alpha: 0)],
          [0, 0.22, 1],
        ),
    );
    return rec.endRecording().toImageSync(64, 64);
  }
}

class _Star {
  double a, z;
  _Star(this.a, this.z);
}

Color _hsl(double h, double s, double l, [double a = 1]) =>
    HSLColor.fromAHSL(a.clamp(0, 1), h % 360, s.clamp(0, 1), l.clamp(0, 1)).toColor();

class VizPainter extends CustomPainter {
  final VizStyle style;
  final VizScene scene;
  final Color accent;

  /// Space left for the cover in the middle (cover styles), in px.
  final double coverSize;

  VizPainter({
    required this.style,
    required this.scene,
    required this.accent,
    this.coverSize = 0,
    super.repaint,
  });

  VizFeed get f => scene.feed;
  double get hue => HSLColor.fromColor(accent).hue;

  @override
  void paint(Canvas c, Size s) {
    switch (style) {
      case VizStyle.bars:
        _bars(c, s);
      case VizStyle.mirror:
        _mirror(c, s);
      case VizStyle.scope:
        _scope(c, s);
      case VizStyle.coverBloom:
        _coverBloom(c, s);
      case VizStyle.ambience:
        _shader(c, s, VizShaders.ambience, hue, hue + 120) || _ambienceFallback(c, s);
      case VizStyle.ribbons:
        _particles(c, s);
      case VizStyle.kaleido:
        _shader(c, s, VizShaders.alchemy, hue + 40, hue + 200) || _ambienceFallback(c, s);
      case VizStyle.tunnel:
        _nebula(c, s);
      case VizStyle.waterfall:
        _waterfall(c, s);
    }
  }

  /// The band at [x] (0..1 across the spectrum), smoothly in between bands.
  double _band(double x, [Float32List? from]) {
    final b = from ?? f.bands;
    final p = (x * (VizFeed.bandCount - 1)).clamp(0.0, VizFeed.bandCount - 1.0);
    final i = p.floor();
    final j = min(i + 1, VizFeed.bandCount - 1);
    return b[i] + (b[j] - b[i]) * (p - i);
  }

  /// A dark background tinted with the accent, a little brighter on beats.
  void _bg(Canvas c, Size s, {double lift = 0.12, Offset? at}) {
    final center = at ?? Offset(s.width / 2, s.height * 0.45);
    c.drawRect(
      Offset.zero & s,
      Paint()
        ..shader = ui.Gradient.radial(center, s.longestSide * 0.75, [
          _hsl(hue, 0.55, lift + f.level * 0.06 + f.beat * 0.04),
          const Color(0xFF020204),
        ]),
    );
  }

  /// A smooth line through [pts] (quadratic curves through the midpoints).
  static Path _smooth(List<Offset> pts) {
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length; i++) {
      final a = pts[i - 1], b = pts[i];
      path.quadraticBezierTo(a.dx, a.dy, (a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
    }
    path.lineTo(pts.last.dx, pts.last.dy);
    return path;
  }

  // ------------------------------------------------------------------ Bars
  /// Slim spectrum bars with a floor reflection and the waveform gliding
  /// across them (after the classic "bars and waves").
  void _bars(Canvas c, Size s) {
    _bg(c, s);
    final n = (s.width / 24).round().clamp(18, 64);
    final floor = s.height * (s.width > s.height ? 0.68 : 0.62);
    final maxH = floor * 0.74;
    final bw = s.width / n;
    final w = bw * 0.58;
    final radius = Radius.circular(min(3, w / 2));
    final glowPath = Path();
    final capPaint = Paint()..color = Colors.white.withValues(alpha: 0.85);
    for (var i = 0; i < n; i++) {
      final x0 = i / (n - 1);
      final v = _band(x0);
      final x = i * bw + (bw - w) / 2;
      final bh = max(2.0, v * maxH);
      final h = hue + x0 * 70;
      final top = _hsl(h, 0.85, 0.62 + v * 0.12);
      final bottom = _hsl(h + 25, 0.8, 0.28);
      final rect = RRect.fromRectAndCorners(
        Rect.fromLTWH(x, floor - bh, w, bh),
        topLeft: radius,
        topRight: radius,
      );
      glowPath.addRRect(rect);
      c.drawRRect(
        rect,
        Paint()..shader = ui.Gradient.linear(Offset(0, floor - bh), Offset(0, floor), [top, bottom]),
      );
      // Reflection, fading into the floor.
      final rh = bh * 0.38;
      c.drawRect(
        Rect.fromLTWH(x, floor + 3, w, rh),
        Paint()
          ..shader = ui.Gradient.linear(Offset(0, floor), Offset(0, floor + rh), [
            bottom.withValues(alpha: 0.32),
            bottom.withValues(alpha: 0),
          ]),
      );
      // The cap that hangs at the peak.
      final pk = _band(x0, f.peaks) * maxH;
      c.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x, floor - pk - 5, w, 2), const Radius.circular(1)),
        capPaint,
      );
    }
    // One soft glow over all the bars (a single blur: cheap).
    c.drawPath(
      glowPath,
      Paint()
        ..color = _hsl(hue + 30, 0.9, 0.6, 0.18 + f.beat * 0.12)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
    );
    // A thin floor line.
    c.drawLine(
      Offset(0, floor + 1),
      Offset(s.width, floor + 1),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.08)
        ..strokeWidth = 1,
    );
    // The waveform across the upper half.
    final mid = floor * 0.38;
    final amp = floor * 0.16 * (0.35 + f.level);
    final pts = <Offset>[
      for (var i = 0; i < 96; i++)
        Offset(i / 95 * s.width, mid + f.wave[(i * (VizFeed.waveCount - 1) / 95).round()] * amp),
    ];
    final wave = _smooth(pts);
    final wc = _hsl(hue + 170, 0.75, 0.75);
    c.drawPath(
      wave,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8
        ..color = wc.withValues(alpha: 0.18 + f.beat * 0.15)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    );
    c.drawPath(
      wave,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..color = wc.withValues(alpha: 0.9),
    );
  }

  // ------------------------------------------------------------------ Mirror
  /// Thin bars mirrored up and down from a bright centre line, bass in the
  /// middle, highs out to the sides.
  void _mirror(Canvas c, Size s) {
    c.drawRect(Offset.zero & s, Paint()..color = const Color(0xFF050409));
    final n = (s.width / 14).round().clamp(24, 110);
    final mid = s.height / 2;
    final bw = s.width / n;
    final w = max(2.0, bw * 0.5);
    final glow = Path();
    for (var i = 0; i < n; i++) {
      final x0 = (i - (n - 1) / 2).abs() / ((n - 1) / 2);
      final v = _band(x0 * 0.85);
      final h = max(2.0, v * s.height * 0.42);
      final x = i * bw + (bw - w) / 2;
      final rect = RRect.fromRectAndRadius(Rect.fromLTRB(x, mid - h, x + w, mid + h), Radius.circular(w / 2));
      glow.addRRect(rect);
      final col = _hsl(hue + x0 * 90, 0.9, 0.6);
      c.drawRRect(
        rect,
        Paint()
          ..shader = ui.Gradient.linear(
            Offset(0, mid - h),
            Offset(0, mid + h),
            [col.withValues(alpha: 0.0), Color.lerp(col, Colors.white, 0.35)!, col.withValues(alpha: 0.0)],
            [0, 0.5, 1],
          ),
      );
    }
    c.drawPath(
      glow,
      Paint()
        ..color = _hsl(hue, 0.9, 0.55, 0.16 + f.beat * 0.14)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
    );
    // The centre line flares on beats.
    c.drawRect(
      Rect.fromLTRB(0, mid - 1, s.width, mid + 1),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(s.width, 0),
          [Colors.transparent, Colors.white.withValues(alpha: 0.35 + f.beat * 0.6), Colors.transparent],
          [0, 0.5, 1],
        ),
    );
  }

  // ------------------------------------------------------------------ Scope
  /// An oscilloscope with phosphor afterglow: a line across in landscape,
  /// a ring in portrait.
  void _scope(Canvas c, Size s) {
    c.drawRect(
      Offset.zero & s,
      Paint()
        ..shader = ui.Gradient.radial(s.center(Offset.zero), s.longestSide * 0.7, [
          const Color(0xFF04140E),
          const Color(0xFF010302),
        ]),
    );
    final grid = Paint()
      ..color = const Color(0x1230FFA0)
      ..strokeWidth = 1;
    final step = s.shortestSide / 8;
    for (var x = s.width / 2 % step; x < s.width; x += step) {
      c.drawLine(Offset(x, 0), Offset(x, s.height), grid);
    }
    for (var y = s.height / 2 % step; y < s.height; y += step) {
      c.drawLine(Offset(0, y), Offset(s.width, y), grid);
    }
    final ring = s.height > s.width;
    final green = HSLColor.fromAHSL(1, 150 - f.level * 40, 0.95, 0.6).toColor();
    Path line(Float32List w) {
      final pts = <Offset>[];
      const n = 160;
      for (var i = 0; i < n; i++) {
        final v = w[(i * (VizFeed.waveCount - 1) / (n - 1)).round()];
        if (ring) {
          final a = i / n * pi * 2 - pi / 2;
          final r = s.width * 0.3 + v * s.width * 0.14;
          pts.add(s.center(Offset(cos(a) * r, sin(a) * r)));
        } else {
          pts.add(Offset(i / (n - 1) * s.width, s.height / 2 + v * s.height * 0.36));
        }
      }
      final p = _smooth(pts);
      if (ring) p.close();
      return p;
    }

    // Older traces, fading.
    final trail = scene.scopeTrail;
    for (var k = 0; k < trail.length; k++) {
      final a = (k + 1) / (trail.length + 1) * 0.25;
      c.drawPath(
        line(trail[k]),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = green.withValues(alpha: a),
      );
    }
    final now = line(f.wave);
    for (final (w, a) in [(18.0, 0.07 + f.beat * 0.06), (7.0, 0.22), (2.4, 1.0)]) {
      c.drawPath(
        now,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = w
          ..strokeJoin = StrokeJoin.round
          ..color = (w < 3 ? Color.lerp(green, Colors.white, 0.4)! : green).withValues(alpha: a),
      );
    }
  }

  // ------------------------------------------------------------------ Cover bloom
  /// The cover in the middle, glowing in its colour, with the spectrum as a
  /// ring of rays around it and sparks drifting up.
  void _coverBloom(Canvas c, Size s) {
    final center = s.center(Offset(0, -s.shortestSide * 0.05));
    final glow = 0.25 + f.level * 0.7 + f.beat * 0.3;
    c.drawRect(
      Offset.zero & s,
      Paint()
        ..shader = ui.Gradient.radial(
          center,
          s.longestSide * (0.45 + glow * 0.25),
          [
            Color.lerp(accent, Colors.white, 0.1)!.withValues(alpha: glow.clamp(0, 1)),
            Color.lerp(accent, Colors.black, 0.8)!,
            const Color(0xFF040307),
          ],
          [0, .42, 1],
        ),
    );
    final p = Paint()..blendMode = BlendMode.plus;
    final rnd = Random(9);
    for (var i = 0; i < 70; i++) {
      final sp = 10 + rnd.nextDouble() * 30;
      final x = (rnd.nextDouble() * s.width + sin(f.time * 0.5 + i) * 20) % s.width;
      final y = (rnd.nextDouble() * s.height - f.time * sp * (0.6 + f.level)) % s.height;
      p.color = Colors.white.withValues(alpha: (0.1 + rnd.nextDouble() * 0.4) * (0.4 + f.level));
      c.drawCircle(Offset(x, y), 0.8 + rnd.nextDouble() * 2.2, p);
    }
    // Rays: 120 around, mirrored left / right so it's balanced.
    const n = 120;
    final r0 = coverSize * 0.6;
    final rays = Paint()
      ..strokeWidth = max(2.0, r0 * pi * 2 / n * 0.45)
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < n; i++) {
      final x0 = (i < n / 2 ? i : n - i) / (n / 2);
      final v = _band(x0 * 0.9);
      final a = i / n * pi * 2 - pi / 2 + f.time * 0.05;
      final d = Offset(cos(a), sin(a));
      rays.color = Color.lerp(accent, Colors.white, 0.3 + v * 0.5)!.withValues(alpha: 0.35 + v * 0.6);
      c.drawLine(center + d * r0, center + d * (r0 + 4 + v * coverSize * 0.38), rays);
    }
  }

  // ------------------------------------------------------------------ Shaders
  /// Draws a shader style; false if the shader isn't loaded.
  bool _shader(Canvas c, Size s, ui.FragmentShader? sh, double hueA, double hueB) {
    if (sh == null) return false;
    final a = _hsl(hueA, 0.85, 0.55), b = _hsl(hueB, 0.85, 0.6);
    sh
      ..setFloat(0, s.width)
      ..setFloat(1, s.height)
      ..setFloat(2, f.time)
      ..setFloat(3, f.bass)
      ..setFloat(4, f.mid)
      ..setFloat(5, f.treble)
      ..setFloat(6, f.beat)
      ..setFloat(7, a.r)
      ..setFloat(8, a.g)
      ..setFloat(9, a.b)
      ..setFloat(10, b.r)
      ..setFloat(11, b.g)
      ..setFloat(12, b.b)
      ..setFloat(13, f.level);
    c.drawRect(Offset.zero & s, Paint()..shader = sh);
    return true;
  }

  /// Plain colour clouds, for when a shader can't be used.
  bool _ambienceFallback(Canvas c, Size s) {
    final t = f.time * (0.3 + f.level);
    for (var k = 0; k < 5; k++) {
      final o = Offset(
        s.width * (0.5 + 0.35 * sin(t * (0.3 + k * 0.1) + k * 1.7)),
        s.height * (0.5 + 0.35 * cos(t * (0.25 + k * 0.08) + k)),
      );
      c.drawCircle(
        o,
        s.shortestSide * (0.35 + f.bass * 0.25),
        Paint()
          ..blendMode = BlendMode.plus
          ..shader = ui.Gradient.radial(o, s.shortestSide * (0.35 + f.bass * 0.25), [
            _hsl(hue + k * 60, 0.8, 0.45, 0.5 + f.level * 0.4),
            _hsl(hue + k * 60, 0.8, 0.45, 0),
          ]),
      );
    }
    return true;
  }

  // ------------------------------------------------------------------ Particles
  /// Thousands of glowing particles swirling round three wandering points:
  /// bass pulls them in, mids spin them, beats throw them out.
  void _particles(Canvas c, Size s) {
    c.drawRect(Offset.zero & s, Paint()..color = Colors.black);
    final sprite = scene.glow;
    final scale = s.shortestSide * 0.9;
    final cx = s.width / 2, cy = s.height / 2;
    final src = Rect.fromLTWH(0, 0, sprite.width.toDouble(), sprite.height.toDouble());
    final hues = [hue, hue + 90, hue + 150];
    final xf = <RSTransform>[];
    final rects = <Rect>[];
    final cols = <Color>[];
    for (final p in scene.particles) {
      final sp = sqrt(p[2] * p[2] + p[3] * p[3]);
      final size = (0.09 + sp * 4) * (0.8 + f.treble * 0.6);
      final k = (p[4] * 3).floor().clamp(0, 2);
      final col = _hsl(hues[k] + sp * 500, 0.85, 0.62, (p[5] * (0.6 + f.level * 0.6)).clamp(0, 1));
      // A short streak back along its path.
      for (var q = 0; q < 4; q++) {
        final b = q / 4;
        xf.add(
          RSTransform.fromComponents(
            rotation: 0,
            scale: (size * (1 - b * 0.45)).clamp(0.05, 0.28),
            anchorX: 32,
            anchorY: 32,
            translateX: cx + (p[0] - p[2] * b * 14) * scale,
            translateY: cy + (p[1] - p[3] * b * 14) * scale,
          ),
        );
        rects.add(src);
        cols.add(col.withValues(alpha: col.a * (1 - b)));
      }
    }
    c.drawAtlas(sprite, xf, rects, cols, BlendMode.modulate, null, Paint()..blendMode = BlendMode.plus);
    // A soft heart at each attractor, brighter on beats.
    for (var k = 0; k < 3; k++) {
      final o = Offset(cx + scene.attractors[k].dx * scale, cy + scene.attractors[k].dy * scale);
      final r = s.shortestSide * (0.05 + f.beat * 0.05);
      c.drawCircle(
        o,
        r,
        Paint()
          ..blendMode = BlendMode.plus
          ..shader = ui.Gradient.radial(o, r, [
            _hsl(hues[k], 0.7, 0.75, 0.35 + f.beat * 0.4),
            Colors.transparent,
          ]),
      );
    }
  }

  // ------------------------------------------------------------------ Nebula
  /// A glowing cloud swirling round a bright core, stars streaming out.
  void _nebula(Canvas c, Size s) {
    if (!_shader(c, s, VizShaders.nebula, hue + 200, hue + 300)) {
      c.drawRect(Offset.zero & s, Paint()..color = Colors.black);
    }
    final center = s.center(Offset.zero);
    final reach = s.longestSide * 0.72;
    final p = Paint()
      ..strokeCap = StrokeCap.round
      ..blendMode = BlendMode.plus;
    for (final st in scene.stars) {
      final r = st.z * st.z * reach;
      final d = Offset(cos(st.a), sin(st.a));
      p
        ..color = Colors.white.withValues(alpha: (st.z * 0.9).clamp(0, 1))
        ..strokeWidth = 0.8 + st.z * 2;
      c.drawLine(center + d * r, center + d * (r * (0.9 - f.level * 0.08)), p);
    }
  }

  // ------------------------------------------------------------------ Waterfall
  /// A spectrogram flowing down from a live spectrum line at the top: low
  /// notes left, loud is hot (black, violet, orange, white).
  void _waterfall(Canvas c, Size s) {
    c.drawRect(Offset.zero & s, Paint()..color = const Color(0xFF040209));
    final rows = f.history;
    if (rows.isEmpty) return;
    const top = 0.14;
    final y0 = s.height * top;
    final cw = s.width / VizFeed.bandCount;
    final rh = (s.height - y0) / VizFeed.historyRows;
    final p = Paint();
    for (var r = 0; r < rows.length; r++) {
      final row = rows[rows.length - 1 - r];
      final y = y0 + r * rh;
      final fade = 1 - r / VizFeed.historyRows * 0.6;
      for (var b = 0; b < VizFeed.bandCount; b++) {
        final v = row[b] * fade;
        if (v < 0.05) continue;
        p.color = _heat(v);
        c.drawRect(Rect.fromLTWH(b * cw, y, cw + .6, rh + .6), p);
      }
    }
    // The live line along the top edge of the flow.
    final pts = <Offset>[
      for (var i = 0; i < VizFeed.bandCount; i++) Offset((i + 0.5) * cw, y0 - f.bands[i] * y0 * 0.85),
    ];
    final line = _smooth(pts);
    c.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..color = _heat(0.7).withValues(alpha: 0.3)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    c.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = _heat(0.9),
    );
  }

  static Color _heat(double v) {
    const stops = [
      Color(0xFF07030F),
      Color(0xFF3B0F70),
      Color(0xFF8C2981),
      Color(0xFFDE4968),
      Color(0xFFFE9F6D),
      Color(0xFFFCFDBF),
    ];
    final x = v.clamp(0.0, 1.0) * (stops.length - 1);
    final i = x.floor().clamp(0, stops.length - 2);
    return Color.lerp(stops[i], stops[i + 1], x - i)!;
  }

  @override
  bool shouldRepaint(VizPainter old) => true;
}

/// Where each style's clock sits and how it looks: out of the way of the
/// picture, styled to match it.
({Alignment at, TextStyle style}) vizClockLook(VizStyle v, Color accent) {
  const shadow = [Shadow(color: Color(0xAA000000), blurRadius: 12)];
  TextStyle look({
    double size = 40,
    FontWeight w = FontWeight.w300,
    Color c = Colors.white,
    double space = 1,
  }) => TextStyle(
    fontSize: size,
    fontWeight: w,
    color: c,
    letterSpacing: space,
    shadows: shadow,
    fontFeatures: const [FontFeature.tabularFigures()],
  );
  return switch (v) {
    // Above the bars, clear of the wave.
    VizStyle.bars => (at: Alignment.topLeft, style: look(size: 44)),
    VizStyle.mirror => (at: Alignment.topCenter, style: look(size: 40, space: 4)),
    // A green readout, like the scope's own screen.
    VizStyle.scope => (
      at: Alignment.bottomRight,
      style: look(size: 34, w: FontWeight.w500, c: const Color(0xFF7DFFC0), space: 3),
    ),
    // Over the cover, small.
    VizStyle.coverBloom => (at: Alignment.topCenter, style: look(size: 34, w: FontWeight.w400)),
    VizStyle.ambience => (at: Alignment.bottomCenter, style: look(size: 64, w: FontWeight.w200, space: 2)),
    VizStyle.ribbons => (at: Alignment.topRight, style: look(size: 40, c: Colors.white70)),
    VizStyle.kaleido => (at: Alignment.bottomCenter, style: look(size: 40, w: FontWeight.w400, space: 3)),
    VizStyle.tunnel => (at: Alignment.topLeft, style: look(size: 44, w: FontWeight.w200)),
    VizStyle.waterfall => (
      at: Alignment.bottomRight,
      style: look(size: 34, w: FontWeight.w500, c: const Color(0xFFFCE1B0)),
    ),
  };
}
