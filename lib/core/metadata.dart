import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'crash_log.dart';
import 'http.dart';
import 'models.dart';
import 'native.dart';

/// Album names that mean "no album" (a download folder, a player's stand-in).
String realAlbum(String a) =>
    RegExp(
      r'^\s*(singles?|unknown album|<unknown>|unknown|no album|none)\s*$',
      caseSensitive: false,
    ).hasMatch(a)
    ? ''
    : a;

/// Tags for one file. Empty strings mean "not known".
class TagValues {
  final String title, artist, album, albumArtist, genre, year, track, trackTotal, disc;
  final String mbTrackId, mbReleaseId, mbArtistId;

  const TagValues({
    this.title = '',
    this.artist = '',
    this.album = '',
    this.albumArtist = '',
    this.genre = '',
    this.year = '',
    this.track = '',
    this.trackTotal = '',
    this.disc = '',
    this.mbTrackId = '',
    this.mbReleaseId = '',
    this.mbArtistId = '',
  });

  factory TagValues.fromMap(Map<String, Object?> m) {
    String s(String k) => (m[k] ?? '').toString().trim();
    return TagValues(
      title: s('title'),
      artist: s('artist'),
      album: realAlbum(s('album')),
      albumArtist: s('albumArtist'),
      genre: s('genre'),
      year: s('year'),
      track: s('track'),
      trackTotal: s('trackTotal'),
      disc: s('disc'),
      mbTrackId: s('musicbrainzTrackId'),
      mbReleaseId: s('musicbrainzReleaseId'),
      mbArtistId: s('musicbrainzArtistId'),
    );
  }

  /// What the library knows about a song (MediaStore's "Unknown ..." is blank).
  factory TagValues.ofSong(Song s) => TagValues(
    title: s.title == s.fileName ? '' : s.title,
    artist: s.artist == 'Unknown artist' ? '' : s.artist,
    album: realAlbum(s.album == 'Unknown album' ? '' : s.album),
    albumArtist: s.albumArtist == 'Unknown artist' ? '' : s.albumArtist,
    genre: s.genre == 'Unknown genre' ? '' : s.genre,
    year: s.year > 0 ? '${s.year}' : '',
    track: s.track > 0 ? '${s.track}' : '',
    disc: s.disc > 0 ? '${s.disc}' : '',
  );

  Map<String, String> toMap() => {
    'title': title,
    'artist': artist,
    'album': album,
    'albumArtist': albumArtist,
    'genre': genre,
    'year': year,
    'track': track,
    'trackTotal': trackTotal,
    'disc': disc,
    'musicbrainzTrackId': mbTrackId,
    'musicbrainzReleaseId': mbReleaseId,
    'musicbrainzArtistId': mbArtistId,
  };

  /// Our values, with blanks filled from [other].
  TagValues fill(TagValues other) {
    String f(String a, String b) => a.isNotEmpty ? a : b;
    return TagValues(
      title: f(title, other.title),
      artist: f(artist, other.artist),
      album: f(album, other.album),
      albumArtist: f(albumArtist, other.albumArtist),
      genre: f(genre, other.genre),
      year: f(year, other.year),
      track: f(track, other.track),
      trackTotal: f(trackTotal, other.trackTotal),
      disc: f(disc, other.disc),
      mbTrackId: f(mbTrackId, other.mbTrackId),
      mbReleaseId: f(mbReleaseId, other.mbReleaseId),
      mbArtistId: f(mbArtistId, other.mbArtistId),
    );
  }

  /// Missing the basics a library needs.
  bool get incomplete => title.isEmpty || artist.isEmpty || album.isEmpty || genre.isEmpty || year.isEmpty;
}

