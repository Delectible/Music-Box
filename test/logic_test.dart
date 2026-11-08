import 'package:flutter_test/flutter_test.dart';
import 'package:roadie/core/library.dart';
import 'package:roadie/core/models.dart';
import 'package:roadie/core/player.dart';
import 'package:roadie/core/settings.dart';
import 'package:roadie/core/sorting.dart';
import 'package:roadie/core/source.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Library lib;
  late Player player;
  late SilentEngine engine;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    lib = Library(DemoSource(), Settings(prefs));
    await lib.load();
    engine = SilentEngine();
    player = Player(engine, prefs);
  });

  tearDown(() => engine.close());

  test('groups albums, artists and genres', () {
    expect(lib.albums.length, 10);
    expect(lib.artist('lumen coast')!.songs.length, 10);
    expect(lib.albumsBy('Mara Vell').length, 2);
    expect(lib.genres.map((g) => g.title), contains('Synthwave'));
  });

  test('sorts ignoring "The" and case', () {
    final sorted = sortCollections(lib.artists, SortKey.title, false, player);
    final names = sorted.map((a) => a.title).toList();
    expect(names.indexOf('The Wayfarers'), greaterThan(names.indexOf('Orbit Kids')));
    expect(names.indexOf('The Second Line'), greaterThan(names.indexOf('Sea of Glass')));
    final byLength = sortSongs(lib.songs, SortKey.duration, true, player);
    expect(byLength.first.duration >= byLength.last.duration, isTrue);
  });

  test('view options round trip', () {
    const v = ViewOptions(
      sort: SortKey.year,
      descending: true,
      mode: ViewMode.grid,
      columns: 4,
      headers: false,
    );
    final back = ViewOptions.decode(v.encode(), LibraryTab.albums);
    expect(back.sort, SortKey.year);
    expect(back.descending, isTrue);
    expect(back.mode, ViewMode.grid);
    expect(back.columns, 4);
    expect(back.headers, isFalse);
  });

  test('queue: shuffle keeps the song, unshuffle restores order', () async {
    final album = lib.albums.first.songs;
    await player.playAll(album, start: 2);
    expect(player.current, album[2]);
    await player.setShuffle(true);
    expect(player.current, album[2]);
    expect(player.index, 0);
    expect(player.queue.toSet(), album.toSet());
    await player.setShuffle(false);
    expect(player.queue, album);
    expect(player.index, 2);
  });

  test('queue: play next, move, remove', () async {
    final songs = lib.songs.take(4).toList();
    final extra = lib.songs[10];
    await player.playAll(songs);
    await player.playNext([extra]);
    expect(player.queue[1], extra);
    await player.move(1, 3);
    expect(player.queue[3], extra);
    await player.removeAt(3);
    expect(player.queue, songs);
  });

  test('counts a play past half way and restores the queue', () async {
    final songs = lib.songs.take(3).toList();
    await player.playAll(songs, start: 1);
    engine.advance(songs[1].duration * 0.6);
    await Future<void>.delayed(Duration.zero);
    expect(player.plays(songs[1].id), 1);

    final again = Player(SilentEngine(), prefs);
    await again.restore({for (final s in lib.songs) s.id: s}, autoplay: false);
    expect(again.queue.map((s) => s.id), songs.map((s) => s.id));
    expect(again.current, songs[1]);
  });

  test('MediaStore packs disc into the track number', () {
    final s = Song.fromMap({'id': 1, 'track': 2005, 'title': 'x', 'path': '/a/b.mp3'});
    expect(s.track, 5);
    expect(s.disc, 2);
    expect(s.artist, 'Unknown artist');
  });
}
