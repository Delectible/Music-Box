import 'dart:math';

import 'models.dart';

/// What a list can be sorted by. Not every key fits every tab: see [SortKey.forTab].
enum SortKey {
  title('Title'),
  artist('Artist'),
  album('Album'),
  albumArtist('Album artist'),
  year('Year'),
  duration('Length'),
  added('Date added'),
  modified('Date modified'),
  track('Track number'),
  plays('Most played'),
  lastPlayed('Recently played'),
  songCount('Number of songs'),
  fileName('File name'),
  random('Shuffle');

  final String label;
  const SortKey(this.label);

  static List<SortKey> forTab(LibraryTab tab) => switch (tab) {
    LibraryTab.songs => [
      title,
      artist,
      album,
      albumArtist,
      year,
      duration,
      added,
      modified,
      plays,
      lastPlayed,
      fileName,
      random,
    ],
    LibraryTab.albums => [title, artist, year, added, songCount, duration, plays, random],
    LibraryTab.artists || LibraryTab.genres => [title, songCount, duration, added, plays, random],
    LibraryTab.folders => [title, songCount, added, random],
    LibraryTab.playlists => [title, songCount, duration, added],
    LibraryTab.podcasts => [added, title, songCount, lastPlayed, plays, random],
    LibraryTab.years => [year, songCount],
    LibraryTab.get => [title],
  };

  /// Keys that read best newest / biggest first.
  bool get descendingByDefault =>
      this == added || this == modified || this == plays || this == lastPlayed || this == songCount;
}

/// How a list is drawn.
enum ViewMode {
  list('List'),
  compact('Compact'),
  grid('Grid'),
  cards('Big cards');

  final String label;
  const ViewMode(this.label);
}

/// The library's tabs. Order and visibility are set in Settings.
enum LibraryTab {
  songs('Songs'),
  albums('Albums'),
  artists('Artists'),
  genres('Genres'),
  years('Years'),
  folders('Folders'),
  playlists('Playlists'),
  podcasts('Podcasts'),
  get('Get music');

  final String label;
  const LibraryTab(this.label);
}

/// One tab's view options (saved per tab).
class ViewOptions {
  final SortKey sort;
  final bool descending;
  final ViewMode mode;
  final int columns; // grid columns; 0 = fit the screen
  final bool headers; // section headers (A, B, C ... or years)

  const ViewOptions({
    required this.sort,
    this.descending = false,
    required this.mode,
    this.columns = 0,
    this.headers = true,
  });

  static ViewOptions defaults(LibraryTab tab) => switch (tab) {
    LibraryTab.songs => const ViewOptions(sort: SortKey.title, mode: ViewMode.list),
    LibraryTab.albums => const ViewOptions(sort: SortKey.title, mode: ViewMode.grid),
    LibraryTab.artists => const ViewOptions(sort: SortKey.title, mode: ViewMode.list),
    LibraryTab.genres => const ViewOptions(sort: SortKey.title, mode: ViewMode.cards),
    LibraryTab.years => const ViewOptions(sort: SortKey.year, descending: true, mode: ViewMode.grid),
    LibraryTab.folders => const ViewOptions(sort: SortKey.title, mode: ViewMode.list),
    LibraryTab.playlists => const ViewOptions(sort: SortKey.title, mode: ViewMode.cards),
    LibraryTab.podcasts => const ViewOptions(sort: SortKey.added, descending: true, mode: ViewMode.grid),
    LibraryTab.get => const ViewOptions(sort: SortKey.title, mode: ViewMode.list),
  };

  ViewOptions copyWith({SortKey? sort, bool? descending, ViewMode? mode, int? columns, bool? headers}) =>
      ViewOptions(
        sort: sort ?? this.sort,
        descending: descending ?? this.descending,
        mode: mode ?? this.mode,
        columns: columns ?? this.columns,
        headers: headers ?? this.headers,
      );

  String encode() => [sort.name, descending ? 1 : 0, mode.name, columns, headers ? 1 : 0].join('|');

  static ViewOptions decode(String? s, LibraryTab tab) {
    final d = defaults(tab);
    if (s == null) return d;
    final p = s.split('|');
    if (p.length != 5) return d;
    T pick<T extends Enum>(List<T> values, String name, T fallback) =>
        values.where((v) => v.name == name).firstOrNull ?? fallback;
    return ViewOptions(
      sort: pick(SortKey.values, p[0], d.sort),
      descending: p[1] == '1',
      mode: pick(ViewMode.values, p[2], d.mode),
      columns: int.tryParse(p[3]) ?? 0,
      headers: p[4] == '1',
    );
  }
}

/// Plays and last-played time, kept by the player.
abstract class PlayHistory {
  int plays(int songId);
  DateTime? lastPlayed(int songId);
}

/// Sort key for text: case-insensitive, leading "The " / "A " ignored.
String sortable(String s) {
  var t = s.toLowerCase().trim();
  for (final p in const ['the ', 'a ', 'an ']) {
    if (t.startsWith(p) && t.length > p.length) {
      t = t.substring(p.length);
      break;
    }
  }
  return t;
}

