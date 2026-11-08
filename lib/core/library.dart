import 'package:flutter/foundation.dart';

import 'models.dart';
import 'settings.dart';
import 'source.dart';

enum LibraryState { idle, loading, needsPermission, ready }

/// The scanned songs and everything grouped from them.
class Library extends ChangeNotifier {
  final LibrarySource source;
  final Settings settings;

  Library(this.source, this.settings) {
    settings.addListener(_onSettings);
  }

  LibraryState state = LibraryState.idle;
  List<Song> _all = const [];
  List<Song> songs = const [];
  List<Collection> albums = const [];
  List<Collection> artists = const [];
  List<Collection> genres = const [];
  List<Collection> years = const [];
  List<Collection> folders = const [];

  /// Podcast shows, episodes in each; kept out of the music tabs.
  List<Collection> podcasts = const [];
  Map<int, Song> byId = const {};

  String _filter = '';
  String get _filterNow =>
      '${settings.minSeconds}|${settings.includeFolders.join(',')}|${settings.excludeFolders.join(',')}';
  void _onSettings() {
    if (_filterNow != _filter && state == LibraryState.ready) _rebuild();
  }

  /// Every song Android knows, before the folder and length filters.
  List<Song> get unfiltered => _all;

  /// [quiet] keeps showing the current library while it reloads.
  Future<void> load({bool ask = false, bool quiet = false}) async {
    if (!quiet || state != LibraryState.ready) {
      state = LibraryState.loading;
      notifyListeners();
    }
    var ok = await source.hasPermission();
    if (!ok && ask) ok = await source.requestPermission();
    if (!ok) {
      state = LibraryState.needsPermission;
      notifyListeners();
      return;
    }
    _all = await source.songs();
    _rebuild();
  }

  void _rebuild() {
    _filter = _filterNow;
    final min = settings.minSeconds;
    final include = settings.includeFolders;
    final exclude = settings.excludeFolders;
    final allowed = _all.where((s) => folderAllowed(s.path, include, exclude)).toList();
    final episodes = allowed.where((s) => s.podcast).toList();
    songs = allowed.where((s) => !s.podcast && s.duration.inSeconds >= min).toList();
    byId = {
      for (final s in [...songs, ...episodes]) s.id: s,
    };
    albums = _group(CollectionKind.album, (s) => '${s.albumId}', (s) => s.album, (s) => s.albumArtist);
    // Album tracks in disc / track order.
    for (final a in albums) {
      a.songs.sort((x, y) => x.disc != y.disc ? x.disc.compareTo(y.disc) : x.track.compareTo(y.track));
    }
    artists = _group(
      CollectionKind.artist,
      (s) => s.artist.toLowerCase(),
      (s) => s.artist,
      (s) => '',
      summary: _countAlbums,
    );
    genres = _group(CollectionKind.genre, (s) => s.genre.toLowerCase(), (s) => s.genre, (s) => '');
    years = _group(
      CollectionKind.year,
      (s) => '${s.year}',
      (s) => s.year == 0 ? 'Unknown year' : '${s.year}',
      (s) => '',
    );
    folders = _group(
      CollectionKind.folder,
      (s) => s.folder,
      (s) => s.folder.split('/').last,
      (s) => s.folder,
      from: [...songs, ...episodes],
    );
    podcasts = _group(
      CollectionKind.podcast,
      (s) => s.album.toLowerCase(),
      (s) => s.album,
      (s) => s.albumArtist,
      from: episodes,
      summary: (e) => '${e.first.albumArtist} · ${e.length} ${e.length == 1 ? 'episode' : 'episodes'}',
    );
    state = LibraryState.ready;
    notifyListeners();
  }

  static String _countAlbums(List<Song> songs) {
    final n = songs.map((s) => s.albumId).toSet().length;
    return '$n ${n == 1 ? 'album' : 'albums'} · ${songs.length} ${songs.length == 1 ? 'song' : 'songs'}';
  }

  List<Collection> _group(
    CollectionKind kind,
    String Function(Song) key,
    String Function(Song) title,
    String Function(Song) subtitle, {
    String Function(List<Song>)? summary,
    List<Song>? from,
  }) {
    final map = <String, List<Song>>{};
    for (final s in from ?? songs) {
      (map[key(s)] ??= []).add(s);
    }
    return [
      for (final e in map.entries)
        Collection(
          kind: kind,
          key: e.key,
          title: title(e.value.first),
          subtitle: summary != null
              ? summary(e.value)
              : [
                  if (subtitle(e.value.first).isNotEmpty) subtitle(e.value.first),
                  '${e.value.length} ${e.value.length == 1 ? 'song' : 'songs'}',
                ].join(' · '),
          songs: e.value,
          artAlbumId: e.value.first.albumId,
        ),
    ];
  }

  Collection? album(int albumId) => albums.where((a) => a.key == '$albumId').firstOrNull;
  Collection? artist(String name) => artists.where((a) => a.key == name.toLowerCase()).firstOrNull;

  /// Albums by an artist (as album artist or on any track).
  List<Collection> albumsBy(String artist) {
    final k = artist.toLowerCase();
    return albums
        .where((a) => a.songs.any((s) => s.artist.toLowerCase() == k || s.albumArtist.toLowerCase() == k))
        .toList();
  }

  List<Song> search(String q) {
    final t = q.toLowerCase().trim();
    if (t.isEmpty) return const [];
    return songs
        .where(
          (s) =>
              s.title.toLowerCase().contains(t) ||
              s.artist.toLowerCase().contains(t) ||
              s.album.toLowerCase().contains(t),
        )
        .take(200)
        .toList();
  }

  @override
  void dispose() {
    settings.removeListener(_onSettings);
    super.dispose();
  }
}

/// Inside one of [include] (or anywhere when it's empty) and in none of [exclude].
bool folderAllowed(String path, List<String> include, List<String> exclude) {
  bool under(String dir) => path.startsWith(dir.endsWith('/') ? dir : '$dir/');
  if (exclude.any(under)) return false;
  return include.isEmpty || include.any(under);
}
