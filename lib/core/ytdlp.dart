import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'crash_log.dart';
import 'http.dart';

class YtdlpResult {
  final int exit;
  final String out, err;
  const YtdlpResult(this.exit, this.out, this.err);
}

class YtdlpFailure implements Exception {
  final String message; // plain words
  final String detail; // yt-dlp's own error
  YtdlpFailure(this.message, this.detail);

  /// The connection dropped / timed out: worth waiting and trying again.
  bool get network => message == Ytdlp.noInternet;
  @override
  String toString() => message;
}

/// yt-dlp, bundled (youtubedl-android, MainActivity's `roadie/ytdlp`). It
/// updates itself from yt-dlp's GitHub releases, so when a site changes,
/// an update fixes it: daily in the background (Settings), and straight
/// away when something fails in a way that looks like the site changed.
class Ytdlp {
  static const _ch = MethodChannel('roadie/ytdlp');
  static const _events = EventChannel('roadie/ytdlp/progress');
  static Stream<Map<Object?, Object?>>? _progress;

  /// Settings the healing uses (set by main.dart).
  static String channel = 'stable';
  static bool nightlyFallback = true;

  /// Options for every run: no stray config, patient with slow networks.
  /// Long timeouts and growing waits between tries, for weak car Wi-Fi and
  /// phone hotspots; IPv4 only, since half-working IPv6 on hotspots makes
  /// every connection wait for a timeout first.
  static const base = [
    '--ignore-config',
    '--no-color',
    '--force-ipv4',
    '--socket-timeout',
    '60',
    '--retries',
    '15',
    '--fragment-retries',
    '15',
    '--extractor-retries',
    '5',
    '--retry-sleep',
    'http:exp=2:30',
    '--retry-sleep',
    'fragment:exp=1:20',
    '--retry-sleep',
    'extractor:exp=2:20',
  ];

  static const noInternet = 'No internet connection (or it dropped)';
  static const badClock =
      'This device\'s date or time is wrong, so secure sites are refused. Set the date and time (or turn on automatic time)';

  /// Bytes a second from a yt-dlp progress line ("… at 1.20MiB/s ETA …").
  static double? speedOf(String line) {
    final m = RegExp(r'at\s+([\d.]+)\s*([KMG]?i?B)/s').firstMatch(line);
    if (m == null) return null;
    final n = double.tryParse(m[1]!) ?? 0;
    final unit = m[2]!.toUpperCase();
    final mult = unit.startsWith('K')
        ? 1024
        : unit.startsWith('M')
        ? 1024 * 1024
        : unit.startsWith('G')
        ? 1 << 30
        : 1;
    return n * mult;
  }

  static Future<YtdlpResult> _raw(String method, Map<String, Object?> args) async {
    final m = await _ch.invokeMapMethod<String, Object?>(method, args) ?? const {};
    return YtdlpResult((m['exit'] as num?)?.toInt() ?? -1, '${m['out'] ?? ''}', '${m['err'] ?? ''}');
  }

  /// Runs yt-dlp; on a breakage-looking failure updates yt-dlp and tries
  /// once more. Throws [YtdlpFailure] with plain words.
  static Future<YtdlpResult> run(String url, List<String> args, {String? id}) => _healing(
    () => _raw('run', {
      'url': url,
      'args': [...base, ...args],
      'id': id,
    }),
  );

  /// A download with progress (0..1); same healing as [run].
  static Future<YtdlpResult> download(
    String url,
    List<String> args, {
    required String id,
    required void Function(double progress, double? bytesPerSecond) progress,
  }) {
    _progress ??= _events
        .receiveBroadcastStream()
        .map((e) => (e as Map).cast<Object?, Object?>())
        .asBroadcastStream();
    final sub = _progress!.where((e) => e['id'] == id).listen((e) {
      final p = (e['progress'] as num?)?.toDouble() ?? -1;
      progress(p < 0 ? -1 : p / 100, speedOf('${e['line'] ?? ''}'));
    });
    return _healing(
      () => _raw('download', {
        'url': url,
        'args': [...base, ...args],
        'id': id,
      }),
    ).whenComplete(sub.cancel);
  }

  static Future<void> cancel(String id) async {
    try {
      await _ch.invokeMethod('cancel', {'id': id});
    } on Object {
      // Already finished.
    }
  }

  /// (version, build name), e.g. ("2026.10.26", "stable").
  static Future<String> version() async {
    try {
      final m = await _ch.invokeMapMethod<String, Object?>('version');
      return '${m?['version'] ?? '?'}';
    } on Object {
      return 'not ready';
    }
  }

  /// Checks for a newer yt-dlp: "DONE" (updated) or "ALREADY_UP_TO_DATE".
  static Future<String> update({String? on}) async {
    final s = await _ch.invokeMethod<String>('update', {'channel': on ?? channel}) ?? '';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ytdlpLastCheck', '${DateTime.now().millisecondsSinceEpoch}|$s');
    return s;
  }

