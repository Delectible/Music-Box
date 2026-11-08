/// A track on the device, as the library scan reports it.
class Song {
  final int id;
  final String uri; // content:// or file path the player opens
  final String path; // file path (folders view)
  final String title;
  final String artist;
  final String album;
  final String albumArtist;
  final int albumId;
  final String genre;
  final int year;
  final int track; // track number within the disc
  final int disc;
  final Duration duration;
  final DateTime added;
  final DateTime modified;
  final int size; // bytes

  /// A podcast episode (Android says so, or the genre is Podcast).
  final bool podcast;

  const Song({
    required this.id,
    required this.uri,
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    required this.albumArtist,
    required this.albumId,
    required this.genre,
    required this.year,
    required this.track,
    required this.disc,
    required this.duration,
    required this.added,
    required this.modified,
    required this.size,
    this.podcast = false,
  });

  String get folder {
    final i = path.lastIndexOf('/');
    return i <= 0 ? '/' : path.substring(0, i);
  }

  String get fileName => path.substring(path.lastIndexOf('/') + 1);

  factory Song.fromMap(Map<Object?, Object?> m) {
    String s(String k, [String fallback = '']) {
      final v = m[k];
      final t = v is String ? v.trim() : '';
      return t.isEmpty || t == '<unknown>' ? fallback : t;
    }

    int n(String k) => (m[k] as num?)?.toInt() ?? 0;
    final rawTrack = n('track');
    final artist = s('artist', 'Unknown artist');
    return Song(
      id: n('id'),
      uri: s('uri'),
      path: s('path'),
      title: s('title', s('path').split('/').last),
      artist: artist,
      album: s('album', 'Unknown album'),
      albumArtist: s('albumArtist', artist),
      albumId: n('albumId'),
      genre: s('genre', 'Unknown genre'),
      year: n('year'),
      // MediaStore packs the disc into the thousands (2003 = disc 2, track 3).
      track: rawTrack % 1000,
      disc: n('disc') > 0 ? n('disc') : (rawTrack ~/ 1000).clamp(1, 99),
      duration: Duration(milliseconds: n('duration')),
      added: DateTime.fromMillisecondsSinceEpoch(n('added') * 1000),
      modified: DateTime.fromMillisecondsSinceEpoch(n('modified') * 1000),
      size: n('size'),
      podcast: n('podcast') != 0 || s('genre').toLowerCase() == 'podcast',
    );
  }
}

/// What a group of songs is collected by.
enum CollectionKind { album, artist, albumArtist, genre, folder, playlist, year, podcast }

/// A group of songs: an album, artist, genre, folder, year or playlist.
class Collection {
  final CollectionKind kind;
  final String key; // unique within the kind
  final String title;
  final String subtitle;
  final List<Song> songs;

  /// Album id whose art stands for the collection.
  final int artAlbumId;

  const Collection({
    required this.kind,
    required this.key,
    required this.title,
    required this.subtitle,
    required this.songs,
    required this.artAlbumId,
  });

  Duration get duration => songs.fold(Duration.zero, (a, s) => a + s.duration);
  int get year => songs.fold(0, (a, s) => s.year > a ? s.year : a);
  DateTime get added =>
      songs.fold(DateTime.fromMillisecondsSinceEpoch(0), (a, s) => s.added.isAfter(a) ? s.added : a);
}