/// Section letter for a title: A–Z, or # for digits and symbols.
String letterOf(String s) {
  final t = sortable(s);
  if (t.isEmpty) return '#';
  final c = t[0].toUpperCase();
  return RegExp('[A-Z]').hasMatch(c) ? c : '#';
}

int _cmp<T extends Comparable<Object>>(T a, T b) => a.compareTo(b);

List<Song> sortSongs(List<Song> songs, SortKey key, bool descending, PlayHistory history, {int seed = 1}) {
  int byTitle(Song a, Song b) => _cmp(sortable(a.title), sortable(b.title));
  int byAlbumOrder(Song a, Song b) {
    final c = _cmp(sortable(a.album), sortable(b.album));
    if (c != 0) return c;
    final d = a.disc.compareTo(b.disc);
    return d != 0 ? d : a.track.compareTo(b.track);
  }

  final Comparator<Song> cmp = switch (key) {
    SortKey.title => byTitle,
    SortKey.artist => (a, b) {
      final c = _cmp(sortable(a.artist), sortable(b.artist));
      return c != 0 ? c : byAlbumOrder(a, b);
    },
    SortKey.album => byAlbumOrder,
    SortKey.albumArtist => (a, b) {
      final c = _cmp(sortable(a.albumArtist), sortable(b.albumArtist));
      return c != 0 ? c : byAlbumOrder(a, b);
    },
    SortKey.year => (a, b) {
      final c = a.year.compareTo(b.year);
      return c != 0 ? c : byAlbumOrder(a, b);
    },
    SortKey.duration => (a, b) => a.duration.compareTo(b.duration),
    SortKey.added => (a, b) => a.added.compareTo(b.added),
    SortKey.modified => (a, b) => a.modified.compareTo(b.modified),
    SortKey.track => (a, b) {
      final d = a.disc.compareTo(b.disc);
      return d != 0 ? d : a.track.compareTo(b.track);
    },
    SortKey.plays => (a, b) {
      final c = history.plays(a.id).compareTo(history.plays(b.id));
      return c != 0 ? c : -byTitle(a, b);
    },
    SortKey.lastPlayed => (a, b) {
      final x = history.lastPlayed(a.id)?.millisecondsSinceEpoch ?? 0;
      final y = history.lastPlayed(b.id)?.millisecondsSinceEpoch ?? 0;
      return x.compareTo(y);
    },
    SortKey.fileName => (a, b) => _cmp(a.fileName.toLowerCase(), b.fileName.toLowerCase()),
    SortKey.songCount => byTitle,
    SortKey.random => (a, b) => _hash(a.id, seed).compareTo(_hash(b.id, seed)),
  };
  final out = [...songs]..sort(cmp);
  return descending && key != SortKey.random ? out.reversed.toList() : out;
}

List<Collection> sortCollections(
  List<Collection> items,
  SortKey key,
  bool descending,
  PlayHistory history, {
  int seed = 1,
}) {
  int byTitle(Collection a, Collection b) => _cmp(sortable(a.title), sortable(b.title));
  int plays(Collection c) => c.songs.fold(0, (n, s) => n + history.plays(s.id));
  final Comparator<Collection> cmp = switch (key) {
    SortKey.artist => (a, b) {
      final c = _cmp(sortable(a.subtitle), sortable(b.subtitle));
      return c != 0 ? c : byTitle(a, b);
    },
    SortKey.year => (a, b) {
      final c = a.year.compareTo(b.year);
      return c != 0 ? c : byTitle(a, b);
    },
    SortKey.added => (a, b) => a.added.compareTo(b.added),
    SortKey.songCount => (a, b) {
      final c = a.songs.length.compareTo(b.songs.length);
      return c != 0 ? c : -byTitle(a, b);
    },
    SortKey.duration => (a, b) => a.duration.compareTo(b.duration),
    SortKey.plays => (a, b) {
      final c = plays(a).compareTo(plays(b));
      return c != 0 ? c : -byTitle(a, b);
    },
    SortKey.lastPlayed => (a, b) {
      int last(Collection c) =>
          c.songs.fold(0, (m, s) => max(m, history.lastPlayed(s.id)?.millisecondsSinceEpoch ?? 0));
      return last(a).compareTo(last(b));
    },
    SortKey.random => (a, b) => _hash(a.key.hashCode, seed).compareTo(_hash(b.key.hashCode, seed)),
    _ => byTitle,
  };
  final out = [...items]..sort(cmp);
  return descending && key != SortKey.random ? out.reversed.toList() : out;
}

/// Section header for an item at a sort key (null = no headers for this key).
String? sectionOf(SortKey key, {required String title, String? artist, String? album, int year = 0}) =>
    switch (key) {
      SortKey.title => letterOf(title),
      SortKey.artist || SortKey.albumArtist => letterOf(artist ?? title),
      SortKey.album => letterOf(album ?? title),
      SortKey.year => year == 0 ? 'Unknown year' : '$year',
      _ => null,
    };

int _hash(int x, int seed) {
  var h = (x ^ (seed * 0x9E3779B1)) & 0x7fffffff;
  h = ((h >> 16) ^ h) * 0x45d9f3b & 0x7fffffff;
  h = ((h >> 16) ^ h) * 0x45d9f3b & 0x7fffffff;
  return (h >> 16) ^ h;
}
