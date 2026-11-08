import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'dart:async';
import 'dart:io';

import 'package:roadie/core/downloads.dart';
import 'package:roadie/core/http.dart';
import 'package:roadie/core/library.dart';
import 'package:roadie/core/metadata.dart';
import 'package:roadie/core/settings.dart';
import 'package:roadie/core/source.dart';
import 'package:roadie/core/sources.dart';
import 'package:roadie/core/visualizer.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('guesses tags from file names and folders', () {
    var t = guessFromPath('/storage/emulated/0/Music/Lumen Coast/Night Drive/03 - Exit 42.mp3');
    expect(t.track, '3');
    expect(t.title, 'Exit 42');
    expect(t.album, 'Night Drive');
    expect(t.artist, 'Lumen Coast');
    t = guessFromPath('/storage/emulated/0/Download/Orbit Kids - Satellite Heart (Official Audio).flac');
    expect(t.artist, 'Orbit Kids');
    expect(t.title, 'Satellite Heart');
    expect(t.album, '');
  });

  test('tags fill only blanks', () {
    const a = TagValues(title: 'Mine', genre: '');
    const b = TagValues(title: 'Theirs', genre: 'Jazz', year: '2018');
    final c = a.fill(b);
    expect(c.title, 'Mine');
    expect(c.genre, 'Jazz');
    expect(c.year, '2018');
  });

  test('music folders: include and exclude', () {
    const p = '/storage/emulated/0/Music/Album/song.mp3';
    expect(folderAllowed(p, const [], const []), isTrue);
    expect(folderAllowed(p, const ['/storage/emulated/0/Music'], const []), isTrue);
    expect(folderAllowed(p, const ['/storage/emulated/0/Mus'], const []), isFalse);
    expect(folderAllowed(p, const [], const ['/storage/emulated/0/Music/Album']), isFalse);
    expect(
      folderAllowed(p, const ['/storage/emulated/0/Music'], const ['/storage/emulated/0/Music/Album']),
      isFalse,
    );
  });

  test('library applies the folder lists', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final s = Settings(prefs);
    final lib = Library(DemoSource(), s);
    await lib.load();
    final all = lib.songs.length;
    s.excludeFolders = ['/storage/emulated/0/Music/Lumen Coast'];
    expect(lib.songs.length, all - 10);
    s.includeFolders = ['/storage/emulated/0/Music/Mara Vell'];
    expect(lib.songs.every((x) => x.artist == 'Mara Vell'), isTrue);
    expect(lib.unfiltered.length, all);
  });

  test('download paths: Artist/Album/NN Title.ext, safe names', () {
    final t = RemoteTrack(
      title: 'What? / Why',
      artist: 'A:B',
      album: 'Live <1999>',
      track: 4,
      url: Uri.parse('https://example.org/x.flac'),
      ext: 'flac',
    );
    expect(Downloads.pathFor('/m', t), '/m/A_B/Live _1999_/04 What_ _ Why.flac');
    final single = RemoteTrack(title: 'Solo', url: Uri.parse('https://e.org/s.mp3'), ext: 'mp3');
    expect(Downloads.pathFor('/m', single), '/m/Unknown artist/Singles/Solo.mp3');
  });

  test('direct links become one track', () async {
    final r = await DirectLink().search('https://example.org/music/Some%20Band%20-%20Song.flac');
    expect(r.single.single, isTrue);
    final t = (await DirectLink().tracks(r.single)).single;
    expect(t.ext, 'flac');
    expect(t.title, 'Some Band - Song');
    expect(await DirectLink().search('not a link'), isEmpty);
  });

  test('visualiser: decodes Android FFT data', () {
    final f = VizFeed();
    // A loud low tone: the first bins big, the rest silent.
    final raw = Int8List(1024);
    for (var k = 1; k < 6; k++) {
      raw[2 * k] = 100;
      raw[2 * k + 1] = 40;
    }
    f.handle({'fft': Uint8List.sublistView(raw)});
    for (var i = 0; i < 20; i++) {
      f.tick(1 / 60);
    }
    expect(f.live, isTrue);
    expect(f.bands[2], greaterThan(0.5));
    expect(f.bands[60], lessThan(0.05));
  });

  test('visualiser: made-up feed follows play / pause', () {
    final f = VizFeed()..playing = true;
    for (var i = 0; i < 60; i++) {
      f.tick(1 / 60);
    }
    expect(f.level, greaterThan(0.05));
    expect(f.bands.first, greaterThan(f.bands.last));
    expect(f.history, isNotEmpty);
    f.playing = false;
    for (var i = 0; i < 120; i++) {
      f.tick(1 / 60);
    }
    expect(f.level, lessThan(0.05));
  });

  test('network errors: plain words, and which are worth retrying', () {
    const dns = SocketException(
      "Failed host lookup: 'archive.org'",
      osError: OSError('No address associated with hostname', 7),
    );
    expect(friendlyError(dns), 'No internet connection');
    expect(isNetworkError(dns), isTrue);
    expect(
      friendlyError(const HttpException('Connection closed while receiving data')),
      'The connection dropped',
    );
    expect(isNetworkError(TimeoutException('x')), isTrue);
    expect(isNetworkError(HttpFailure('busy', 503)), isTrue);
    expect(isNetworkError(HttpFailure('missing', 404)), isFalse);
  });
}
