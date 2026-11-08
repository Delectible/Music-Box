import 'dart:math';

import 'library.dart';
import 'models.dart';
import 'player.dart';
import 'playlists.dart';

/// Playlists that fill themselves from the library and your listening.
List<Collection> smartPlaylists(Library lib, Player p, Playlists lists, {DateTime? now}) {
  final t = now ?? DateTime.now();
  final songs = lib.songs;
  Collection make(String key, String title, String what, List<Song> s) => Collection(
    kind: CollectionKind.playlist,
    key: 'smart:$key',
    title: title,
    subtitle: '$what · ${s.length} ${s.length == 1 ? 'song' : 'songs'}',
    songs: s,
    artAlbumId: s.isEmpty ? -1 : s.first.albumId,
  );
  int last(Song s) => p.lastPlayed(s.id)?.millisecondsSinceEpoch ?? 0;

  final recent = songs.where((s) => t.difference(s.added).inDays <= 30).toList()
    ..sort((a, b) => b.added.compareTo(a.added));
  final most = songs.where((s) => p.plays(s.id) > 0).toList()
    ..sort((a, b) => p.plays(b.id).compareTo(p.plays(a.id)));
  final never = songs.where((s) => p.plays(s.id) == 0).toList()..sort((a, b) => b.added.compareTo(a.added));
  final cutoff = t.subtract(const Duration(days: 180)).millisecondsSinceEpoch;
  final forgotten = songs.where((s) => p.plays(s.id) >= 2 && last(s) < cutoff).toList()
    ..sort((a, b) => p.plays(b.id).compareTo(p.plays(a.id)));
  final favCut = t.subtract(const Duration(days: 45)).millisecondsSinceEpoch;
  final favs = [
    for (final id in lists.favs.songIds)
      if (lib.byId[id] case final s? when last(s) < favCut) s,
  ];
  // A two hour mix, new each day: favourites and most played first, topped up.
  final day = t.year * 400 + t.month * 32 + t.day;
  final pool = {...lists.favs.songIds.map((id) => lib.byId[id]).whereType<Song>(), ...most.take(60)}.toList()
    ..shuffle(Random(day));
  final rest = [...songs]..shuffle(Random(day + 1));
  final trip = <Song>[];
  var total = Duration.zero;
  for (final s in [...pool, ...rest]) {
    if (total >= const Duration(hours: 2)) break;
    if (trip.contains(s)) continue;
    trip.add(s);
    total += s.duration;
  }

  return [
    if (trip.isNotEmpty) make('trip', 'Road trip mix', 'Two hours, new each day', trip),
    if (recent.isNotEmpty) make('recent', 'Recently added', 'Last 30 days', recent.take(150).toList()),
    if (most.isNotEmpty) make('most', 'Most played', 'Your top 50', most.take(50).toList()),
    if (favs.isNotEmpty) make('favs', 'Forgotten favourites', 'Not played in 6 weeks', favs),
    if (forgotten.isNotEmpty)
      make('forgotten', 'Not heard in a while', '6 months or more', forgotten.take(100).toList()),
    if (never.isNotEmpty) make('never', 'Never played', 'Newest first', never.take(200).toList()),
  ];
}

/// Songs that look like the same recording more than once (same title and
/// artist, lengths within 3 s), best copy first in each group.
List<List<Song>> findDuplicates(List<Song> songs, int Function(Song a, Song b) better) {
  String norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[\(\[][^\)\]]*(remaster|version|edit|mono|stereo|explicit)[^\)\]]*[\)\]]'), '')
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .trim();
  final byName = <String, List<Song>>{};
  for (final s in songs) {
    final t = norm(s.title);
    if (t.isEmpty) continue;
    (byName['$t|${norm(s.artist)}'] ??= []).add(s);
  }
  final out = <List<Song>>[];
  for (final g in byName.values) {
    if (g.length < 2) continue;
    g.sort((a, b) => a.duration.compareTo(b.duration));
    var run = <Song>[g.first];
    for (final s in g.skip(1)) {
      if ((s.duration - run.last.duration).inSeconds.abs() <= 3) {
        run.add(s);
      } else {
        if (run.length > 1) out.add(run);
        run = [s];
      }
    }
    if (run.length > 1) out.add(run);
  }
  for (final g in out) {
    g.sort(better);
  }
  return out;
}
