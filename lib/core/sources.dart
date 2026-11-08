import 'dart:convert';
import 'dart:math';

import 'http.dart';

/// Something to download from: an album / collection, or a single track.
class RemoteItem {
  final String source, id, title, artist, year;
  final String? cover;
  final bool single;
  final Object? data; // source-specific (e.g. the track for a single)

  const RemoteItem({
    required this.source,
    required this.id,
    required this.title,
    this.artist = '',
    this.year = '',
    this.cover,
    this.single = false,
    this.data,
  });
}

class RemoteTrack {
  final String title, artist, album, albumArtist, year, genre;
  final int track;
  final Uri url;
  final String ext; // without the dot
  final Duration? length;
  final String? cover;
  final String quality; // e.g. "FLAC", "MP3 320"

  /// A lighter stream to preview before downloading (else [url]).
  final Uri? preview;

  const RemoteTrack({
    required this.title,
    required this.url,
    required this.ext,
    this.artist = '',
    this.album = '',
    this.albumArtist = '',
    this.year = '',
    this.genre = '',
    this.track = 0,
    this.length,
    this.cover,
    this.quality = '',
    this.preview,
  });

  Uri get previewUrl => preview ?? url;
}

abstract class MusicSource {
  String get id;
  String get name;
  String get blurb;
  bool get needsKey => false;
  bool get searchable => true;
  Future<List<RemoteItem>> search(String query);
  Future<List<RemoteTrack>> tracks(RemoteItem item);
}

/// Every built-in source. [jamendoKey] and [lossless] come from Settings.
List<MusicSource> allSources({required String jamendoKey, required bool lossless}) => [
  InternetArchive(lossless: lossless),
  Jamendo(jamendoKey, lossless: lossless),
  CcMixter(lossless: lossless),
  DirectLink(),
];

Duration? _seconds(Object? v) {
  if (v == null) return null;
  final s = '$v';
  if (s.contains(':')) {
    final p = s.split(':').map((x) => double.tryParse(x) ?? 0).toList();
    var t = 0.0;
    for (final x in p) {
      t = t * 60 + x;
    }
    return Duration(milliseconds: (t * 1000).round());
  }
  final d = double.tryParse(s);
  return d == null ? null : Duration(milliseconds: (d * 1000).round());
}

String _str(Object? v) => v is List ? (v.isEmpty ? '' : '${v.first}') : (v ?? '').toString();

/// archive.org: live concerts, old recordings, netlabels, public domain.
class InternetArchive extends MusicSource {
  final bool lossless;
  InternetArchive({this.lossless = true});

  @override
  String get id => 'archive';
  @override
  String get name => 'Internet Archive';
  @override
  String get blurb => 'Live recordings, netlabels, public domain and free releases';

  /// Collections that are talk, not music (radio shows, podcasts, audio books).
  static const _notMusic =
      'radioprograms OR radiostationarchives OR radioshowarchive OR podcasts OR podcasts_mirror OR '
      'audio_podcast OR librivoxaudio OR oldtimeradio OR audio_religion OR audio_news OR audio_tech OR '
      'audio_bookspoetry OR radio OR tvarchive OR spokenword';

  /// Collections that are mostly real releases and concerts.
  static const _music = {
    'etree',
    'audio_music',
    '78rpm',
    'netlabels',
    'album_recordings',
    'hifidelity',
    'georgeblood',
    'unlockedrecordings',
    'opensource_audio',
  };

  /// Best first: how much of [query] is in the title and artist, then
  /// popularity, with a nudge for real-music collections.
  static void rank(List<Map<Object?, Object?>> docs, String query) {
    final terms = RegExp(
      r'\w+',
      unicode: true,
    ).allMatches(query.toLowerCase()).map((m) => m.group(0)!).where((t) => t.length > 1).toList();
    String all(Object? v) => v is List ? v.join(' ') : (v ?? '').toString();
    double score(Map<Object?, Object?> x) {
      final hay = '${all(x['title'])} ${all(x['creator'])}'.toLowerCase();
      final hit = terms.isEmpty ? 1 : terms.where(hay.contains).length / terms.length;
      final cols = (x['collection'] is List ? x['collection']! as List : [x['collection']]).map((c) => '$c');
      final dl = (x['downloads'] as num?)?.toDouble() ?? 0;
      return hit * 100 + log(1 + dl) * 3 + (cols.any(_music.contains) ? 8 : 0);
    }

    docs.sort((a, b) => score(b).compareTo(score(a)));
  }

