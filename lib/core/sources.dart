import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:xml/xml.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

import 'crash_log.dart';
import 'http.dart';
import 'yt_solver.dart';
import 'ytdlp.dart';

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

  /// A YouTube video: the audio comes from YouTube's streams, not [url].
  final String? youtubeId;

  /// Look the song up on MusicBrainz for missing tags (not for podcasts).
  final bool lookUp;

  /// Downloaded by yt-dlp (SoundCloud): [url] is the track's page, the
  /// file type is decided at download time.
  final bool viaYtdlp;

  /// The real stream to preview, when [preview] / [url] is only a page.
  final Future<Uri> Function()? resolvePreview;

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
    this.youtubeId,
    this.lookUp = true,
    this.viaYtdlp = false,
    this.resolvePreview,
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

/// Built-in source ids, in the default order.
const builtInSources = ['soundcloud', 'archive', 'podcasts', 'youtube', 'jamendo', 'ccmixter', 'link'];

/// Sources that can download lossless (FLAC) when it's there.
const losslessSources = {'archive', 'jamendo', 'ccmixter'};

/// Every built-in source. [jamendoKey] and [lossless] (per source id) come
/// from Settings.
List<MusicSource> allSources({required String jamendoKey, required bool Function(String id) lossless}) => [
  SoundCloud(original: lossless('soundcloud')),
  InternetArchive(lossless: lossless('archive')),
  Jamendo(jamendoKey, lossless: lossless('jamendo')),
  CcMixter(lossless: lossless('ccmixter')),
  YouTube(),
  Podcasts(),
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
  Future<List<RemoteTrack>> tracks(RemoteItem item) async => switch (item.source) {
    'youtube' => YouTube().tracks(item),
    'soundcloud' => SoundCloud().tracks(item),
    'podcasts' => Podcasts().tracks(item),
    _ => [item.data! as RemoteTrack],
  };
}

/// The link is a web page: look for music files on it in the browser.
class LinkIsPage implements Exception {
  final Uri url;
  LinkIsPage(this.url);
}

/// A link Roadie won't download from, with the reason in plain words.
class UnsupportedLink implements Exception {
  final String message;
  UnsupportedLink(this.message);
  @override
  String toString() => message;
}

bool isYouTube(Uri u) {
  final h = u.host.toLowerCase();
  return h == 'youtu.be' || h == 'youtube.com' || h.endsWith('.youtube.com') || h == 'youtube-nocookie.com';
}

/// Any direct link to an audio file. Tags come from the name, then MusicBrainz.
/// The link is checked first: a web page opens in the browser instead, and
/// anything that isn't music is refused (nothing is downloaded).
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

  /// Checks what [uri] points at (null: skip the check, for tests).
  final Future<LinkInfo> Function(Uri)? probe;
  DirectLink({this.probe = Http.probe});

  @override
  Future<List<RemoteItem>> search(String query) async {
    var text = query.trim();
    if (!text.contains('://') && RegExp(r'^[\w-]+(\.[\w-]+)+(/|$)').hasMatch(text)) text = 'https://$text';
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasScheme || !uri.scheme.startsWith('http') || uri.host.isEmpty) return const [];
    // YouTube videos and playlists, and podcast feeds, have their own sources.
    if (isYouTube(uri)) return YouTube().fromUrl(uri);
    if (SoundCloud.isLink(uri)) return SoundCloud().fromUrl(uri);
    String? served;
    final check = probe;
    if (check != null) {
      final info = await check(uri);
      switch (info.kind) {
        case LinkKind.page:
          throw LinkIsPage(uri);
        case LinkKind.feed:
          return [await Podcasts().fromFeed(uri)];
        case LinkKind.other:
          throw UnsupportedLink(
            'That link isn\'t a music file (${info.type.isEmpty ? 'unknown type' : info.type}).',
          );
        case LinkKind.music:
          served = info.fileName;
      }
    }
    final name = served ?? Uri.decodeComponent(uri.pathSegments.isEmpty ? 'download' : uri.pathSegments.last);
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

/// YouTube: search, single videos and whole playlists. Downloads the
/// best AAC (M4A) audio stream; tags from the title ("Artist - Title") and
/// channel, cover from the thumbnail, then MusicBrainz.
class YouTube extends MusicSource {
  static final client = yt.YoutubeExplode(jsSolver: WebViewSolver());

  @override
  String get id => 'youtube';
  @override
  String get name => 'YouTube';
  @override
  String get blurb => 'Videos and playlists: Creative Commons, free releases, talks, podcasts';

