import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class Playlist {
  final String id;
  String name;
  final List<int> songIds;
  final DateTime created;

  /// Its own cover: an image file (from the playlist it was downloaded from,
  /// or picked), or one of its songs' covers. Neither: the first song's.
  String? coverPath;
  int? coverSongId;

  Playlist(this.id, this.name, this.songIds, this.created, {this.coverPath, this.coverSongId});

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'songs': songIds,
    'created': created.millisecondsSinceEpoch,
    'coverPath': ?coverPath,
    'coverSong': ?coverSongId,
  };

  static Playlist fromJson(Map<String, Object?> m) => Playlist(
    m['id']! as String,
    m['name']! as String,
    [for (final n in m['songs']! as List<Object?>) (n! as num).toInt()],
    DateTime.fromMillisecondsSinceEpoch((m['created']! as num).toInt()),
    coverPath: m['coverPath'] as String?,
    coverSongId: (m['coverSong'] as num?)?.toInt(),
  );
}

/// The app's own playlists, plus Favourites.
class Playlists extends ChangeNotifier {
  static const favourites = 'fav';
  final SharedPreferences _p;
  final List<Playlist> all = [];

  Playlists(this._p) {
    try {
      for (final m in jsonDecode(_p.getString('playlists') ?? '[]') as List<Object?>) {
        all.add(Playlist.fromJson((m! as Map).cast<String, Object?>()));
      }
    } on Object {
      // Start over rather than fail to open.
    }
    if (!all.any((p) => p.id == favourites)) {
      all.insert(0, Playlist(favourites, 'Favourites', [], DateTime(2000)));
    }
  }

  void _save() {
    _p.setString('playlists', jsonEncode([for (final p in all) p.toJson()]));
    notifyListeners();
  }

  Playlist get favs => all.firstWhere((p) => p.id == favourites);
  bool isFavourite(int songId) => favs.songIds.contains(songId);

  void toggleFavourite(int songId) {
    final f = favs.songIds;
    f.contains(songId) ? f.remove(songId) : f.add(songId);
    _save();
  }

  Playlist create(String name) {
    final p = Playlist('${DateTime.now().microsecondsSinceEpoch}', name, [], DateTime.now());
    all.add(p);
    _save();
    return p;
  }

  void add(Playlist p, List<Song> songs) {
    for (final s in songs) {
      if (!p.songIds.contains(s.id)) p.songIds.add(s.id);
    }
    _save();
  }

  void remove(Playlist p, int songId) {
    p.songIds.remove(songId);
    _save();
  }

  void move(Playlist p, int from, int to) {
    p.songIds.insert(to, p.songIds.removeAt(from));
    _save();
  }

  /// A picture file or a song's cover as the playlist's cover; neither: automatic.
  void setCover(Playlist p, {String? path, int? songId}) {
    final old = p.coverPath;
    if (old != null && old != path && old.contains('/covers/')) {
      try {
        File(old).deleteSync();
      } on Object {
        // Already gone.
      }
    }
    p
      ..coverPath = path
      ..coverSongId = songId;
    _save();
  }

  void rename(Playlist p, String name) {
    p.name = name;
    _save();
  }

  void delete(Playlist p) {
    if (p.id == favourites) return;
    all.remove(p);
    _save();
  }

  List<Collection> collections(Map<int, Song> byId) => [
    for (final p in all)
      () {
        final songs = [for (final id in p.songIds) ?byId[id]];
        final coverSong = p.coverSongId == null ? null : byId[p.coverSongId];
        return Collection(
          kind: CollectionKind.playlist,
          key: p.id,
          title: p.name,
          subtitle: '${songs.length} ${songs.length == 1 ? 'song' : 'songs'}',
          songs: songs,
          artAlbumId: coverSong?.albumId ?? (songs.isEmpty ? -1 : songs.first.albumId),
          coverPath: p.coverPath != null && File(p.coverPath!).existsSync() ? p.coverPath : null,
        );
      }(),
  ];

  Playlist? byKey(String key) => all.where((p) => p.id == key).firstOrNull;
}
