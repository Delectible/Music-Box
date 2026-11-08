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
  ribbons('Ribbons'),
  kaleido('Kaleido'),
  tunnel('Tunnel'),
  waterfall('Waterfall');

  final String label;
  const VizStyle(this.label);

  bool get usesCover => this == coverBloom;
  static VizStyle byName(String n) => values.where((v) => v.name == n).firstOrNull ?? bars;
}

/// The sound the visualisers draw: 64 spectrum bands (0..1, low to high),
/// a waveform (-1..1) and the overall level. Live from Android's Visualizer
/// on the player's audio session; made up (but in time with play / pause)
/// when that isn't available, so the screen still moves.
class VizFeed {
  static const bandCount = 64;
  static const waveCount = 256;
  static const _ch = EventChannel('roadie/visualizer');

  final bands = Float32List(bandCount);
  final peaks = Float32List(bandCount);
  final wave = Float32List(waveCount);
  double level = 0;
  double beat = 0; // jumps to 1 on a beat, then decays

  /// Waterfall history: newest row last.
  final history = <Float32List>[];
  static const historyRows = 72;

  bool live = false;
  String? problem;
  bool playing = false;
  double time = 0;

  final _target = Float32List(bandCount);
  final _waveTarget = Float32List(waveCount);
  StreamSubscription<Object?>? _sub;
  DateTime _lastData = DateTime.fromMillisecondsSinceEpoch(0);
  double _avgLevel = 0;
  double _historyClock = 0;

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
    if (w is Uint8List) {
      for (var i = 0; i < waveCount; i++) {
        final b = w[(i * w.length / waveCount).floor()];
        _waveTarget[i] = (b - 128) / 128;
      }
    }
    _lastData = DateTime.now();
    live = true;
    problem = null;
  }

  /// Android's FFT: [re0, reN/2, re1, im1, re2, im2, ...] as signed bytes.
  void _fromFft(Uint8List raw) {
    final bytes = Int8List.sublistView(raw);
    final n = bytes.length ~/ 2;
    if (n < 8) return;
    for (var b = 0; b < bandCount; b++) {
      // Log-spaced bands from ~40 Hz up.
      final lo = max(1, (pow(n, b / bandCount) as double).floor());
      final hi = max(lo + 1, (pow(n, (b + 1) / bandCount) as double).ceil()).clamp(lo + 1, n);
      var m = 0.0;
      for (var k = lo; k < hi; k++) {
        final re = bytes[2 * k].toDouble();
        final im = bytes[2 * k + 1].toDouble();
        m = max(m, sqrt(re * re + im * im));
      }
      // Highs are quieter: lift them a little.
      final v = log(1 + m * (1 + b / bandCount * 2.5)) / log(1 + 90);
      _target[b] = v.clamp(0, 1).toDouble();
    }
  }

  void _simulate() {
    final t = time;
    final bpm = 118 / 60;
    final kick = pow(max(0, cos(t * bpm * pi * 2)), 12).toDouble();
    final energy = playing ? 1.0 : 0.0;
    for (var b = 0; b < bandCount; b++) {
      final x = b / bandCount;
      var v = 0.55 * exp(-x * 2.2) + 0.25 * kick * exp(-x * 6) + 0.18 * (0.5 + 0.5 * sin(t * 2.7 + b * 0.45));
      v += 0.15 * (0.5 + 0.5 * sin(t * 7.3 + b * 1.3)) * (0.4 + x);
      _target[b] = (v * energy).clamp(0, 1).toDouble();
    }
    for (var i = 0; i < waveCount; i++) {
      final p = i / waveCount * pi * 2;
      _waveTarget[i] =
          energy *
          (0.45 * sin(p * 4 + t * 6) + 0.2 * sin(p * 11 - t * 9) + 0.12 * sin(p * 23 + t * 3) * (0.5 + kick));
    }
  }

  /// Advances smoothing by [dt] seconds; call once a frame.
  void tick(double dt) {
    time += dt;
    if (live && DateTime.now().difference(_lastData).inMilliseconds > 600) live = false;
    if (!live) _simulate();
    final attack = 1 - exp(-dt * 30);
    final release = 1 - exp(-dt * 7);
    var sum = 0.0;
    for (var i = 0; i < bandCount; i++) {
      final t = _target[i];
      bands[i] += (t - bands[i]) * (t > bands[i] ? attack : release);
      sum += bands[i];
      peaks[i] = max(bands[i], peaks[i] - dt * 0.35);
    }
    final wl = 1 - exp(-dt * 25);
    for (var i = 0; i < waveCount; i++) {
      wave[i] += (_waveTarget[i] - wave[i]) * wl;
    }
    level = sum / bandCount;
    // A beat: low end well above its recent average.
    final low = (bands[0] + bands[1] + bands[2] + bands[3]) / 4;
    if (low > _avgLevel * 1.35 + 0.05 && beat < 0.3) beat = 1;
    beat = max(0, beat - dt * 3.5);
    _avgLevel += (low - _avgLevel) * (1 - exp(-dt * 2));
    _historyClock += dt;
    if (_historyClock > 1 / 30) {
      _historyClock = 0;
      history.add(Float32List.fromList(bands));
      if (history.length > historyRows) history.removeAt(0);
    }
  }
}