  static RemoteTrack trackOf(yt.Video v, {String album = '', int number = 0}) {
    var artist = v.author.replaceAll(RegExp(r'\s*-\s*Topic$'), '').replaceAll(RegExp(r'VEVO$'), '').trim();
    var title = v.title;
    final dash = RegExp(r'^(.+?)\s+[-–—]\s+(.+)$').firstMatch(title);
    if (dash != null) {
      artist = dash.group(1)!.trim();
      title = dash.group(2)!.trim();
    }
    title = title
        .replaceAll(
          RegExp(
            r'\s*[\(\[](official|lyric|lyrics|audio|video|hq|hd|4k|visualizer|music video)[^\)\]]*[\)\]]',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
    return RemoteTrack(
      title: title.isEmpty ? v.title : title,
      artist: artist,
      albumArtist: album.isEmpty ? artist : '',
      album: album,
      year: '${v.uploadDate?.year ?? v.publishDate?.year ?? ''}',
      track: number,
      url: Uri.parse(v.url),
      ext: 'm4a',
      length: v.duration,
      cover: v.thumbnails.highResUrl,
      quality: 'AAC',
      youtubeId: v.id.value,
      resolvePreview: () => previewUrl(v.id.value),
    );
  }

  @override
  Future<List<RemoteItem>> search(String query) async {
    final u = Uri.tryParse(query.trim());
    if (u != null && isYouTube(u)) return fromUrl(u);
    final list = await client.search.search(query);
    return [
      for (final v in list)
        if (!v.isLive)
          RemoteItem(
            source: id,
            id: v.id.value,
            title: v.title,
            artist: v.author,
            year: '${v.uploadDate?.year ?? ''}',
            cover: v.thumbnails.mediumResUrl,
            single: true,
            data: trackOf(v),
          ),
    ];
  }

  /// A watch / short / youtu.be link (one video) or a playlist link.
  Future<List<RemoteItem>> fromUrl(Uri u) async {
    try {
      return await _fromUrl(u);
    } on ArgumentError {
      throw UnsupportedLink('That YouTube link isn\'t a video or playlist.');
    }
  }

  Future<List<RemoteItem>> _fromUrl(Uri u) async {
    final listId = u.queryParameters['list'];
    if (listId != null && listId.isNotEmpty && !u.queryParameters.containsKey('v')) {
      final p = await client.playlists.get(listId);
      return [
        RemoteItem(
          source: id,
          id: 'list:${p.id.value}',
          title: p.title,
          artist: p.author,
          cover: p.thumbnails.highResUrl,
        ),
      ];
    }
    final v = await client.videos.get(u.toString());
    return [
      RemoteItem(
        source: id,
        id: v.id.value,
        title: v.title,
        artist: v.author,
        year: '${v.uploadDate?.year ?? ''}',
        cover: v.thumbnails.mediumResUrl,
        single: true,
        data: trackOf(v),
      ),
    ];
  }

  @override
  Future<List<RemoteTrack>> tracks(RemoteItem item) async {
    if (item.single) return [item.data! as RemoteTrack];
    final listId = item.id.replaceFirst('list:', '');
    final out = <RemoteTrack>[];
    var n = 0;
    await for (final v in client.playlists.getVideos(listId).take(500)) {
      n++;
      out.add(trackOf(v, album: item.title, number: n));
    }
    return out;
  }

  /// YouTube app types to ask for the stream, in order. The VR app works
  /// without the extra tokens YouTube now wants from the others.
  static const _clients = [
    ('web player', yt.YoutubeApiClient.safari),
    ('VR app', yt.YoutubeApiClient.androidVr),
    ('TV app', yt.YoutubeApiClient.tv),
    ('mobile web', yt.YoutubeApiClient.mweb),
    ('Android app', yt.YoutubeApiClient.androidSdkless),
  ];

  /// Web types solve YouTube's challenge first (the first time fetches its
  /// player script): give them longer.
  static Duration _limit(String name) =>
      name.contains('web') || name.contains('TV') ? const Duration(seconds: 90) : const Duration(seconds: 40);

  /// YouTube's own reason, from its exception text ("Reason: ...").
  static String reason(Object e) {
    final t = '$e';
    final m = RegExp(r'Reason:\s*(.+)').firstMatch(t);
    return (m?.group(1) ?? t.split('\n').first).trim();
  }

  /// The audio stream to download or preview (AAC in MP4), trying each app
  /// type in turn; [status] hears which one.
  static Future<yt.AudioOnlyStreamInfo> audio(String videoId, {void Function(String)? status}) async {
    Object? last;
    for (var i = 0; i < _clients.length; i++) {
      final (name, api) = _clients[i];
      status?.call('Finding the audio (${i + 1}/${_clients.length}: $name)…');
      try {
        final m = await client.videos.streamsClient
            .getManifest(videoId, ytClients: [api])
            .timeout(_limit(name));
        final mp4 = m.audioOnly.where((s) => s.container == yt.StreamContainer.mp4);
        if (mp4.isNotEmpty) return mp4.withHighestBitrate();
        last = UnsupportedLink('This video has no downloadable audio');
      } on Object catch (e) {
        last = e;
        CrashLog.note('YouTube $videoId via $name: ${reason(e)}');
      }
    }
    throw UnsupportedLink(
      'YouTube refused every way of getting this video'
      '${last == null ? '' : ' (last: ${reason(last)})'}.',
    );
  }

  static Future<Uri> previewUrl(String videoId) async => (await audio(videoId)).url;

  /// Saves the video's audio to [file] (via a .part file), in ~9 MB pieces
  /// (YouTube slows down single big requests to a crawl). If YouTube refuses
  /// a stream, the next app type is tried.
  static Future<void> download(
    String videoId,
    File file, {
    void Function(double)? progress,
    void Function(String)? status,
    bool Function()? cancelled,
  }) async {
    final part = File('${file.path}.part');
    await part.parent.create(recursive: true);
    Object? last;
    for (var attempt = 0; attempt < _clients.length; attempt++) {
      // Each attempt asks a different app type first.
      final (name, api) = _clients[attempt];
      status?.call('Finding the audio (${attempt + 1}/${_clients.length}: $name)…');
      yt.AudioOnlyStreamInfo info;
      try {
        final m = await YouTube.client.videos.streamsClient
            .getManifest(videoId, ytClients: [api])
            .timeout(_limit(name));
        final mp4 = m.audioOnly.where((s) => s.container == yt.StreamContainer.mp4);
        if (mp4.isEmpty) {
          last = UnsupportedLink('This video has no downloadable audio');
          continue;
        }
        info = mp4.withHighestBitrate();
      } on Object catch (e) {
        last = e;
        CrashLog.note('YouTube $videoId via $name: ${reason(e)}');
        continue;
      }
      try {
        status?.call('');
        await Http.downloadPieces(
          info.url,
          part,
          info.size.totalBytes,
          rangeInQuery: info.url.queryParameters['c'] != 'ANDROID',
          progress: progress,
          cancelled: cancelled,
        );
        final head = await part.openRead(0, 64).fold<List<int>>([], (a, b) => a..addAll(b));
        if (!looksLikeAudio(head, 'audio/mp4')) throw NotMusicFile('not audio');
        if (await file.exists()) await file.delete();
        await part.rename(file.path);
        return;
      } on HttpFailure catch (e) {
        if (e.message == 'Cancelled') rethrow;
        last = e; // refused (403) or cut off: next app type
        CrashLog.note('YouTube $videoId via $name: download $e');
        if (await part.exists()) await part.delete();
      }
    }
    throw UnsupportedLink(
      'YouTube refused every way of getting this video'
      '${last == null ? '' : ' (last: ${reason(last)})'}. Details are in Problem reports.',
    );
  }
}

/// Podcasts: search Apple's free podcast directory, then download episodes
/// straight from the show's own feed (or paste any podcast feed link).
class Podcasts extends MusicSource {
  @override
  String get id => 'podcasts';
  @override
  String get name => 'Podcasts';
  @override
  String get blurb => 'Any podcast: episodes straight from the show\'s own feed';

  @override
  Future<List<RemoteItem>> search(String query) async {
    final d =
        await Http.json(
              Uri.https('itunes.apple.com', '/search', {'media': 'podcast', 'term': query, 'limit': '40'}),
            )
            as Map;
    return [
      for (final r in (d['results'] as List? ?? const []).cast<Map<Object?, Object?>>())
        if (r['feedUrl'] != null)
          RemoteItem(
            source: id,
            id: '${r['feedUrl']}',
            title: '${r['collectionName'] ?? r['trackName'] ?? ''}',
            artist: '${r['artistName'] ?? ''}',
            cover: (r['artworkUrl600'] ?? r['artworkUrl100']) as String?,
            data: Uri.parse('${r['feedUrl']}'),
          ),
    ];
  }

  Future<RemoteItem> fromFeed(Uri feed) async {
    final show = parseFeed(utf8.decode(await Http.bytes(feed), allowMalformed: true));
    return RemoteItem(
      source: id,
      id: feed.toString(),
      title: show.$1,
      artist: show.$2,
      cover: show.$3,
      data: feed,
    );
  }

  @override
  Future<List<RemoteTrack>> tracks(RemoteItem item) async {
    final feed = item.data is Uri ? item.data! as Uri : Uri.parse(item.id);
    return parseFeed(utf8.decode(await Http.bytes(feed), allowMalformed: true)).$4;
  }

  static const _types = {
    'audio/mpeg': 'mp3',
    'audio/mp3': 'mp3',
    'audio/x-m4a': 'm4a',
    'audio/m4a': 'm4a',
    'audio/mp4': 'm4a',
    'audio/aac': 'aac',
    'audio/ogg': 'ogg',
    'audio/opus': 'opus',
    'audio/flac': 'flac',
    'audio/x-flac': 'flac',
    'audio/wav': 'wav',
  };

  /// (show title, author, cover, episodes newest first) from RSS.
  static (String, String, String?, List<RemoteTrack>) parseFeed(String text) {
    final doc = XmlDocument.parse(text);
    final ch = doc.findAllElements('channel').first;
    String child(XmlElement e, String name) =>
        e.childElements.where((c) => c.name.qualified == name).firstOrNull?.innerText.trim() ?? '';
    final show = child(ch, 'title');
    final author = child(ch, 'itunes:author').isNotEmpty
        ? child(ch, 'itunes:author')
        : child(ch, 'managingEditor');
    final cover =
        ch.childElements.where((c) => c.name.qualified == 'itunes:image').firstOrNull?.getAttribute('href') ??
        ch.findElements('image').firstOrNull?.findElements('url').firstOrNull?.innerText.trim();
    final eps = <RemoteTrack>[];
    for (final it in ch.findElements('item')) {
      final enc = it.findElements('enclosure').firstOrNull;
      final url = enc?.getAttribute('url');
      if (url == null || url.isEmpty) continue;
      final type = (enc?.getAttribute('type') ?? '').toLowerCase();
      if (type.startsWith('video/')) continue;
      final u = Uri.tryParse(url.trim());
      if (u == null) continue;
      final pathExt = u.path.contains('.') ? u.path.substring(u.path.lastIndexOf('.') + 1).toLowerCase() : '';
      final ext = _types[type] ?? (DirectLink.audioExts.contains(pathExt) ? pathExt : 'mp3');
      final year = RegExp(r'\b(19|20)\d\d\b').firstMatch(child(it, 'pubDate'))?.group(0) ?? '';
      final dur = child(it, 'itunes:duration');
      final epImage = it.childElements
          .where((c) => c.name.qualified == 'itunes:image')
          .firstOrNull
          ?.getAttribute('href');
      eps.add(
        RemoteTrack(
          title: child(it, 'title'),
          artist: author.isNotEmpty ? author : show,
          albumArtist: author.isNotEmpty ? author : show,
          album: show,
          year: year,
          genre: 'Podcast',
          track: int.tryParse(child(it, 'itunes:episode')) ?? 0,
          url: u,
          ext: ext,
          length: _seconds(dur.isEmpty ? null : dur),
          cover: epImage ?? cover,
          quality: ext.toUpperCase(),
          lookUp: false,
        ),
      );
    }
    return (show, author, cover, eps);
  }
}

/// SoundCloud through yt-dlp: search, tracks, sets / albums and links.
/// The artist's original file when they allow downloads, otherwise the
/// best stream (never the 30-second Go+ previews).
class SoundCloud extends MusicSource {
  final bool original;
  SoundCloud({this.original = true});

  @override
  String get id => 'soundcloud';
  @override
  String get name => 'SoundCloud';
  @override
  String get blurb => 'Millions of tracks, remixes and mixes, from the artists themselves';

  static bool isLink(Uri u) {
    final h = u.host.toLowerCase();
    return h == 'soundcloud.com' || h.endsWith('.soundcloud.com') || h == 'snd.sc';
  }

  /// yt-dlp format choice: the artist's file, then MP3, then any full stream.
  String get format => [
    if (original) 'download',
    'bestaudio[format_id!*=preview][ext=mp3]',
    'bestaudio[format_id!*=preview][ext=m4a]',
    'bestaudio[format_id!*=preview]',
  ].join('/');

  static String? _art(Map<String, Object?> e) {
    final thumbs = (e['thumbnails'] as List? ?? const []).cast<Map<Object?, Object?>>();
    final big =
        thumbs.where((t) => '${t['id']}' == 't500x500').firstOrNull ??
        (thumbs.isEmpty
            ? null
            : thumbs.reduce((a, b) => ((a['width'] as num?) ?? 0) >= ((b['width'] as num?) ?? 0) ? a : b));
    return (big?['url'] ?? e['thumbnail']) as String?;
  }

  RemoteTrack trackOf(Map<String, Object?> e, {String album = '', int number = 0}) {
    var artist = '${e['artist'] ?? e['uploader'] ?? ''}';
    var title = '${e['track'] ?? e['title'] ?? ''}';
    final dash = RegExp(r'^(.+?)\s+[-–—]\s+(.+)$').firstMatch(title);
    if (dash != null && e['artist'] == null) {
      artist = dash.group(1)!.trim();
      title = dash.group(2)!.trim();
    }
    final date = '${e['upload_date'] ?? ''}';
    final url = '${e['webpage_url'] ?? e['url'] ?? ''}';
    final genres = e['genres'] is List ? (e['genres']! as List) : const [];
    return RemoteTrack(
      title: title,
      artist: artist,
      album: album,
      albumArtist: album.isEmpty ? artist : '${e['album_artist'] ?? ''}',
      year: '${e['release_year'] ?? (date.length >= 4 ? date.substring(0, 4) : '')}',
      genre: '${e['genre'] ?? (genres.isEmpty ? '' : genres.first)}',
      track: number,
      url: Uri.parse(url),
      ext: 'mp3',
      length: _seconds(e['duration']),
      cover: _art(e),
      quality: original ? 'Original or MP3' : 'MP3',
      viaYtdlp: true,
      resolvePreview: () => streamUrl(url),
    );
  }

  /// A playable stream for previews (MP3 or HLS).
  static Future<Uri> streamUrl(String page) async {
    final r = await Ytdlp.run(page, [
      '-g',
      '--no-playlist',
      '-f',
      'bestaudio[format_id!*=preview][ext=mp3]/bestaudio[format_id!*=preview]/bestaudio',
    ]);
    return Uri.parse(r.out.split('\n').firstWhere((l) => l.startsWith('http')));
  }

  @override
  Future<List<RemoteItem>> search(String query) async {
    final u = Uri.tryParse(query.trim());
    if (u != null && u.hasScheme && isLink(u)) return fromUrl(u);
    final j = Ytdlp.json(await Ytdlp.run('scsearch40:$query', ['-J', '--flat-playlist']));
    final entries = (j['entries'] as List? ?? const []).cast<Map<Object?, Object?>>();
    return [
      for (final raw in entries)
        if (raw['title'] != null)
          () {
            final e = raw.cast<String, Object?>();
            final t = trackOf(e);
            return RemoteItem(
              source: id,
              id: t.url.toString(),
              title: '${e['title']}',
              artist: '${e['uploader'] ?? ''}',
              year: t.year,
              cover: t.cover,
              single: true,
              data: t,
            );
          }(),
    ];
  }

  /// A track, set / album, or artist page link.
  Future<List<RemoteItem>> fromUrl(Uri u) async {
    final j = Ytdlp.json(await Ytdlp.run(u.toString(), ['-J', '--flat-playlist', '--playlist-end', '300']));
    if (j['_type'] == 'playlist') {
      return [
        RemoteItem(
          source: id,
          id: u.toString(),
          title: '${j['title'] ?? 'SoundCloud playlist'}',
          artist: '${j['uploader'] ?? ''}',
          cover: _art(j),
          data: u.toString(),
        ),
      ];
    }
    final t = trackOf(j);
    return [
      RemoteItem(
        source: id,
        id: u.toString(),
        title: '${j['title'] ?? ''}',
        artist: '${j['uploader'] ?? ''}',
        year: t.year,
        cover: t.cover,
        single: true,
        data: t,
      ),
    ];
  }

  @override
  Future<List<RemoteTrack>> tracks(RemoteItem item) async {
    if (item.single) return [item.data! as RemoteTrack];
    // Full details for each track of the set (titles, lengths, covers).
    final j = Ytdlp.json(await Ytdlp.run('${item.data}', ['-J', '--playlist-end', '300']));
    final album = '${j['title'] ?? item.title}';
    final entries = (j['entries'] as List? ?? const []).whereType<Map<Object?, Object?>>().toList();
    return [
      for (var i = 0; i < entries.length; i++)
        trackOf(entries[i].cast<String, Object?>(), album: album, number: i + 1),
    ];
  }
}
