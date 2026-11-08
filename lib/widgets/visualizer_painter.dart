import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/visualizer.dart';

/// Moving parts some styles keep between frames.
class VizScene {
  final feed = VizFeed();
  final _rnd = Random(4);
  final stars = <_Star>[];

  void tick(double dt) {
    feed.tick(dt);
    // Tunnel stars fly outwards, faster with the music.
    if (stars.isEmpty) {
      for (var i = 0; i < 220; i++) {
        stars.add(_Star(_rnd.nextDouble() * pi * 2, _rnd.nextDouble()));
      }
    }
    final speed = 0.08 + feed.level * 0.9 + feed.beat * 0.4;
    for (final s in stars) {
      s.z += dt * speed * (0.4 + s.z);
      if (s.z > 1) {
        s
          ..z = 0.02
          ..a = _rnd.nextDouble() * pi * 2;
      }
    }
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

  @override
  void paint(Canvas c, Size s) {
    switch (style) {
      case VizStyle.bars:
        _bars(c, s);
      case VizStyle.mirror:
        _mirror(c, s);
      case VizStyle.scope:
        _scope(c, s);
      case VizStyle.coverRing:
        _coverRing(c, s);
      case VizStyle.coverBloom:
        _coverBloom(c, s);
      case VizStyle.ambience:
        _ambience(c, s);
      case VizStyle.ribbons:
        _ribbons(c, s);
      case VizStyle.kaleido:
        _kaleido(c, s);
      case VizStyle.tunnel:
        _tunnel(c, s);
      case VizStyle.waterfall:
        _waterfall(c, s);
    }
  }

  void _bg(Canvas c, Size s, Color top, Color bottom) => c.drawRect(
    Offset.zero & s,
    Paint()..shader = ui.Gradient.linear(Offset.zero, Offset(0, s.height), [top, bottom]),
  );

  /// Classic LED spectrum with falling peak caps.
  void _bars(Canvas c, Size s) {
    _bg(c, s, const Color(0xFF0B0F1A), Colors.black);
    const n = 32;
    final bw = s.width / n;
    final maxH = s.height * 0.86;
    const seg = 12.0;
    final p = Paint();
    for (var i = 0; i < n; i++) {
      final v = (f.bands[i * 2] + f.bands[i * 2 + 1]) / 2;
      final h = v * maxH;
      final segs = (h / seg).floor();
      for (var k = 0; k < segs; k++) {
        final t = k * seg / maxH;
        p.color = t > 0.78
            ? const Color(0xFFFF3B30)
            : (t > 0.55 ? const Color(0xFFFFD23F) : const Color(0xFF3BE37A));
        c.drawRect(Rect.fromLTWH(i * bw + 3, s.height - 20 - (k + 1) * seg, bw - 6, seg - 3), p);
      }
      final pk = max(f.peaks[i * 2], f.peaks[i * 2 + 1]) * maxH;
      p.color = Colors.white;
      c.drawRect(Rect.fromLTWH(i * bw + 3, s.height - 20 - pk - 8, bw - 6, 3), p);
    }
  }

  /// Bars mirrored from the centre line, bass in the middle.
  void _mirror(Canvas c, Size s) {
    c.drawRect(Offset.zero & s, Paint()..color = const Color(0xFF07060C));
    const n = 56;
    final bw = s.width / n;
    final mid = s.height / 2;
    final hsv = HSLColor.fromColor(accent).hue;
    for (var i = 0; i < n; i++) {
      final b = ((i - n / 2).abs() / (n / 2) * (VizFeed.bandCount - 1)).round();
      final h = max(4.0, f.bands[b] * s.height * 0.44);
      final r = RRect.fromRectAndRadius(
        Rect.fromLTRB(i * bw + 2, mid - h, (i + 1) * bw - 2, mid + h),
        const Radius.circular(4),
      );
      c.drawRRect(
        r,
        Paint()
          ..shader = ui.Gradient.linear(
            Offset(0, mid - h),
            Offset(0, mid + h),
            [_hsl(hsv + i * 1.5, .9, .65), _hsl(hsv + 40 + i, .9, .55), _hsl(hsv + i * 1.5, .9, .65, .15)],
            [0, .5, 1],
          ),
      );
    }
  }

  /// Oscilloscope: the waveform as a glowing line.
  void _scope(Canvas c, Size s) {
    c.drawRect(Offset.zero & s, Paint()..color = const Color(0xFF020806));
    final grid = Paint()
      ..color = const Color(0x1430FFA0)
      ..strokeWidth = 1;
    for (var x = 0.0; x < s.width; x += 48) {
      c.drawLine(Offset(x, 0), Offset(x, s.height), grid);
    }
    for (var y = 0.0; y < s.height; y += 48) {
      c.drawLine(Offset(0, y), Offset(s.width, y), grid);
    }
    final path = Path();
    for (var i = 0; i < VizFeed.waveCount; i++) {
      final x = i / (VizFeed.waveCount - 1) * s.width;
      final y = s.height / 2 + f.wave[i] * s.height * 0.4;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    for (final (w, a) in [(16.0, .08), (7.0, .22), (2.5, 1.0)]) {
      c.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = w
          ..strokeJoin = StrokeJoin.round
          ..color = Color.fromRGBO(80, 255, 170, a),
      );
    }
  }

  /// Spectrum spokes around the (round) cover.
  void _coverRing(Canvas c, Size s) {
    c.drawRect(Offset.zero & s, Paint()..color = const Color(0xFF0D0A14));
    final center = s.center(Offset.zero);
    final r = coverSize / 2 + 10;
    const n = 120;
    final hue = HSLColor.fromColor(accent).hue;
    final p = Paint()
      ..strokeWidth = max(3, r * 2 * pi / n * 0.55)
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < n; i++) {
      final a = i / n * pi * 2 - pi / 2;
      final half = i < n / 2 ? i : n - i;
      final v = f.bands[(half / (n / 2) * (VizFeed.bandCount - 1)).round()];
      final l = 10 + v * min(s.width, s.height) * 0.22;
      p.color = _hsl(hue - 30 + i * 1.0, .95, .6);
      final d = Offset(cos(a), sin(a));
      c.drawLine(center + d * r, center + d * (r + l), p);
    }
  }