  @override
  Future<List<RemoteItem>> search(String query) async {
    // Archive matches words anywhere (descriptions, reviews...). Ask for
    // music only, then rank by how much of the search is in the title and
    // artist, with popularity as the tie-break.
    final uri = Uri.https('archive.org', '/advancedsearch.php', {
      'q': '($query) AND mediatype:(audio) AND -collection:($_notMusic)',
      'fl[]': ['identifier', 'title', 'creator', 'year', 'downloads', 'collection'],
      'rows': '100',
      'output': 'json',
    });
    final d = await Http.json(uri) as Map;
    final docs = [...((d['response'] as Map?)?['docs'] as List? ?? const []).cast<Map<Object?, Object?>>()];
    rank(docs, query);
    String all(Object? v) => v is List ? v.join(' ') : (v ?? '').toString();
    return [
      for (final x in docs.take(50))
        RemoteItem(
          source: id,
          id: '${x['identifier']}',
          title: _str(x['title']),
          artist: all(x['creator']).isEmpty
              ? ''
              : (x['creator'] is List ? (x['creator']! as List).join(', ') : _str(x['creator'])),
          year: _str(x['year']),
          cover: 'https://archive.org/services/img/${x['identifier']}',
        ),
    ];
  }

  static const _rank = {
    'Flac': 10,
    '24bit Flac': 9,
    'VBR MP3': 6,
    'MP3': 5,
    '128Kbps MP3': 4,
    'Ogg Vorbis': 3,
    '64Kbps MP3': 1,
  };

  @override
  Future<List<RemoteTrack>> tracks(RemoteItem item) async {
    final d = await Http.json(Uri.https('archive.org', '/metadata/${item.id}')) as Map;
    final meta = (d['metadata'] as Map?) ?? const {};
    final files = (d['files'] as List? ?? const []).cast<Map<Object?, Object?>>();
    final best = <String, Map<Object?, Object?>>{};
    final mp3 = <String, String>{};
    int rank(Map<Object?, Object?> f) {
      final r = _rank['${f['format']}'] ?? 0;
      return lossless ? r : (r >= 9 ? 2 : r);
    }

    for (final f in files) {
      if (rank(f) == 0) continue;
      final name = '${f['name']}';
      final stem = name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;
      final cur = best[stem];
      if (cur == null || rank(f) > rank(cur)) best[stem] = f;
      if ('${f['format']}'.contains('MP3') && (_rank['${f['format']}'] ?? 0) >= 4) mp3[stem] = name;
    }
    final album = _str(meta['title']);
    final artist = _str(meta['creator']);
    final year = _str(meta['date']).length >= 4 ? _str(meta['date']).substring(0, 4) : item.year;
    final out = <RemoteTrack>[];
    for (final f in best.values) {
      final name = '${f['name']}';
      final ext = name.contains('.') ? name.substring(name.lastIndexOf('.') + 1).toLowerCase() : 'mp3';
      final stem = name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;
      out.add(
        RemoteTrack(
          title: _str(f['title']).isNotEmpty
              ? _str(f['title'])
              : stem.split('/').last.replaceAll('_', ' ').trim(),
          artist: _str(f['artist']).isNotEmpty
              ? _str(f['artist'])
              : (_str(f['creator']).isNotEmpty ? _str(f['creator']) : artist),
          album: _str(f['album']).isNotEmpty ? _str(f['album']) : album,
          albumArtist: artist,
          year: year,
          track: int.tryParse(_str(f['track']).split('/').first) ?? 0,
          url: Uri.https('archive.org', '/download/${item.id}/$name'),
          ext: ext,
          length: _seconds(f['length']),
          cover: item.cover,
          quality: '${f['format']}',
          preview: mp3[stem] == null ? null : Uri.https('archive.org', '/download/${item.id}/${mp3[stem]}'),
        ),
      );
    }
    out.sort((a, b) => a.track != b.track ? a.track.compareTo(b.track) : a.title.compareTo(b.title));
    return out;
  }
}

/// jamendo.com: independent artists who allow free downloads. Needs a free
/// API key from developer.jamendo.com (Settings > Get music).
class Jamendo extends MusicSource {
  final String key;
  final bool lossless;
  Jamendo(this.key, {this.lossless = true});

