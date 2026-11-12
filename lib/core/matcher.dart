import 'dart:math';

import 'sources.dart';
import 'ytdlp.dart';

/// No SoundCloud upload looked like the song.
class NoMatch implements Exception {
  final String message;
  NoMatch(this.message);
  @override
  String toString() => message;
}

/// Only something close was found (another version, a different length…):
/// the person decides whether to keep it.
class CloseMatch implements Exception {
  final Found found;
  CloseMatch(this.found);
  @override
  String toString() => 'Close match found';
}

/// A SoundCloud upload and how well it matched.
class Found {
  final Uri page;
  final String title, uploader;
  final Duration? length;
  final String? cover;
  final double score;
  const Found(this.page, this.title, this.uploader, this.length, this.cover, this.score);
}

/// The good matches (best first) and, when there are none, the close ones.
class Matches {
  final List<Found> good, close;
  const Matches(this.good, this.close);
}

/// Finds a song (from a Spotify / YouTube link: title, artist, length) on
/// SoundCloud, the way spotDL-style apps do: search, then score each
/// upload on title, artist, length and the words that mean a different
/// version (remix, live, sped up…).
class SongMatcher {
  /// Found pages, best first, by "artist|title"; a retry doesn't search again.
  static final _cache = <String, Matches>{};

  static const _versions = [
    'remix',
    'cover',
    'live',
    'nightcore',
    'sped up',
    'spedup',
    'speed up',
    'speedup',
    'slowed',
    'reverb',
    'karaoke',
    'instrumental',
    'acapella',
    'a cappella',
    '8d',
    'mashup',
    'bootleg',
    'flip',
    'vip',
    'extended',
    'edit',
    'rework',
    'tribute',
    'chopped',
    'bass boosted',
    'loop',
  ];