  /// Turns the daily background check on or off.
  static Future<void> schedule({required bool enabled}) async {
    try {
      await _ch.invokeMethod('schedule', {'enabled': enabled, 'channel': channel});
    } on Object {
      // Tests / no device.
    }
  }

  static DateTime _lastHeal = DateTime.fromMillisecondsSinceEpoch(0);

  static Future<YtdlpResult> _healing(Future<YtdlpResult> Function() go) async {
    var r = await _guard(go);
    if (r.exit == 0) return r;
    if (looksBroken(r.err) && DateTime.now().difference(_lastHeal) > const Duration(minutes: 20)) {
      _lastHeal = DateTime.now();
      CrashLog.note('yt-dlp failed like a site change; updating. ${_firstError(r.err)}');
      try {
        var s = await update();
        // Still failing on an up-to-date stable: the fix may only be in nightly so far.
        if (s == 'ALREADY_UP_TO_DATE' && channel == 'stable' && nightlyFallback) {
          s = await update(on: 'nightly');
        }
        CrashLog.note('yt-dlp update: $s');
        r = await _guard(go);
        if (r.exit == 0) return r;
      } on Object catch (e) {
        CrashLog.note('yt-dlp update failed: $e');
      }
    }
    throw YtdlpFailure(friendly(r.err), _firstError(r.err));
  }

  static Future<YtdlpResult> _guard(Future<YtdlpResult> Function() go) async {
    try {
      return await go();
    } on PlatformException catch (e) {
      if (e.code == 'cancelled') throw YtdlpFailure('Cancelled', 'cancelled');
      return YtdlpResult(-1, '', '${e.message}\n${e.details ?? ''}');
    }
  }

  static String _firstError(String err) =>
      err.split('\n').firstWhere((l) => l.contains('ERROR'), orElse: () => err.split('\n').first).trim();

  /// Failures an update can fix (the site changed), not ones it can't
  /// (no internet, track removed, not available here).
  static bool looksBroken(String err) {
    final e = err.toLowerCase();
    if (_isNetwork(e) ||
        _isClock(e) ||
        e.contains('404') ||
        e.contains('not available in your country') ||
        e.contains('geo')) {
      return false;
    }
    return e.contains('unable to extract') ||
        e.contains('client id') ||
        e.contains('http error 401') ||
        e.contains('http error 403') ||
        e.contains('please report this issue') ||
        e.contains('keyerror') ||
        e.contains('typeerror') ||
        e.contains('jsondecodeerror') ||
        e.contains('unsupported url');
  }

  static bool _isNetwork(String e) =>
      e.contains('urlopen error') ||
      e.contains('timed out') ||
      e.contains('name or service not known') ||
      e.contains('no address associated') ||
      e.contains('network is unreachable') ||
      e.contains('connection reset') ||
      e.contains('connection refused') ||
      e.contains('connection aborted') ||
      e.contains('temporary failure in name resolution') ||
      e.contains('read timed out') ||
      e.contains('remote end closed connection') ||
      e.contains('incompleteread');

  static bool _isClock(String e) =>
      e.contains('certificate is not yet valid') ||
      e.contains('certificate has expired') ||
      e.contains('not yet valid');

  /// yt-dlp's error in plain words.
  static String friendly(String err) {
    final e = err.toLowerCase();
    if (_isClock(e)) return badClock;
    if (e.contains('read-only file system') || (e.contains('permission denied') && e.contains('/storage/'))) {
      return e.contains('/storage/emulated')
          ? 'Roadie isn\'t allowed to save there. Allow file access or pick another folder'
          : removableReadOnly;
    }
    if (_isNetwork(e)) return noInternet;
    if (e.contains('requested format is not available') || e.contains('preview')) {
      return 'SoundCloud only offers a 30-second preview of this track (it\'s for SoundCloud Go+ subscribers)';
    }
    if (e.contains('404') || e.contains('not found')) return 'This track was removed or made private';
    if (e.contains('geo') || e.contains('not available in your country')) {
      return 'Not available in your country';
    }
    if (e.contains('http error 429')) return 'SoundCloud is limiting requests. Try again in a few minutes';
    if (looksBroken(err)) {
      return 'SoundCloud changed something. An update didn\'t fix it yet; try again later';
    }
    final first = _firstError(err).replaceFirst(RegExp(r'^ERROR:\s*(\[[^\]]+\]\s*)?'), '');
    return first.isEmpty ? 'The download didn\'t work' : first;
  }

  /// The JSON yt-dlp printed with -J.
  static Map<String, Object?> json(YtdlpResult r) {
    final line = r.out.split('\n').lastWhere((l) => l.trimLeft().startsWith('{'), orElse: () => '{}');
    return (jsonDecode(line) as Map).cast<String, Object?>();
  }
}
