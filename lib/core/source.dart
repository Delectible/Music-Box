import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

import 'models.dart';

/// Where the library comes from. On the device that's Android's media
/// index (MainActivity.kt); tests and screenshots use [DemoSource].
abstract class LibrarySource {
  Future<bool> hasPermission();
  Future<bool> requestPermission();
  Future<List<Song>> songs();

  /// A cached file with the album's cover at about [size] px, or null.
  Future<String?> art(int albumId, int size);

  /// Asks the media index to pick up new files (e.g. after a download).
  Future<void> scan(List<String> paths);

  /// A cover already fetched for [albumId] (this size, else the closest),
  /// so it can show on the first frame. Null if none is known yet.
  String? artNow(int albumId, int size) => null;
}

class MediaStoreSource implements LibrarySource {
  static const _ch = MethodChannel('roadie/library');

  @override
  Future<bool> hasPermission() async => await _ch.invokeMethod<bool>('hasPermission') ?? false;

  @override
  Future<bool> requestPermission() async => await _ch.invokeMethod<bool>('requestPermission') ?? false;

  @override
  Future<List<Song>> songs() async {
    final raw = await _ch.invokeListMethod<Map<Object?, Object?>>('songs') ?? const [];
    return raw.map(Song.fromMap).toList();
  }

  final _art = <String, Future<String?>>{};
  final _known = <String, String>{};

  @override
  Future<String?> art(int albumId, int size) => _art.putIfAbsent('$albumId@$size', () async {
    try {
      final path = await _ch.invokeMethod<String>('art', {'albumId': albumId, 'size': size});
      final ok = path != null && File(path).existsSync() ? path : null;
      if (ok != null) _known['$albumId@$size'] = ok;
      return ok;
    } on PlatformException {
      return null;
    }
  });

  @override
  String? artNow(int albumId, int size) {
    final exact = _known['$albumId@$size'];
    if (exact != null) return exact;
    for (final s in const [800, 400, 160]) {
      final p = _known['$albumId@$s'];
      if (p != null) return p;
    }
    return null;
  }

  @override
  Future<void> scan(List<String> paths) => _ch.invokeMethod('scan', {'paths': paths});
}

/// A made-up library (no files, no covers) for tests and screenshots.
class DemoSource implements LibrarySource {
  @override
  Future<bool> hasPermission() async => true;
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<String?> art(int albumId, int size) async => null;
  @override
  Future<void> scan(List<String> paths) async {}
  @override
  String? artNow(int albumId, int size) => null;

  static const _albums = <(String, String, String, int, List<String>)>[
    (
      'Night Drive',
      'Lumen Coast',
      'Synthwave',
      2021,
      ['Neon Overpass', 'Exit 42', 'Tail Lights', 'Coastline at 2am', 'Cruise Control', 'Rearview'],
    ),
    (
      'Paper Lanterns',
      'Mara Vell',
      'Indie',
      2019,
      ['Lantern Song', 'Folded Maps', 'Sparrows', 'The Long Field', 'Kite String'],
    ),
    (
      'Copper Hills',
      'The Wayfarers',
      'Folk',
      2016,
      ['Copper Hills', 'Riverbend', 'Woodsmoke', 'Old Mill Road', 'Harvest Moon Waltz', 'Homeward'],
    ),
    (
      'Static Bloom',
      'Orbit Kids',
      'Electronic',
      2023,
      ['Signal', 'Bloom', 'Satellite Heart', 'Low Orbit', 'Fade Out'],
    ),
    (
      'Blue Hour',
      'Ines Dorado',
      'Jazz',
      2018,
      ['Blue Hour', 'Second Avenue', 'Smoke Rings', 'Late Train', 'Velvet'],
    ),
    (
      'Gravel & Gold',
      'Hollow Pines',
      'Rock',
      2014,
      ['Gravel', 'Gold Rush', 'Engine Heart', 'Dust Devil', 'Open Road', 'Last Gas Station'],
    ),
    ('Afterglow', 'Lumen Coast', 'Synthwave', 2024, ['Afterglow', 'Mirage', 'Skyline Drift', 'Polaroid']),
    ('Tidal', 'Sea of Glass', 'Ambient', 2020, ['Low Tide', 'Undertow', 'Saltwater', 'Lighthouse']),
    ('Wildflower Radio', 'Mara Vell', 'Indie', 2022, ['Radio', 'Wildflower', 'Porch Light', 'Summer Rain']),
    ('Brass Parade', 'The Second Line', 'Funk', 2017, ['Parade', 'Strut', 'Big Easy', 'Horn Section']),
  ];

  @override
  Future<List<Song>> songs() async {
    final r = Random(7);
    final out = <Song>[];
    var id = 1;
    for (var a = 0; a < _albums.length; a++) {
      final (album, artist, genre, year, tracks) = _albums[a];
      for (var t = 0; t < tracks.length; t++) {
        final secs = 150 + r.nextInt(180);
        final path = '/storage/emulated/0/Music/$artist/$album/${t + 1} ${tracks[t]}.mp3';
        out.add(
          Song(
            id: id,
            uri: path,
            path: path,
            title: tracks[t],
            artist: artist,
            album: album,
            albumArtist: artist,
            albumId: a + 1,
            genre: genre,
            year: year,
            track: t + 1,
            disc: 1,
            duration: Duration(seconds: secs),
            added: DateTime(2025, 1 + a, 1 + t),
            modified: DateTime(2025, 1 + a, 1 + t),
            size: secs * 40000,
          ),
        );
        id++;
      }
    }
    // A podcast, kept apart from the music.
    const eps = ['Maps and Shortcuts', 'The Long Way Home', 'Night Radio', 'Fuel Stops', 'Last Exit'];
    for (var e = 0; e < eps.length; e++) {
      final path = '/storage/emulated/0/Podcasts/Road Talk/${e + 1} ${eps[e]}.mp3';
      out.add(
        Song(
          id: id++,
          uri: path,
          path: path,
          title: eps[e],
          artist: 'Jo Host',
          album: 'Road Talk',
          albumArtist: 'Jo Host',
          albumId: 99,
          genre: 'Podcast',
          year: 2026,
          track: e + 1,
          disc: 1,
          duration: Duration(minutes: 30 + e * 4),
          added: DateTime(2026, 1, 1 + e * 7),
          modified: DateTime(2026, 1, 1 + e * 7),
          size: 30000000,
          podcast: true,
        ),
      );
    }
    return out;
  }
}