  static String norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[’`´]'), "'")
      .replaceAll('&', ' and ')
      .replaceAll(RegExp(r"[^\p{L}\p{N}' ]+", unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static Set<String> _words(String s) => norm(s).split(' ').where((w) => w.isNotEmpty).toSet();

  /// The title without "(feat. …)", "- Remastered 2011" and the like.
  static String coreTitle(String t) => t
      .replaceAll(RegExp(r'\s*[\(\[](feat|ft|with)\.?[^\)\]]*[\)\]]', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s+[-–]\s+.*(remaster|version|mono|stereo|edit).*$', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s*[\(\[][^\)\]]*remaster[^\)\]]*[\)\]]', caseSensitive: false), '')
      .trim();

  static List<String> artistsOf(String a) => a
      .split(RegExp(r',|&|\s+x\s+|\s+feat\.?\s+|\s+ft\.?\s+|\s+and\s+', caseSensitive: false))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  /// 0..1: how likely [c] is the song. Below [threshold] it's not used.
  static double score({
    required String title,
    required String artist,
    Duration? length,
    required String candTitle,
    required String candUploader,
    Duration? candLength,
  }) {
    final want = _words(coreTitle(title));
    if (want.isEmpty) return 0;
    final hay = '${norm(candTitle)} ${norm(candUploader)}';
    final have = _words(candTitle);
    // Title: how much of the song's title is there.
    final t = want.where(have.contains).length / want.length;
    if (t < 0.6) return 0;
    var s = 0.55 * t;
    // Extra words in the upload's title that aren't the artist: a little less sure.
    final artistWords = _words(artist);
    final extra = have.difference(want).difference(artistWords).where((w) => w.length > 2).length;
    s -= (extra * 0.02).clamp(0, 0.1);
    // Artist: the main one named in the title or as the uploader.
    final names = artistsOf(artist);
    if (names.isEmpty) {
      s += 0.15;
    } else {
      final main = norm(names.first);
      final squashed = hay.replaceAll(' ', '');
      if (hay.contains(main) || squashed.contains(main.replaceAll(' ', ''))) {
        s += 0.3;
        // Uploaded by the artist themselves: the one to prefer.
        if (norm(candUploader).replaceAll(' ', '').contains(main.replaceAll(' ', ''))) s += 0.05;
      } else if (names.skip(1).any((n) => hay.contains(norm(n)))) {
        s += 0.15;
      }
    }
    // Length: the strongest sign it's the same recording.
    if (length != null && candLength != null && length > Duration.zero && candLength > Duration.zero) {
      final d = (length - candLength).inSeconds.abs();
      // Reuploads that are a bit off are often sped up or cut to dodge takedowns.
      s += d <= 3
          ? 0.15
          : d <= 7
          ? 0.05
          : d <= 15
          ? -0.2
          : d <= 30
          ? -0.35
          : -0.5;
      // 30 seconds exactly: a Go+ preview clip.
      if (candLength.inSeconds == 30 && length.inSeconds > 40) s -= 0.5;
    }
    // A different version, when the song isn't that version.
    final songText = norm('$title $artist');
    for (final v in _versions) {
      final re = RegExp('(^| )$v( |\$)');
      if (re.hasMatch(norm(candTitle)) && !re.hasMatch(songText)) s -= 0.5;
    }
    return max(0, s); // over 1 is fine: it only orders the best ones
  }

  static const threshold = 0.6;

  /// Below [threshold] but worth asking about.
  static const closeFrom = 0.3;

  /// SoundCloud uploads for the song: good ones best first (up to 3), or
  /// close ones when nothing good turned up.
  static Future<Matches> find(RemoteTrack t) async {
    final key = '${norm(t.artist)}|${norm(t.title)}|${t.length?.inSeconds}';
    final hit = _cache[key];
    if (hit != null) return hit;
    final main = artistsOf(t.artist).firstOrNull ?? '';
    var m = await _search(t, '$main ${coreTitle(t.title)}'.trim());
    // Nothing good: try the full title and every artist, the way the song is listed.
    if (m.good.isEmpty) {
      final again = await _search(t, '${t.title} ${t.artist}'.trim());
      m = again.good.isNotEmpty
          ? again
          : Matches(const [], ([...m.close, ...again.close]..sort(_best)).take(3).toList());
    }
    _cache[key] = m;
    return m;
  }

  /// The good pages, or [CloseMatch] / [NoMatch].
  static Future<List<Found>> pages(RemoteTrack t) async {
    final m = await find(t);
    if (m.good.isNotEmpty) return m.good;
    if (m.close.isNotEmpty) throw CloseMatch(m.close.first);
    throw NoMatch('Not found on SoundCloud');
  }

  static int _best(Found a, Found b) => b.score.compareTo(a.score);

  static Future<Matches> _search(RemoteTrack t, String query) async {
    final j = Ytdlp.json(await Ytdlp.run('scsearch10:$query', ['-J', '--flat-playlist']));
    final all = <Found>[];
    final seen = <String>{};
    for (final raw in (j['entries'] as List? ?? const []).whereType<Map<Object?, Object?>>()) {
      final url = '${raw['webpage_url'] ?? raw['url'] ?? ''}';
      if (!url.startsWith('http') || !seen.add(url)) continue;
      final secs = (raw['duration'] as num?)?.toDouble();
      final len = secs == null ? null : Duration(milliseconds: (secs * 1000).round());
      final s = score(
        title: t.title,
        artist: t.artist,
        length: t.length,
        candTitle: '${raw['title'] ?? ''}',
        candUploader: '${raw['uploader'] ?? ''}',
        candLength: len,
      );
      if (s < closeFrom) continue;
      all.add(
        Found(
          Uri.parse(url),
          '${raw['title'] ?? ''}',
          '${raw['uploader'] ?? ''}',
          len,
          SoundCloud.artOf(raw.cast<String, Object?>()),
          s,
        ),
      );
    }
    all.sort(_best);
    return Matches(
      all.where((f) => f.score >= threshold).take(3).toList(),
      all.where((f) => f.score < threshold).take(3).toList(),
    );
  }

  /// A stream to preview the SoundCloud upload that would be downloaded
  /// (the close one when that's all there is).
  static Future<Uri> preview(RemoteTrack t) async {
    final m = await find(t);
    final f = m.good.firstOrNull ?? m.close.firstOrNull;
    if (f == null) throw NoMatch('Not found on SoundCloud');
    return SoundCloud.streamUrl('${f.page}');
  }
}
