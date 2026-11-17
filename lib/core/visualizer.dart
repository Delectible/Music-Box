import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'crash_log.dart';

enum VizStyle {
  bars('Bars'),
  mirror('Mirror'),
  scope('Scope'),
  coverBloom('Cover bloom'),
  ambience('Ambience'),
  // Saved names stay; these three became the particle swirl, Alchemy-style
  // mirrors and the nebula.
  ribbons('Particles'),
  kaleido('Alchemy'),
  tunnel('Nebula'),
  waterfall('Waterfall');

  final String label;
  const VizStyle(this.label);

  bool get usesCover => this == coverBloom;
  static VizStyle byName(String n) => values.where((v) => v.name == n).firstOrNull ?? bars;
}

/// The sound the visualisers draw: 64 spectrum bands (0..1, low to high),
/// a waveform (-1..1), the overall level, bass / mid / treble, and a beat
/// that jumps on onsets. Live from Android's Visualizer on the player's
/// audio session; made up (but in time with play / pause) when that isn't
/// available, so the screen still moves.
///
/// Levels are relative to the song's own recent loudness (a slow automatic
/// gain, like a VU meter's), so a quiet verse looks quiet and the chorus
/// fills the screen, whatever the device volume.
class VizFeed {
  static const bandCount = 64;
  static const waveCount = 256;
  static const _ch = EventChannel('roadie/visualizer');

  final bands = Float32List(bandCount);
  final peaks = Float32List(bandCount);
  final wave = Float32List(waveCount);
  double level = 0;
  double bass = 0, mid = 0, treble = 0;

  /// Jumps to 1 on an onset (kick, snare, a new chord), then decays.
  double beat = 0;

  /// Counts beats, for styles that change something on each one.
  int beats = 0;

  /// Waterfall history: newest row last.
  final history = <Float32List>[];
  static const historyRows = 90;

  bool live = false;
  String? problem;
  bool playing = false;
  double time = 0;

  final _target = Float32List(bandCount);
  final _prevRaw = Float32List(bandCount);
  final _waveTarget = Float32List(waveCount);
  StreamSubscription<Object?>? _sub;
  DateTime _lastData = DateTime.fromMillisecondsSinceEpoch(0);
  double _historyClock = 0;

  // Automatic gain: the loudness (dB) the top of the scale stands for.
  double _ref = -20;
  double _waveRef = 0.2;
  // Onset detection: recent flux values.
  final _flux = <double>[];
  double _pendingBeat = 0;

  void start(int? session) {
    stop();
    try {
      _sub = _ch
          .receiveBroadcastStream(session ?? 0)
          .listen(
            handle,
            onError: (Object e) {
              problem = e is PlatformException ? (e.message ?? e.code) : '$e';
              live = false;
              CrashLog.note('visualiser: $problem');
            },
          );
    } on Object catch (e) {
      problem = '$e';
    }
  }

  void stop() {
    unawaited(_sub?.cancel());
    _sub = null;
    live = false;
  }

  /// One message from the native side ({'fft': bytes} or {'wave': bytes}).
  @visibleForTesting
  void handle(Object? event) {
    if (event is! Map) return;
    final fft = event['fft'];
    final w = event['wave'];
    if (fft is Uint8List) _fromFft(fft);
    if (w is Uint8List) _fromWave(w);
    _lastData = DateTime.now();
    live = true;
    problem = null;
  }

  void _fromWave(Uint8List w) {
    var peak = 0.0;
    for (var i = 0; i < waveCount; i++) {
      final b = w[(i * w.length / waveCount).floor()];
      final v = (b - 128) / 128;
      _waveTarget[i] = v;
      peak = max(peak, v.abs());
    }
    // The waveform's own slow gain: rises fast, falls over a few seconds.
    _waveRef = peak > _waveRef ? _waveRef + (peak - _waveRef) * 0.5 : max(0.02, _waveRef * 0.985);
    final g = 0.9 / _waveRef;
    for (var i = 0; i < waveCount; i++) {
      _waveTarget[i] = (_waveTarget[i] * g).clamp(-1, 1);
    }
  }

