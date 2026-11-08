import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'crash_log.dart';
import 'http.dart';
import 'models.dart';
import 'native.dart';

class LyricLine {
  final Duration at;
  final String text;
  const LyricLine(this.at, this.text);
}

/// A song's words: timed lines (synced) or plain text.
class Lyrics {
  final List<LyricLine> lines; // empty when only plain text
  final String plain;
  final String source;
  const Lyrics({this.lines = const [], this.plain = '', required this.source});

  bool get synced => lines.isNotEmpty;
  bool get isEmpty => lines.isEmpty && plain.trim().isEmpty;

  /// The line playing at [pos] (-1 before the first).
  int lineAt(Duration pos) {
    var i = -1;
    for (var n = 0; n < lines.length; n++) {
      if (lines[n].at <= pos) {
        i = n;
      } else {
        break;
      }
    }
    return i;
  }

  /// "[01:23.45] words" lines (several stamps per line allowed).
  static List<LyricLine> parseLrc(String text) {
    final out = <LyricLine>[];
    final stamp = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
    for (final raw in const LineSplitter().convert(text)) {
      final stamps = stamp.allMatches(raw).toList();
      if (stamps.isEmpty) continue;
      final words = raw.substring(stamps.last.end).trim();
      for (final m in stamps) {
        final frac = m.group(3) ?? '0';
        final ms = int.parse(frac.padRight(3, '0').substring(0, 3));
        out.add(
          LyricLine(
            Duration(minutes: int.parse(m.group(1)!), seconds: int.parse(m.group(2)!), milliseconds: ms),
            words,
          ),
        );
      }
    }
    out.sort((a, b) => a.at.compareTo(b.at));
    return out;
  }

  static final _cache = <int, Future<Lyrics?>>{};

  /// Tests and screenshots: lyrics for [songId] without looking anywhere.
  @visibleForTesting
  static void preload(int songId, Lyrics? l) => _cache[songId] = Future.value(l);

  /// From a .lrc next to the file, then LRCLIB (lrclib.net, free and open).
  /// Kept on the device after the first look.
  static Future<Lyrics?> of(Song s) => _cache.putIfAbsent(s.id, () => _load(s));

  static Future<Lyrics?> _load(Song s) async {
    final dot = s.path.lastIndexOf('.');
    if (dot > 0) {
      try {
        final f = File('${s.path.substring(0, dot)}.lrc');
        if (f.existsSync()) {
          final t = f.readAsStringSync();
          final lines = parseLrc(t);
          return Lyrics(lines: lines, plain: lines.isEmpty ? t : '', source: 'Lyrics file next to the song');
        }
      } on Object {
        // Not readable: try online.
      }
    }
    final dir = await Native.filesDir();
    final cache = dir == null ? null : File('$dir/lyrics/${s.path.hashCode}.json');
    if (cache != null && cache.existsSync()) {
      try {
        final m = jsonDecode(cache.readAsStringSync()) as Map<String, Object?>;
        return _fromLrclib(m);
      } on Object {
        // Fetch again.
      }
    }
    try {
      Map<String, Object?>? m;
      try {
        m =
            (await Http.json(
                  Uri.https('lrclib.net', '/api/get', {
                    'track_name': s.title,
                    'artist_name': s.artist,
                    'album_name': s.album,
                    'duration': '${s.duration.inSeconds}',
                  }),
                ))
                as Map<String, Object?>?;
      } on HttpFailure catch (e) {
        if (e.status != 404) rethrow;
      }
      if (m == null) {
        // No exact match: search, and take one close in length.
        final list =
            (await Http.json(
                  Uri.https('lrclib.net', '/api/search', {'track_name': s.title, 'artist_name': s.artist}),
                ))
                as List? ??
            const [];
        m = list.cast<Map<String, Object?>>().where((x) {
          final d = (x['duration'] as num?)?.toDouble() ?? 0;
          return (d - s.duration.inSeconds).abs() <= 4;
        }).firstOrNull;
      }
      if (m == null) return null;
      if (cache != null) {
        cache.parent.createSync(recursive: true);
        cache.writeAsStringSync(jsonEncode(m));
      }
      return _fromLrclib(m);
    } on Object catch (e) {
      CrashLog.note('lyrics for ${s.title}: $e');
      unawaited(_cache.remove(s.id)); // try again next time
      return null;
    }
  }

  static Lyrics? _fromLrclib(Map<String, Object?> m) {
    if (m['instrumental'] == true) return const Lyrics(plain: '♪ Instrumental', source: 'LRCLIB');
    final synced = '${m['syncedLyrics'] ?? ''}';
    final plain = '${m['plainLyrics'] ?? ''}';
    final l = Lyrics(lines: parseLrc(synced), plain: plain == 'null' ? '' : plain, source: 'LRCLIB');
    return l.isEmpty ? null : l;
  }
}