/// Best guess from a file name like "03 - Artist - Title.mp3" or
/// "Artist - Title (Official Audio).flac", and its folders (Artist/Album/).
TagValues guessFromPath(String path) {
  final parts = path.split('/');
  var name = parts.last;
  final dot = name.lastIndexOf('.');
  if (dot > 0) name = name.substring(0, dot);
  name = name.replaceAll('_', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  // Noise often in downloaded names.
  name = name
      .replaceAll(
        RegExp(
          r'[\(\[](official|lyric|lyrics|audio|video|hq|hd|explicit|visualizer)[^\)\]]*[\)\]]',
          caseSensitive: false,
        ),
        '',
      )
      .trim();
  var track = '';
  final num = RegExp(r'^(\d{1,3})\s*[-.)]?\s+').firstMatch(name);
  if (num != null) {
    track = '${int.parse(num.group(1)!)}';
    name = name.substring(num.end);
  }
  var artist = '';
  var title = name;
  final dash = name.split(RegExp(r'\s+[-–—]\s+'));
  if (dash.length >= 2) {
    artist = dash.first.trim();
    title = dash.sublist(1).join(' - ').trim();
  }
  var album = '';
  if (parts.length >= 3) {
    album = parts[parts.length - 2];
    if (artist.isEmpty && parts.length >= 4) artist = parts[parts.length - 3];
    // A folder named like the storage root or "Music" isn't an album.
    if (RegExp(r'^(music|download|downloads|roadie|0|emulated)$', caseSensitive: false).hasMatch(album) ||
        realAlbum(album).isEmpty) {
      album = '';
    }
  }
  return TagValues(title: title, artist: artist, album: album, track: track);
}

/// A lookup stopped by the user.
class LookupCancelled implements Exception {
  @override
  String toString() => 'Stopped';
}

/// One candidate from MusicBrainz.
class MbMatch {
  final String recordingId, releaseId, artistId;
  final String title, artist, album, albumArtist, date, genre;
  final int track, trackTotal, disc, score;
  final Duration? length;
  final String releaseType, country, releaseGroupId;

  /// A live recording / release, and whether the file asked for one.
  final bool live, liveWanted;

  /// The cover found for it (large, and a small one for lists); '' if none.
  String coverUrl = '', coverThumb = '';

  /// Official, Bootleg, Promotion ...
  String status = '';

  MbMatch({
    required this.recordingId,
    required this.releaseId,
    required this.artistId,
    required this.title,
    required this.artist,
    required this.album,
    required this.albumArtist,
    required this.date,
    required this.genre,
    required this.track,
    required this.trackTotal,
    required this.disc,
    required this.score,
    required this.length,
    required this.releaseType,
    required this.country,
    this.releaseGroupId = '',
    this.live = false,
    this.liveWanted = false,
  });

  String get year => date.length >= 4 ? date.substring(0, 4) : '';

  TagValues get tags => TagValues(
    title: title,
    artist: artist,
    album: album,
    albumArtist: albumArtist,
    genre: genre,
    year: year,
    track: track > 0 ? '$track' : '',
    trackTotal: trackTotal > 0 ? '$trackTotal' : '',
    disc: disc > 0 ? '$disc' : '',
    mbTrackId: recordingId,
    mbReleaseId: releaseId,
    mbArtistId: artistId,
  );
}

/// MusicBrainz (an open music database) and the Cover Art Archive. One
/// request a second, as MusicBrainz asks.
class MusicBrainz {
  static const _api = 'https://musicbrainz.org/ws/2';
  static DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  /// One request at a time, a little over a second apart, however many
  /// lookups run at once (they queue for their turn); when MusicBrainz says
  /// it's busy (503 / 429, common on shared mobile connections), waits
  /// longer each time and slows down for a while. [cancelled] stops a
  /// lookup while it waits (throws [LookupCancelled]).
  static Future<Object?> _get(String path, Map<String, String> query, {bool Function()? cancelled}) async {
    final uri = Uri.parse('$_api/$path').replace(queryParameters: {...query, 'fmt': 'json'});
    const backoff = [3, 8, 20, 45];
    for (var attempt = 0; ; attempt++) {
      await _turn(cancelled);
      try {
        final r = await Http.json(uri);
        _gap = max(1100, _gap - 50);
        return r;
      } on HttpFailure catch (e) {
        final busy = e.status == 503 || e.status == 429 || e.status == 502;
        if (!busy || attempt >= backoff.length) {
          if (busy) throw HttpFailure('MusicBrainz is busy right now. Try again in a minute.', e.status);
          rethrow;
        }
        _gap = min(3000, _gap + 500);
        final until = DateTime.now().add(Duration(seconds: backoff[attempt]));
        if (until.isAfter(_last)) _last = until;
      }
    }
  }

  static Future<void> _queue = Future.value();

  /// Waits for this request's slot: [_gap] after the last one started.
  static Future<void> _turn(bool Function()? cancelled) async {
    final before = _queue;
    final mine = Completer<void>();
    _queue = mine.future;
    try {
      await before;
      while (true) {
        if (cancelled?.call() ?? false) throw LookupCancelled();
        final wait = _last.add(Duration(milliseconds: _gap)).difference(DateTime.now());
        if (wait <= Duration.zero) break;
        // In small steps, so Stop is quick.
        await Future<void>.delayed(
          wait < const Duration(milliseconds: 300) ? wait : const Duration(milliseconds: 300),
        );
      }
      _last = DateTime.now();
    } finally {
      mine.complete();
    }
  }

  static int _gap = 1100; // ms between requests (MusicBrainz asks for 1 a second)

  static String _q(String s) => s.replaceAll(RegExp(r'[\\+\-!(){}\[\]^"~*?:/]|&&|\|\|'), ' ').trim();

  static String _credit(Object? credits) {
    if (credits is! List) return '';
    return credits.map((c) => '${(c as Map)['name'] ?? ''}${c['joinphrase'] ?? ''}').join().trim();
  }

  /// Candidates for a song, best first. Albums beat compilations and singles.
  static Future<List<MbMatch>> search({
    required String title,
    String artist = '',
    String album = '',
    Duration? length,
    bool Function()? cancelled,
  }) async {
    final t = _q(title);
    if (t.isEmpty) return const [];
    // Files often say "Artist A; Artist B" or "X feat. Y": try each name.
    final artists = [
      for (final x in artist.split(
        RegExp(r'\s*(?:;|,|&|/|\bfeat\.?|\bft\.?|\bfeaturing\b|\band\b|\bwith\b)\s*', caseSensitive: false),
      ))
        if (_q(x).isNotEmpty) _q(x),
    ];
    final whole = _q(artist);
    final al = _q(album);
    String loose(String s) => s.split(RegExp(r'\s+')).where((w) => w.length > 1).join(' ');
    // Strict first, then looser until something matches.
    final attempts = <String>{
      if (al.isNotEmpty && whole.isNotEmpty) 'recording:"$t" AND artist:"$whole" AND release:"$al"',
      if (whole.isNotEmpty) 'recording:"$t" AND artist:"$whole"',
      for (final a in artists.take(3)) 'recording:"$t" AND artist:"$a"',
      if (artists.isNotEmpty) 'recording:(${loose(t)}) AND artist:(${loose(artists.first)})',
      if (artists.isNotEmpty)
        'recording:(${loose(t)}) AND (${artists.map((a) => 'artist:(${loose(a)})').join(' OR ')})',
      'recording:"$t"',
    }.toList();
    var recs = const <Object?>[];
    for (final q in attempts.take(4)) {
      final data = await _get('recording', {'query': q, 'limit': '15'}, cancelled: cancelled);
      recs = (data as Map?)?['recordings'] as List? ?? const [];
      if (recs.isNotEmpty) break;
    }
    String norm(String x) => x
        .toLowerCase()
        .replaceAll(RegExp(r'[\(\[][^\)\]]*[\)\]]'), ' ')
        .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
        .trim();
    final liveRe = RegExp(r'\blive\b|unplugged|in concert|\bsessions?\b', caseSensitive: false);
    final liveWanted = liveRe.hasMatch('$title $album');
    // Other cuts of a song: wrong unless the file says so.
    final variantRe = RegExp(
      r'\b(remix|mix|instrumental|karaoke|acoustic|demo|edit|version|cover|tribute|8-bit|lullaby)\b',
      caseSensitive: false,
    );
    final variantsWanted = variantRe.allMatches(title.toLowerCase()).map((m) => m[0]!).toSet();
    final out = <MbMatch>[];
    final firstYear = <String, String>{};
    for (final r in recs.cast<Map<Object?, Object?>>()) {
      final score = (r['score'] as num?)?.toInt() ?? 0;
      final len = (r['length'] as num?)?.toInt();
      final tags = [...(r['tags'] as List? ?? const []).cast<Map<Object?, Object?>>()]
        ..sort((a, b) => ((b['count'] as num?) ?? 0).compareTo((a['count'] as num?) ?? 0));
      final genre = tags.isEmpty ? '' : _titleCase('${tags.first['name']}');
      final artistCredit = r['artist-credit'] as List?;
      final artistId = artistCredit != null && artistCredit.isNotEmpty
          ? '${((artistCredit.first as Map)['artist'] as Map?)?['id'] ?? ''}'
          : '';
      final recTitle = '${r['title'] ?? title}';
      final recLive = liveRe.hasMatch('${r['disambiguation'] ?? ''} $recTitle');
      final first = '${r['first-release-date'] ?? ''}';
      if (first.length >= 4) firstYear['${r['id']}'] = first.substring(0, 4);
      for (final rel in (r['releases'] as List? ?? const []).cast<Map<Object?, Object?>>().take(8)) {
        final media = (rel['media'] as List? ?? const []).cast<Map<Object?, Object?>>();
        final m = media.isEmpty ? const <Object?, Object?>{} : media.first;
        final tr = (m['track'] as List? ?? const []).cast<Map<Object?, Object?>>();
        final rg = rel['release-group'] as Map?;
        final type =
            '${rg?['primary-type'] ?? ''}${rg?['secondary-types'] is List && (rg!['secondary-types'] as List).isNotEmpty ? ' (${(rg['secondary-types'] as List).join(', ')})' : ''}';
        final relTitle = '${rel['title'] ?? ''}';
        out.add(
          MbMatch(
            recordingId: '${r['id']}',
            releaseId: '${rel['id']}',
            artistId: artistId,
            title: recTitle,
            artist: _credit(artistCredit),
            album: relTitle,
            albumArtist: rel['artist-credit'] != null ? _credit(rel['artist-credit']) : _credit(artistCredit),
            date: '${rel['date'] ?? r['first-release-date'] ?? ''}',
            genre: genre,
            track: tr.isEmpty ? 0 : int.tryParse('${tr.first['number']}') ?? 0,
            trackTotal: (m['track-count'] as num?)?.toInt() ?? 0,
            disc: (m['position'] as num?)?.toInt() ?? 1,
            score: score,
            length: len == null ? null : Duration(milliseconds: len),
            releaseType: type,
            country: '${rel['country'] ?? ''}',
            releaseGroupId: '${rg?['id'] ?? ''}',
            live: recLive || type.contains('Live') || liveRe.hasMatch(relTitle),
            liveWanted: liveWanted,
          )..status = '${rel['status'] ?? ''}',
        );
      }
    }
    final wantAlbum = norm(album);
    final wantTitle = norm(title);
    int rank(MbMatch m) {
      var v = m.score * 10;
      final type = m.releaseType;
      if (type == 'Album') v += 60;
      if (type.contains('Compilation')) v -= 150;
      if (type.contains('Soundtrack')) v -= 30;
      if (type.contains('Remix') || type.contains('DJ-mix') || type.contains('Demo')) v -= 150;
      if (m.live && !liveWanted) v -= 400;
      if (m.status == 'Official') v += 30;
      if (m.status == 'Bootleg' || m.status == 'Promotion') v -= 200;
      final got = norm(m.album);
      final albumMatches = wantAlbum.isNotEmpty && (got == wantAlbum || got.contains(wantAlbum));
      // A single / EP only when the file says it's from one.
      if ((type.startsWith('Single') || type.startsWith('EP')) && !albumMatches) v -= 90;
      if (wantAlbum.isNotEmpty) {
        if (got == wantAlbum) {
          v += 120;
        } else if (albumMatches || wantAlbum.contains(got)) {
          v += 60;
        } else if (wantAlbum.split(' ').where((w) => w.length > 2).any(got.split(' ').contains)) {
          v += 25;
        }
      }
      if (norm(m.title) == wantTitle) v += 40;
      final extra = variantRe.allMatches(m.title.toLowerCase()).map((x) => x[0]!).toSet()
        ..removeAll(variantsWanted);
      if (extra.isNotEmpty) v -= 300;
      if (length != null && m.length != null) {
        final off = (m.length! - length).inSeconds.abs();
        v += off <= 3 ? 80 : (off <= 10 ? 30 : -120);
      }
      // The song's first release (the original album, not a later reissue).
      if (m.year.isNotEmpty && m.year == firstYear[m.recordingId]) v += 25;
      if (m.year.isNotEmpty) v += 5;
      if (m.coverUrl.isNotEmpty) v += 150;
      return v;
    }

    List<MbMatch> best() {
      out.sort((a, b) => rank(b).compareTo(rank(a)));
      // One entry per release.
      final seen = <String>{};
      return out.where((m) => seen.add(m.releaseId)).toList();
    }

    var list = best();
    // Live takes only when nothing else fits.
    if (!liveWanted && list.any((m) => !m.live)) list = list.where((m) => !m.live).toList();
    // A match without a cover shouldn't win: look up covers for the few
    // that a cover could still put first (all at once, a few seconds at most).
    final top = list.isEmpty ? 0 : rank(list.first);
    await Future.wait(
      list
          .take(4)
          .where((m) => top - rank(m) < 150)
          .map((m) => findCover(m).timeout(const Duration(seconds: 8), onTimeout: () {})),
    );
    out
      ..clear()
      ..addAll(list);
    return best().take(12).toList();
  }

  static final _covers = <String, Future<(String, String)?>>{};

  /// Fills [m]'s cover: its release's front, else any release in its group
  /// (the same album, another pressing), else Deezer's album search.
  static Future<void> findCover(MbMatch m) async {
    if (m.coverUrl.isNotEmpty) return;
    final found =
        await _caa('release', m.releaseId) ??
        await _caa('release-group', m.releaseGroupId) ??
        await deezerCover(m.albumArtist.isNotEmpty ? m.albumArtist : m.artist, m.album);
    if (found != null) {
      m.coverUrl = found.$1;
      m.coverThumb = found.$2;
    }
  }

  static Future<(String, String)?> _caa(String kind, String id) {
    if (id.isEmpty) return Future.value();
    return _covers.putIfAbsent('$kind/$id', () async {
      try {
        final d = await Http.json(Uri.parse('https://coverartarchive.org/$kind/$id')) as Map?;
        final images = (d?['images'] as List? ?? const []).cast<Map<Object?, Object?>>();
        final front = images.where((i) => i['front'] == true).firstOrNull ?? images.firstOrNull;
        if (front == null) return null;
        final th = front['thumbnails'] as Map? ?? const {};
        String pick(List<String> keys) => keys
            .map((k) => '${th[k] ?? ''}')
            .firstWhere((u) => u.isNotEmpty, orElse: () => '${front['image']}');
        return (pick(['500', 'large', '1200']), pick(['250', 'small', '500']));
      } on Object {
        return null;
      }
    });
  }

  /// An album cover from Deezer's open search (no key), when the album's
  /// name (and artist) match.
  static Future<(String, String)?> deezerCover(String artist, String album) {
    if (album.trim().isEmpty) return Future.value();
    String n(String x) => x
        .toLowerCase()
        .replaceAll(RegExp(r'[\(\[][^\)\]]*[\)\]]'), ' ')
        .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
        .trim();
    return _covers.putIfAbsent('deezer/${n(artist)}/${n(album)}', () async {
      try {
        final q = [if (artist.isNotEmpty) 'artist:"${_q(artist)}"', 'album:"${_q(album)}"'].join(' ');
        final d =
            await Http.json(Uri.https('api.deezer.com', '/search/album', {'q': q, 'limit': '10'})) as Map?;
        final hits = (d?['data'] as List? ?? const []).cast<Map<Object?, Object?>>();
        for (final h in hits) {
          final t = n('${h['title'] ?? ''}');
          final a = n('${(h['artist'] as Map?)?['name'] ?? ''}');
          final albumOk = t == n(album) || t.startsWith(n(album)) || n(album).startsWith(t);
          final artistOk = artist.isEmpty || a == n(artist) || a.contains(n(artist)) || n(artist).contains(a);
          final big = '${h['cover_xl'] ?? h['cover_big'] ?? ''}';
          if (albumOk && artistOk && big.isNotEmpty) return (big, '${h['cover_medium'] ?? big}');
        }
      } on Object catch (e) {
        CrashLog.note('Deezer cover lookup failed: $e');
      }
      return null;
    });
  }

  /// Genre for a release (its own, else its release group's), when the
  /// recording search had none.
  static Future<String> releaseGenre(String releaseId) async {
    try {
      final d = await _get('release/$releaseId', {'inc': 'genres release-groups'}) as Map?;
      List<Object?>? g = d?['genres'] as List?;
      if (g == null || g.isEmpty) g = (d?['release-group'] as Map?)?['genres'] as List<Object?>?;
      if (g == null || g.isEmpty) return '';
      final list = [...g.cast<Map<Object?, Object?>>()]
        ..sort((a, b) => ((b['count'] as num?) ?? 0).compareTo((a['count'] as num?) ?? 0));
      return _titleCase('${list.first['name']}');
    } on Object catch (e) {
      CrashLog.note('genre lookup failed: $e');
      return '';
    }
  }

  /// The match's cover saved to [dir] (see [findCover]), or null.
  static Future<String?> cover(MbMatch m, String dir) async {
    if (m.releaseId.isEmpty) return null;
    final file = File('$dir/cover_${m.releaseId}.jpg');
    if (file.existsSync() && file.lengthSync() > 1024) return file.path;
    await findCover(m);
    if (m.coverUrl.isEmpty) return null;
    try {
      final b = await Http.bytes(Uri.parse(m.coverUrl));
      // A real picture (JPEG / PNG), not an error page.
      final jpeg = b.length > 2 && b[0] == 0xFF && b[1] == 0xD8;
      final png = b.length > 4 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47;
      if (b.length < 1024 || !(jpeg || png)) return null;
      await file.parent.create(recursive: true);
      await file.writeAsBytes(b);
      return file.path;
    } on Object {
      return null;
    }
  }

  static String _titleCase(String s) =>
      s.split(' ').map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1)).join(' ');
}

/// Writes tags (and a cover) into a file, then has Android re-read it.
Future<void> applyTags(String path, TagValues tags, {String? cover}) async {
  await Native.writeTags(path, tags.toMap(), cover: cover);
}

/// Where covers are cached before going into files.
Future<String> coverCacheDir() async => '${await Native.filesDir() ?? Directory.systemTemp.path}/covers';