  /// The cover's colour glowing and pulsing behind it, with a spectrum strip.
  void _coverBloom(Canvas c, Size s) {
    final center = s.center(Offset.zero);
    final glow = 0.35 + f.level * 0.6 + f.beat * 0.25;
    c.drawRect(
      Offset.zero & s,
      Paint()
        ..shader = ui.Gradient.radial(
          center,
          max(s.width, s.height) * (0.5 + glow * 0.3),
          [
            Color.lerp(accent, Colors.white, 0.1)!.withValues(alpha: glow.clamp(0, 1)),
            Color.lerp(accent, Colors.black, 0.75)!,
            const Color(0xFF06050A),
          ],
          [0, .45, 1],
        ),
    );
    // Drifting sparks.
    final p = Paint();
    final rnd = Random(9);
    for (var i = 0; i < 50; i++) {
      final x = (rnd.nextDouble() * s.width + f.time * (8 + rnd.nextDouble() * 20)) % s.width;
      final y = (rnd.nextDouble() * s.height - f.time * (10 + rnd.nextDouble() * 25)) % s.height;
      p.color = Colors.white.withValues(alpha: 0.15 + rnd.nextDouble() * 0.35 * (0.5 + f.level));
      c.drawCircle(Offset(x, y), 1 + rnd.nextDouble() * 2.5, p);
    }
    const n = 48;
    final w = coverSize;
    final top = center.dy + coverSize / 2 + 18;
    p.color = Colors.white.withValues(alpha: 0.8);
    for (var i = 0; i < n; i++) {
      final h = 4 + f.bands[i] * 46;
      c.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(center.dx - w / 2 + i * w / n + 1, top, w / n - 2, h),
          const Radius.circular(2),
        ),
        p,
      );
    }
  }

  /// Slow colour clouds (low resolution, scaled up smooth).
  void _ambience(Canvas c, Size s) {
    const cols = 48, rows = 27;
    final cw = s.width / cols, ch = s.height / rows;
    final t = f.time * (0.4 + f.level * 1.4);
    final amp = 1 + f.beat * 0.6;
    final hue = HSLColor.fromColor(accent).hue;
    final p = Paint();
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < cols; x++) {
        final v =
            sin(x / 3.7 + t) +
            sin(y / 2.3 - t * 0.7) +
            sin((x + y) / 4.1 + t * 0.5) +
            sin(sqrt(pow(x - cols / 2, 2) + pow(y - rows / 2, 2)) / 1.9 * amp - t);
        final h = (v + 4) / 8;
        p.color = _hsl(hue + h * 300, 0.85, 0.25 + 0.3 * (0.5 + 0.5 * sin(h * pi * 3)) + f.level * 0.15);
        c.drawRect(Rect.fromLTWH(x * cw, y * ch, cw + 1, ch + 1), p);
      }
    }
  }

  /// Soft overlapping ribbons that swell with the music.
  void _ribbons(Canvas c, Size s) {
    c.drawRect(Offset.zero & s, Paint()..color = Colors.black);
    final hue = HSLColor.fromColor(accent).hue;
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..blendMode = BlendMode.plus;
    for (var k = 0; k < 5; k++) {
      final energy = f.bands[k * 10];
      for (var j = 0; j < 28; j++) {
        p.color = _hsl(hue + k * 35, .95, .6, 0.09);
        final path = Path();
        for (var i = 0; i <= 80; i++) {
          final t = i / 80;
          final y =
              s.height / 2 +
              sin(t * 6 + k * 1.3 + j * 0.025 + f.time * (0.5 + k * 0.15)) *
                  s.height *
                  0.22 *
                  sin(t * pi) *
                  (0.6 + energy) +
              sin(t * 17 + k + f.time * 2) * 22 * energy +
              j * 1.2 -
              17;
          i == 0 ? path.moveTo(0, y) : path.lineTo(t * s.width, y);
        }
        c.drawPath(path, p);
      }
    }
  }

  /// Twelve mirrored slices of spectrum petals.
  void _kaleido(Canvas c, Size s) {
    c.drawRect(Offset.zero & s, Paint()..color = const Color(0xFF05030A));
    c.save();
    c.translate(s.width / 2, s.height / 2);
    c.rotate(f.time * 0.15);
    final scale = min(s.width, s.height) / 360;
    final p = Paint()..blendMode = BlendMode.plus;
    for (var k = 0; k < 12; k++) {
      c.save();
      c.rotate(k * pi / 6);
      if (k.isOdd) c.scale(1, -1);
      for (var i = 0; i < 16; i++) {
        final v = f.bands[i * 4];
        p.color = _hsl(i * 20 + 180 + f.time * 20, .9, .55, .35);
        c.save();
        c.translate((30 + i * 10) * scale, (i * 3 + sin(f.time + i) * 4) * scale);
        c.rotate(i * 0.3 + f.time * 0.4);
        c.drawOval(
          Rect.fromCenter(center: Offset.zero, width: (12 + v * 50) * scale, height: (6 + v * 18) * scale),
          p,
        );
        c.restore();
      }
      c.restore();
    }
    c.restore();
  }

  /// Flying through a star tunnel; the rings pulse with the bass.
  void _tunnel(Canvas c, Size s) {
    c.drawRect(Offset.zero & s, Paint()..color = Colors.black);
    final center = s.center(Offset.zero);
    final reach = s.longestSide * 0.75;
    final p = Paint()..strokeCap = StrokeCap.round;
    for (final st in scene.stars) {
      final r = st.z * st.z * reach;
      final d = Offset(cos(st.a), sin(st.a));
      p
        ..color = Colors.white.withValues(alpha: st.z.clamp(0, 1))
        ..strokeWidth = 1 + st.z * 2.5;
      c.drawLine(center + d * r, center + d * (r * 0.86), p);
    }
    final hue = HSLColor.fromColor(accent).hue;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    for (var k = 0; k < 9; k++) {
      final phase = (k / 9 + f.time * 0.12) % 1;
      final r = 20 + phase * phase * reach * (1 + f.bands[k * 6] * 0.25);
      ring.color = _hsl(hue + k * 15, .9, .6, phase);
      final path = Path();
      for (var i = 0; i <= 6; i++) {
        final a = i / 6 * pi * 2 + k * 0.2 + f.time * 0.3;
        final pt = center + Offset(cos(a), sin(a)) * r;
        i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
      }
      c.drawPath(path, ring);
    }
  }

  /// Spectrogram scrolling down: low notes left, loud is hot.
  void _waterfall(Canvas c, Size s) {
    c.drawRect(Offset.zero & s, Paint()..color = const Color(0xFF05030F));
    final rows = f.history;
    if (rows.isEmpty) return;
    final cw = s.width / VizFeed.bandCount;
    final rh = s.height / VizFeed.historyRows;
    final p = Paint();
    for (var r = 0; r < rows.length; r++) {
      final row = rows[rows.length - 1 - r];
      final y = r * rh;
      for (var b = 0; b < VizFeed.bandCount; b++) {
        final v = row[b];
        if (v < 0.04) continue;
        p.color = _hsl(260 - v * 260, .9, .1 + v * .5);
        c.drawRect(Rect.fromLTWH(b * cw, y, cw + .5, rh + .5), p);
      }
    }
  }

  @override
  bool shouldRepaint(VizPainter old) => true;
}