  /// Android's FFT: [re0, reN/2, re1, im1, re2, im2, ...] as signed bytes.
  void _fromFft(Uint8List raw) {
    final bytes = Int8List.sublistView(raw);
    final n = bytes.length ~/ 2;
    if (n < 8) return;
    final db = Float32List(bandCount);
    var loudest = -120.0;
    for (var b = 0; b < bandCount; b++) {
      // Log-spaced bands from ~40 Hz up.
      final lo = max(1, (pow(n, b / bandCount) as double).floor());
      final hi = max(lo + 1, (pow(n, (b + 1) / bandCount) as double).ceil()).clamp(lo + 1, n);
      var e = 0.0;
      for (var k = lo; k < hi; k++) {
        final re = bytes[2 * k].toDouble();
        final im = bytes[2 * k + 1].toDouble();
        e = max(e, re * re + im * im);
      }
      // Highs carry less energy: tilt them up (about 3 dB an octave).
      final tilt = 9 * b / bandCount;
      // Byte rounding leaves a hiss of a few dB: below 6 dB counts as silence.
      db[b] = e < 4 ? -60 : 10 * log(e) / ln10 + tilt;
      loudest = max(loudest, db[b]);
    }
    // Gain: catches up with loud parts in a moment, eases down over ~8 s,
    // so dynamics within a song survive.
    _ref = loudest > _ref ? _ref + (loudest - _ref) * 0.35 : _ref - 0.12;
    _ref = max(_ref, 24); // silence stays dark
    const range = 36.0; // dB shown from bottom to top
    var flux = 0.0;
    for (var b = 0; b < bandCount; b++) {
      final v = ((db[b] - (_ref - range)) / range).clamp(0.0, 1.0);
      // Curve: keeps the bottom calm, lets peaks reach the top.
      final shaped = v * v * (1.4 - 0.4 * v);
      flux += max(0, shaped - _prevRaw[b]) * (b < 12 ? 1.6 : 1.0);
      _prevRaw[b] = shaped;
      _target[b] = shaped;
    }
    // An onset: flux well above its recent average.
    _flux.add(flux);
    if (_flux.length > 24) _flux.removeAt(0);
    final mean = _flux.reduce((a, b) => a + b) / _flux.length;
    var varc = 0.0;
    for (final x in _flux) {
      varc += (x - mean) * (x - mean);
    }
    final sd = sqrt(varc / _flux.length);
    if (_flux.length > 6 && flux > mean + sd * 1.3 && flux > 0.35) {
      _pendingBeat = ((flux - mean) / (sd * 3 + 0.2)).clamp(0.5, 1.0);
    }
  }

  void _simulate() {
    final t = time;
    const bpm = 118 / 60;
    final ph = (t * bpm) % 1;
    final kick = pow(1 - ph, 8).toDouble();
    final energy = playing ? 0.75 + 0.25 * sin(t * 0.21) : 0.0;
    for (var b = 0; b < bandCount; b++) {
      final x = b / bandCount;
      var v = 0.55 * exp(-x * 2.2) + 0.35 * kick * exp(-x * 6) + 0.18 * (0.5 + 0.5 * sin(t * 2.7 + b * 0.45));
      v += 0.15 * (0.5 + 0.5 * sin(t * 7.3 + b * 1.3)) * (0.4 + x);
      _target[b] = (v * energy).clamp(0, 1).toDouble();
    }
    if (playing && ph < 0.05 && beat < 0.3) _pendingBeat = 0.9;
    for (var i = 0; i < waveCount; i++) {
      final p = i / waveCount * pi * 2;
      _waveTarget[i] =
          energy *
          (0.45 * sin(p * 4 + t * 6) + 0.2 * sin(p * 11 - t * 9) + 0.12 * sin(p * 23 + t * 3) * (0.5 + kick));
    }
  }

  /// Advances smoothing by [dt] seconds; call once a frame. Smoothing is by
  /// time, not frames, so motion is the same at any frame rate.
  void tick(double dt) {
    time += dt;
    if (live && DateTime.now().difference(_lastData).inMilliseconds > 600) live = false;
    if (!live) _simulate();
    // Fast up (25 ms), softer down (180 ms): punchy but not jittery.
    final attack = 1 - exp(-dt / 0.025);
    final release = 1 - exp(-dt / 0.18);
    var sum = 0.0, lo = 0.0, md = 0.0, hi = 0.0;
    for (var i = 0; i < bandCount; i++) {
      final t = _target[i];
      bands[i] += (t - bands[i]) * (t > bands[i] ? attack : release);
      sum += bands[i];
      if (i < 10) {
        lo += bands[i];
      } else if (i < 38) {
        md += bands[i];
      } else {
        hi += bands[i];
      }
      // Caps hang a moment, then fall faster and faster.
      peaks[i] = bands[i] >= peaks[i]
          ? bands[i]
          : max(bands[i], peaks[i] - dt * (0.25 + (1 - peaks[i]) * 0.6));
    }
    final wl = 1 - exp(-dt / 0.03);
    for (var i = 0; i < waveCount; i++) {
      wave[i] += (_waveTarget[i] - wave[i]) * wl;
    }
    double ease(double cur, double to, double up, double down) =>
        cur + (to - cur) * (1 - exp(-dt / (to > cur ? up : down)));
    level = ease(level, sum / bandCount, 0.04, 0.25);
    bass = ease(bass, lo / 10, 0.03, 0.2);
    mid = ease(mid, md / 28, 0.05, 0.3);
    treble = ease(treble, hi / 26, 0.03, 0.2);
    if (_pendingBeat > 0) {
      if (_pendingBeat > beat) {
        beat = _pendingBeat;
        beats++;
      }
      _pendingBeat = 0;
    }
    beat = max(0, beat - dt * 3.2);
    _historyClock += dt;
    if (_historyClock > 1 / 30) {
      _historyClock = 0;
      history.add(Float32List.fromList(bands));
      if (history.length > historyRows) history.removeAt(0);
    }
  }
}