  @override
  String get id => 'jamendo';
  @override
  String get name => 'Jamendo';
  @override
  String get blurb => 'Independent artists, free to download';
  @override
  bool get needsKey => key.isEmpty;

  Uri _api(String path, Map<String, String> q) =>
      Uri.https('api.jamendo.com', '/v3.0/$path/', {'client_id': key, 'format': 'json', ...q});

  @override
  Future<List<RemoteItem>> search(String query) async {
    final albums =
        await Http.json(_api('albums', {'namesearch': query, 'limit': '30', 'imagesize': '300'})) as Map;
    final tracks =
        await Http.json(
              _api('tracks', {'search': query, 'limit': '20', 'imagesize': '300', 'audiodlformat': _fmt}),
            )
            as Map;
    return [
      for (final a in (albums['results'] as List? ?? const []).cast<Map<Object?, Object?>>())
        RemoteItem(
          source: id,
          id: '${a['id']}',
          title: '${a['name']}',
          artist: '${a['artist_name']}',
          year: '${a['releasedate'] ?? ''}'.split('-').first,
          cover: a['image'] as String?,
        ),
      for (final t in (tracks['results'] as List? ?? const []).cast<Map<Object?, Object?>>())
        if (t['audiodownload_allowed'] != false)
          RemoteItem(
            source: id,
            id: 't${t['id']}',
            title: '${t['name']}',
            artist: '${t['artist_name']}',
            cover: t['image'] as String?,
            single: true,
            data: _track(t),
          ),
    ];
  }

  String get _fmt => lossless ? 'flac' : 'mp32';

  RemoteTrack _track(Map<Object?, Object?> t) => RemoteTrack(
    title: '${t['name']}',
    artist: '${t['artist_name']}',
    album: '${t['album_name'] ?? ''}',
    albumArtist: '${t['artist_name']}',
    year: '${t['releasedate'] ?? ''}'.split('-').first,
    track: int.tryParse('${t['position']}') ?? 0,
    url: Uri.parse('${t['audiodownload']}'),
    ext: lossless ? 'flac' : 'mp3',
    length: _seconds(t['duration']),
    cover: t['image'] as String? ?? t['album_image'] as String?,
    quality: lossless ? 'FLAC' : 'MP3 VBR',
    preview: t['audio'] is String && (t['audio'] as String).isNotEmpty
        ? Uri.parse(t['audio']! as String)
        : null,
  );

  @override
  Future<List<RemoteTrack>> tracks(RemoteItem item) async {
    if (item.single) return [item.data! as RemoteTrack];
    final d =
        await Http.json(
              _api('tracks', {
                'album_id': item.id,
                'limit': '200',
                'order': 'position',
                'imagesize': '500',
                'audiodlformat': _fmt,
              }),
            )
            as Map;
    return [
      for (final t in (d['results'] as List? ?? const []).cast<Map<Object?, Object?>>())
        if (t['audiodownload_allowed'] != false) _track(t),
    ];
  }
}

/// ccmixter.org: Creative Commons remixes, instrumentals and a cappellas.
class CcMixter extends MusicSource {
  final bool lossless;
  CcMixter({this.lossless = true});

  @override
  String get id => 'ccmixter';
  @override
  String get name => 'ccMixter';
  @override
  String get blurb => 'Creative Commons remixes and instrumentals';

  @override
  Future<List<RemoteItem>> search(String query) async {
    final d = await Http.json(
      Uri.https('ccmixter.org', '/api/query', {'f': 'json', 'search': query, 'limit': '40', 'sort': 'rank'}),
    );
    final out = <RemoteItem>[];
    for (final u in (d as List? ?? const []).cast<Map<Object?, Object?>>()) {
      final files = (u['files'] as List? ?? const []).cast<Map<Object?, Object?>>();
      String mime(Map<Object?, Object?> f) => '${(f['file_format_info'] as Map?)?['mime_type'] ?? ''}';
      final audio = files.where((f) => mime(f).startsWith('audio')).toList();
      final f =
          (lossless ? audio.where((f) => mime(f).contains('flac')).firstOrNull : null) ?? audio.firstOrNull;
      if (f == null) continue;
      final mp3 = audio.where((f) => mime(f).contains('mpeg')).firstOrNull;
      final info = f['file_format_info'] as Map?;
      final ext = '${info?['default-ext'] ?? 'mp3'}';
      final artist = '${u['user_real_name'] ?? u['user_name'] ?? ''}';
      final date = '${u['upload_date'] ?? ''}';
      out.add(
        RemoteItem(
          source: id,
          id: '${u['upload_id']}',
          title: '${u['upload_name']}',
          artist: artist,
          year: date.length >= 4 ? date.substring(0, 4) : '',
          single: true,
          data: RemoteTrack(
            title: '${u['upload_name']}',
            artist: artist,
            albumArtist: artist,
            album: 'ccMixter',
            year: date.length >= 4 ? date.substring(0, 4) : '',
            genre: 'Remix',
            url: Uri.parse('${f['download_url']}'),
            ext: ext,
            quality: ext.toUpperCase(),
            preview: mp3 == null ? null : Uri.parse('${mp3['download_url']}'),
          ),
        ),
      );
    }
    return out;
  }

