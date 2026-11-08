import 'dart:async';
import 'dart:io';

import 'crash_log.dart';
import 'http.dart';
import 'models.dart';
import 'native.dart';

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
      album: s('album'),
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
    album: s.album == 'Unknown album' ? '' : s.album,
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
    if (RegExp(r'^(music|download|downloads|roadie|0|emulated)$', caseSensitive: false).hasMatch(album)) {
      album = '';
    }
  }
  return TagValues(title: title, artist: artist, album: album, track: track);
}

/// One candidate from MusicBrainz.
class MbMatch {
  final String recordingId, releaseId, artistId;
  final String title, artist, album, albumArtist, date, genre;
  final int track, trackTotal, disc, score;
  final Duration? length;
  final String releaseType, country;

  const MbMatch({
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

  static Future<Object?> _get(String path, Map<String, String> query) async {
    final wait = _last.add(const Duration(milliseconds: 1100)).difference(DateTime.now());
    if (!wait.isNegative) await Future<void>.delayed(wait);
    _last = DateTime.now();
    return Http.json(Uri.parse('$_api/$path').replace(queryParameters: {...query, 'fmt': 'json'}));
  }

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
  }) async {
    final t = _q(title);
    if (t.isEmpty) return const [];
    final q = [
      'recording:"$t"',
      if (_q(artist).isNotEmpty) 'artist:"${_q(artist)}"',
      if (_q(album).isNotEmpty) 'release:"${_q(album)}"',
    ].join(' AND ');
    final data = await _get('recording', {'query': q, 'limit': '15'});
    final recs = (data as Map?)?['recordings'] as List? ?? const [];
    if (recs.isEmpty && album.isNotEmpty) {
      // The album name is often what's wrong.
      return search(title: title, artist: artist, length: length);
    }
    final out = <MbMatch>[];
    for (final r in recs.cast<Map<Object?, Object?>>()) {
      final score = (r['score'] as num?)?.toInt() ?? 0;
      final len = (r['length'] as num?)?.toInt();
      final tags = (r['tags'] as List? ?? const []).cast<Map<Object?, Object?>>()
        ..sort((a, b) => ((b['count'] as num?) ?? 0).compareTo((a['count'] as num?) ?? 0));
      final genre = tags.isEmpty ? '' : _titleCase('${tags.first['name']}');
      final artistCredit = r['artist-credit'] as List?;
      final artistId = artistCredit != null && artistCredit.isNotEmpty
          ? '${((artistCredit.first as Map)['artist'] as Map?)?['id'] ?? ''}'
          : '';
      for (final rel in (r['releases'] as List? ?? const []).cast<Map<Object?, Object?>>().take(4)) {
        final media = (rel['media'] as List? ?? const []).cast<Map<Object?, Object?>>();
        final m = media.isEmpty ? const <Object?, Object?>{} : media.first;
        final tr = (m['track'] as List? ?? const []).cast<Map<Object?, Object?>>();
        final rg = rel['release-group'] as Map?;
        out.add(
          MbMatch(
            recordingId: '${r['id']}',
            releaseId: '${rel['id']}',
            artistId: artistId,
            title: '${r['title'] ?? title}',
            artist: _credit(artistCredit),
            album: '${rel['title'] ?? ''}',
            albumArtist: rel['artist-credit'] != null ? _credit(rel['artist-credit']) : _credit(artistCredit),
            date: '${rel['date'] ?? r['first-release-date'] ?? ''}',
            genre: genre,
            track: tr.isEmpty ? 0 : int.tryParse('${tr.first['number']}') ?? 0,
            trackTotal: (m['track-count'] as num?)?.toInt() ?? 0,
            disc: (m['position'] as num?)?.toInt() ?? 1,
            score: score,
            length: len == null ? null : Duration(milliseconds: len),
            releaseType:
                '${rg?['primary-type'] ?? ''}${rg?['secondary-types'] is List && (rg!['secondary-types'] as List).isNotEmpty ? ' (${(rg['secondary-types'] as List).join(', ')})' : ''}',
            country: '${rel['country'] ?? ''}',
          ),
        );
      }
    }
    int rank(MbMatch m) {
      var v = m.score * 10;
      if (m.releaseType == 'Album') v += 60;
      if (m.releaseType.contains('Compilation')) v -= 80;
      if (m.releaseType.contains('Live')) v -= 40;
      if (length != null && m.length != null) {
        final off = (m.length! - length).inSeconds.abs();
        v += off <= 3 ? 80 : (off <= 10 ? 30 : -120);
      }
      if (m.year.isNotEmpty) v += 5;
      return v;
    }

    out.sort((a, b) => rank(b).compareTo(rank(a)));
    // One entry per release.
    final seen = <String>{};
    return out.where((m) => seen.add(m.releaseId)).take(12).toList();
  }

  /// Genre for a release (its own, else its release group's), when the
  /// recording search had none.
  static Future<String> releaseGenre(String releaseId) async {
    try {
      final d = await _get('release/$releaseId', {'inc': 'genres release-groups'}) as Map?;
      List<Object?>? g = d?['genres'] as List?;
      if (g == null || g.isEmpty) g = (d?['release-group'] as Map?)?['genres'] as List<Object?>?;
      if (g == null || g.isEmpty) return '';
      final list = g.cast<Map<Object?, Object?>>()
        ..sort((a, b) => ((b['count'] as num?) ?? 0).compareTo((a['count'] as num?) ?? 0));
      return _titleCase('${list.first['name']}');
    } on Object catch (e) {
      CrashLog.note('genre lookup failed: $e');
      return '';
    }
  }

  /// The release's front cover (500 px) saved to [dir], or null.
  static Future<String?> cover(String releaseId, String dir) async {
    if (releaseId.isEmpty) return null;
    final file = File('$dir/cover_$releaseId.jpg');
    if (file.existsSync()) return file.path;
    try {
      final b = await Http.bytes(Uri.parse('https://coverartarchive.org/release/$releaseId/front-500'));
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
