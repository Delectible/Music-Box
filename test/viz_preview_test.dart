// Preview looks for the visualiser redo (SHOTS=dir to write PNGs).
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shots.dart';

/// A loud moment: strong bass, a vocal hump in the mids, airy highs.
Float32List spectrum(double t) {
  final b = Float32List(64);
  for (var i = 0; i < 64; i++) {
    final x = i / 63;
    var v = 0.95 * exp(-x * 5) + 0.55 * exp(-pow((x - 0.35) / 0.12, 2)) + 0.3 * exp(-pow((x - 0.7) / 0.1, 2));
    v *= 0.75 + 0.25 * sin(i * 1.7 + t * 3);
    b[i] = v.clamp(0, 1).toDouble();
  }
  return b;
}

Float32List wave(double t) => Float32List.fromList([
  for (var i = 0; i < 256; i++)
    0.55 * sin(i / 256 * pi * 8 + t) * (0.6 + 0.4 * sin(i / 256 * pi * 3)) + 0.15 * sin(i / 256 * pi * 37),
]);

// ---------------------------------------------------------------- Bars A: LED+
class LedBars extends CustomPainter {
  final Float32List b;
  LedBars(this.b);
  @override
  void paint(Canvas c, Size s) {
    c.drawRect(
      Offset.zero & s,
      Paint()
        ..shader = ui.Gradient.linear(Offset.zero, Offset(0, s.height), [
          const Color(0xFF0A1022),
          const Color(0xFF02030A),
        ]),
    );
    final n = s.width > s.height ? 40 : 24;
    final floor = s.height * 0.74;
    final maxH = floor * 0.9;
    final bw = s.width / n;
    final seg = max(8.0, maxH / 26);
    for (var i = 0; i < n; i++) {
      final v = (b[(i * 64 / n).floor()] * 1.25).clamp(0.0, 1.0);
      final segs = (v * maxH / seg).floor();
      final x = i * bw + bw * 0.12;
      final w = bw * 0.76;
      for (var k = 0; k < segs; k++) {
        final t = k * seg / maxH;
        final col = Color.lerp(
          Color.lerp(const Color(0xFF2BF5A0), const Color(0xFFFFE14D), (t / 0.6).clamp(0, 1))!,
          const Color(0xFFFF3D5A),
          ((t - 0.6) / 0.3).clamp(0, 1),
        )!;
        final r = Rect.fromLTWH(x, floor - (k + 1) * seg + 2, w, seg - 3);
        c.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(2)), Paint()..color = col);
        // Reflection.
        final rr = Rect.fromLTWH(x, floor + k * seg + 4, w, seg - 3);
        c.drawRRect(
          RRect.fromRectAndRadius(rr, const Radius.circular(2)),
          Paint()..color = col.withValues(alpha: 0.22 * (1 - k / 14).clamp(0, 1)),
        );
      }
      // Glow over the lit column.
      c.drawRect(
        Rect.fromLTWH(x - 4, floor - segs * seg, w + 8, segs * seg),
        Paint()
          ..color = const Color(0xFF2BF5A0).withValues(alpha: 0.10)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
      );
      final pk = (v + 0.08).clamp(0, 1) * maxH;
      c.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x, floor - pk - 6, w, 4), const Radius.circular(2)),
        Paint()..color = Colors.white,
      );
    }
  }

  @override
  bool shouldRepaint(_) => true;
}

// ---------------------------------------------------------------- Bars B: Gloss & waves
class GlossBars extends CustomPainter {
  final Float32List b, w;
  final Color accent;
  GlossBars(this.b, this.w, this.accent);
  @override
  void paint(Canvas c, Size s) {
    final h = HSLColor.fromColor(accent).hue;
    c.drawRect(
      Offset.zero & s,
      Paint()
        ..shader = ui.Gradient.radial(s.center(Offset.zero), s.longestSide * 0.7, [
          HSLColor.fromAHSL(1, h, 0.6, 0.14).toColor(),
          const Color(0xFF020205),
        ]),
    );
    final n = s.width > s.height ? 48 : 28;
    final mid = s.height * 0.62;
    final bw = s.width / n;
    for (var i = 0; i < n; i++) {
      final v = b[(i * 64 / n).floor()];
      final x = i * bw + bw * 0.18;
      final bh = v * mid * 0.85;
      final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, mid - bh, bw * 0.64, bh),
        Radius.circular(bw * 0.32),
      );
      final top = HSLColor.fromAHSL(1, (h + i * 2.5) % 360, 0.9, 0.68).toColor();
      final bottom = HSLColor.fromAHSL(1, (h + i * 2.5 + 30) % 360, 0.9, 0.38).toColor();
      c.drawRRect(
        r,
        Paint()..shader = ui.Gradient.linear(Offset(0, mid - bh), Offset(0, mid), [top, bottom]),
      );
      // Gloss highlight.
      c.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x + bw * 0.08, mid - bh + 3, bw * 0.16, max(0, bh - 6)),
          Radius.circular(bw * 0.1),
        ),
        Paint()..color = Colors.white.withValues(alpha: 0.25),
      );
      // Reflection.
      c.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x, mid + 4, bw * 0.64, bh * 0.45), Radius.circular(bw * 0.32)),
        Paint()
          ..shader = ui.Gradient.linear(Offset(0, mid), Offset(0, mid + bh * 0.45), [
            bottom.withValues(alpha: 0.35),
            bottom.withValues(alpha: 0),
          ]),
      );
    }
    // The wave, glowing, across the bars.
    final path = Path();
    for (var i = 0; i < w.length; i++) {
      final px = i / (w.length - 1) * s.width;
      final py = mid * 0.55 + w[i] * mid * 0.22;
      i == 0 ? path.moveTo(px, py) : path.lineTo(px, py);
    }
    final wc = HSLColor.fromAHSL(1, (h + 180) % 360, 0.9, 0.75).toColor();
    c.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10
        ..color = wc.withValues(alpha: 0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    c.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = wc,
    );
  }

  @override
  bool shouldRepaint(_) => true;
}