  @override
  Future<List<RemoteTrack>> tracks(RemoteItem item) async => [item.data! as RemoteTrack];
}

/// Any direct link to an audio file. Tags come from the name, then MusicBrainz.
class DirectLink extends MusicSource {
  @override
  String get id => 'link';
  @override
  String get name => 'Link';
  @override
  String get blurb => 'Paste a link to a music file';
  @override
  bool get searchable => false;

  static const audioExts = {'mp3', 'flac', 'm4a', 'aac', 'ogg', 'opus', 'wav'};

  @override
  Future<List<RemoteItem>> search(String query) async {
    final uri = Uri.tryParse(query.trim());
    if (uri == null || !uri.hasScheme || !uri.scheme.startsWith('http')) return const [];
    final name = Uri.decodeComponent(uri.pathSegments.isEmpty ? 'download' : uri.pathSegments.last);
    final dot = name.lastIndexOf('.');
    final ext = dot > 0 ? name.substring(dot + 1).toLowerCase() : 'mp3';
    final title = dot > 0 ? name.substring(0, dot) : name;
    return [
      RemoteItem(
        source: id,
        id: uri.toString(),
        title: title,
        artist: uri.host,
        single: true,
        data: RemoteTrack(
          title: title,
          url: uri,
          ext: audioExts.contains(ext) ? ext : 'mp3',
          quality: ext.toUpperCase(),
        ),
      ),
    ];
  }

  @override
  Future<List<RemoteTrack>> tracks(RemoteItem item) async => [item.data! as RemoteTrack];
}

/// A website the user added. With a [search] address ("…{q}…") a search
/// opens its results in the browser; otherwise the browser opens [home].
class CustomSite {
  final String id, name, home, search;
  const CustomSite({required this.id, required this.name, required this.home, this.search = ''});

  Uri searchUri(String q) => Uri.parse(search.replaceAll('{q}', Uri.encodeQueryComponent(q)));
  Uri get homeUri => Uri.parse(home);

  Map<String, String> toJson() => {'id': id, 'name': name, 'home': home, 'search': search};
  factory CustomSite.fromJson(Map<String, Object?> m) => CustomSite(
    id: '${m['id']}',
    name: '${m['name']}',
    home: '${m['home']}',
    search: '${m['search'] ?? ''}',
  );

  static List<CustomSite> decode(String? s) {
    if (s == null || s.isEmpty) return const [];
    try {
      return [
        for (final m in jsonDecode(s) as List<Object?>)
          CustomSite.fromJson((m! as Map).cast<String, Object?>()),
      ];
    } on Object {
      return const [];
    }
  }

  static String encode(List<CustomSite> list) => jsonEncode([for (final c in list) c.toJson()]);

  /// "example.com/search?q=chopin" → the address with {q} where "chopin" was.
  static String templateFrom(String url, String sample) {
    if (sample.isEmpty) return url;
    for (final enc in [Uri.encodeQueryComponent(sample), Uri.encodeComponent(sample), sample]) {
      if (url.contains(enc)) return url.replaceFirst(enc, '{q}');
    }
    return url;
  }
}

/// Music files found on a web page (browser), as a downloadable "album".
class PageSource extends MusicSource {
  final String siteName;
  PageSource(this.siteName);

  @override
  String get id => 'page';
  @override
  String get name => siteName;
  @override
  String get blurb => 'Music files on a web page';
  @override
  bool get searchable => false;
  @override
  Future<List<RemoteItem>> search(String query) async => const [];
  @override
  Future<List<RemoteTrack>> tracks(RemoteItem item) async => (item.data! as List).cast<RemoteTrack>();
}