// ---------------------------------------------------------------- Bars C: Neon curve
class NeonCurve extends CustomPainter {
  final Float32List b;
  NeonCurve(this.b);
  @override
  void paint(Canvas c, Size s) {
    c.drawRect(Offset.zero & s, Paint()..color = const Color(0xFF05040B));
    // Faint grid, like an old analyser.
    final grid = Paint()
      ..color = const Color(0xFF1B1A33)
      ..strokeWidth = 1;
    for (var y = s.height * 0.1; y < s.height; y += s.height / 10) {
      c.drawLine(Offset(0, y), Offset(s.width, y), grid);
    }
    for (var x = 0.0; x < s.width; x += s.width / 16) {
      c.drawLine(Offset(x, 0), Offset(x, s.height), grid);
    }
    final base = s.height * 0.86;
    final top = s.height * 0.12;
    Offset pt(int i) => Offset(i / 63 * s.width, base - b[i] * (base - top));
    final line = Path()..moveTo(pt(0).dx, pt(0).dy);
    for (var i = 1; i < 64; i++) {
      final a = pt(i - 1), p = pt(i);
      final m = Offset((a.dx + p.dx) / 2, (a.dy + p.dy) / 2);
      line.quadraticBezierTo(a.dx, a.dy, m.dx, m.dy);
    }
    line.lineTo(s.width, pt(63).dy);
    final fill = Path.from(line)
      ..lineTo(s.width, base)
      ..lineTo(0, base)
      ..close();
    const cols = [Color(0xFFFF2E97), Color(0xFF8A5CFF), Color(0xFF00E5FF)];
    final shader = ui.Gradient.linear(Offset.zero, Offset(s.width, 0), cols, const [0, 0.5, 1]);
    c.drawPath(
      fill,
      Paint()
        ..shader = ui.Gradient.linear(Offset(0, top), Offset(0, base), [
          const Color(0x668A5CFF),
          const Color(0x008A5CFF),
        ]),
    );
    c.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 14
        ..shader = shader
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
    );
    c.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..shader = shader,
    );
    // Mirror, faint, below the base line.
    c.save();
    c.translate(0, base * 2);
    c.scale(1, -1);
    c.clipRect(Rect.fromLTRB(0, base, s.width, s.height * 2));
    c.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..shader = shader
        ..color = Colors.white.withValues(alpha: 0.2),
    );
    c.restore();
  }

  @override
  bool shouldRepaint(_) => true;
}

// ---------------------------------------------------------------- Swirl A: particles
class Particles {
  final rnd = Random(7);
  final pts = <List<double>>[]; // x, y, vx, vy, group, life, px, py
  void step(Size s, double t, double bass, double mid, double dt) {
    while (pts.length < 4200) {
      final a = rnd.nextDouble() * pi * 2;
      final r = rnd.nextDouble() * 0.1;
      pts.add([cos(a) * r, sin(a) * r, 0, 0, rnd.nextDouble(), rnd.nextDouble(), 0, 0]);
    }
    // Three attractors circling the centre.
    final at = [
      for (var k = 0; k < 3; k++)
        Offset(cos(t * 0.7 + k * 2.09) * 0.32, sin(t * 0.9 + k * 2.09) * 0.22 * (1 + k * 0.2)),
    ];
    for (final p in pts) {
      final k = (p[4] * 3).floor();
      final dx = at[k].dx - p[0], dy = at[k].dy - p[1];
      final d2 = dx * dx + dy * dy + 0.01;
      final f = (0.6 + bass * 2) / d2 * 0.004;
      // Pull in, and spin around the attractor.
      p[2] += (dx * f - dy * f * (1.6 + mid * 3)) * dt * 60;
      p[3] += (dy * f + dx * f * (1.6 + mid * 3)) * dt * 60;
      p[2] *= 0.94;
      p[3] *= 0.94;
      p[6] = p[0];
      p[7] = p[1];
      p[0] += p[2];
      p[1] += p[3];
      p[5] -= dt * 0.25;
      if (p[5] <= 0 || p[0].abs() > 1.2 || p[1].abs() > 1.2) {
        final a = rnd.nextDouble() * pi * 2;
        p
          ..[0] = at[k].dx + cos(a) * 0.3
          ..[1] = at[k].dy + sin(a) * 0.3
          ..[2] = 0
          ..[3] = 0
          ..[5] = 1;
      }
    }
  }
}

class Swirl extends CustomPainter {
  final Particles ps;
  final ui.Image sprite;
  final double hueShift;
  Swirl(this.ps, this.sprite, this.hueShift);
  @override
  void paint(Canvas c, Size s) {
    c.drawRect(Offset.zero & s, Paint()..color = Colors.black);
    final scale = s.shortestSide * 0.95;
    final xf = <RSTransform>[];
    final rects = <Rect>[];
    final cols = <Color>[];
    final src = Rect.fromLTWH(0, 0, sprite.width.toDouble(), sprite.height.toDouble());
    const hues = [195.0, 285.0, 330.0];
    for (final p in ps.pts) {
      final sp = sqrt(p[2] * p[2] + p[3] * p[3]);
      final size = (0.05 + sp * 3).clamp(0.04, 0.16);
      final k = (p[4] * 3).floor();
      final hue = (hueShift + hues[k] + sp * 400) % 360;
      final col = HSLColor.fromAHSL((p[5] * 0.55).clamp(0, 1), hue, 0.85, 0.62).toColor();
      // A short streak: a few sprites back along the way it moved.
      for (var q = 0; q < 4; q++) {
        final f = q / 4;
        xf.add(
          RSTransform.fromComponents(
            rotation: 0,
            scale: size * (1 - f * 0.5),
            anchorX: sprite.width / 2,
            anchorY: sprite.height / 2,
            translateX: s.width / 2 + (p[0] - p[2] * f * 3) * scale,
            translateY: s.height / 2 + (p[1] - p[3] * f * 3) * scale,
          ),
        );
        rects.add(src);
        cols.add(col.withValues(alpha: col.a * (1 - f)));
      }
    }
    // A soft glow at each attractor's heart.
    c.drawAtlas(sprite, xf, rects, cols, BlendMode.modulate, null, Paint()..blendMode = BlendMode.plus);
  }

  @override
  bool shouldRepaint(_) => true;
}

ui.Image glowSprite() {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.drawCircle(
    const Offset(32, 32),
    32,
    Paint()
      ..shader = ui.Gradient.radial(
        const Offset(32, 32),
        32,
        [Colors.white, Colors.white.withValues(alpha: 0.35), Colors.white.withValues(alpha: 0)],
        [0, 0.25, 1],
      ),
  );
  return rec.endRecording().toImageSync(64, 64);
}

// ---------------------------------------------------------------- Swirl B: nebula shader
class Nebula extends CustomPainter {
  final ui.FragmentShader sh;
  final double t;
  Nebula(this.sh, this.t);
  @override
  void paint(Canvas c, Size s) {
    sh
      ..setFloat(0, s.width)
      ..setFloat(1, s.height)
      ..setFloat(2, t)
      ..setFloat(3, 0.8) // bass
      ..setFloat(4, 0.55) // mid
      ..setFloat(5, 0.4) // treble
      ..setFloat(6, 0.6) // beat
      ..setFloat(7, 0.10)
      ..setFloat(8, 0.45)
      ..setFloat(9, 1.0)
      ..setFloat(10, 1.0)
      ..setFloat(11, 0.25)
      ..setFloat(12, 0.75);
    c.drawRect(Offset.zero & s, Paint()..shader = sh);
  }

  @override
  bool shouldRepaint(_) => true;
}

void main() {
  for (final (name, size) in [('land', car), ('port', phone)]) {
    testWidgets('viz previews $name', (tester) async {
      setScreen(tester, size);
      final b = spectrum(1.3), w = wave(0.7);
      Future<void> draw(String id, CustomPainter p) async {
        await tester.pumpWidget(SizedBox.expand(child: CustomPaint(painter: p)));
        await shot(tester, 'viz_${id}_$name');
      }

      await draw('bars_a_led', LedBars(b));
      await draw('bars_b_gloss', GlossBars(b, w, const Color(0xFF7C4DFF)));
      await draw('bars_c_neon', NeonCurve(b));
      final ps = Particles();
      final logical = Size(size.width, size.height);
      for (var i = 0; i < 240; i++) {
        ps.step(logical, i / 60, 0.7 + 0.3 * sin(i / 9), 0.5, 1 / 60);
      }
      late ui.Image sprite;
      await tester.runAsync(() async => sprite = glowSprite());
      await draw('swirl_a_particles', Swirl(ps, sprite, 0));
      late ui.FragmentProgram prog;
      await tester.runAsync(() async => prog = await ui.FragmentProgram.fromAsset('shaders/nebula.frag'));
      await draw('swirl_b_nebula', Nebula(prog.fragmentShader(), 12));
    });
  }
}
