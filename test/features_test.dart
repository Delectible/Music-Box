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
import 'package:roadie/core/sorting.dart';
import 'package:roadie/core/visualizer.dart';
import 'package:roadie/screens/podcast_screen.dart';
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
    expect(lib.unfiltered.where((s) => !s.podcast).length, all);
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
    final r = await DirectLink(probe: null).search('https://example.org/music/Some%20Band%20-%20Song.flac');
    expect(r.single.single, isTrue);
    final t = (await DirectLink(probe: null).tracks(r.single)).single;
    expect(t.ext, 'flac');
    expect(t.title, 'Some Band - Song');
    expect(await DirectLink(probe: null).search('not a link'), isEmpty);
    // YouTube, web pages and other files are never "downloaded".
    expect(DirectLink(probe: null).search('https://youtu.be/abc'), throwsA(isA<UnsupportedLink>()));
    expect(
      DirectLink(
        probe: (_) async => const LinkInfo(LinkKind.page, 'text/html', null),
      ).search('https://e.org/album'),
      throwsA(isA<LinkIsPage>()),
    );
    expect(
      DirectLink(
        probe: (_) async => const LinkInfo(LinkKind.other, 'application/pdf', null),
      ).search('https://e.org/x'),
      throwsA(isA<UnsupportedLink>()),
    );
    final named = await DirectLink(
      probe: (_) async => const LinkInfo(LinkKind.music, 'audio/flac', 'Real Name.flac'),
    ).search('https://e.org/dl?id=7');
    expect(named.single.title, 'Real Name');
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

  test('Internet Archive: titles and artists that match come first', () {
    final docs = <Map<Object?, Object?>>[
      {'title': 'Concert Grande - Chopin Etudes', 'creator': 'Radio host', 'downloads': 90000},
      {
        'title': '24 Etudes',
        'creator': ['Alfred Cortot', 'Frédéric Chopin'],
        'downloads': 300,
        'collection': ['audio_music'],
      },
      {'title': 'Something else', 'creator': 'Nobody', 'downloads': 1000000},
    ];
    InternetArchive.rank(docs, 'chopin etudes cortot');
    expect(docs.first['title'], '24 Etudes');
    expect(docs.last['title'], 'Something else');
  });

  test('added sites: search address from an example search', () {
    expect(
      CustomSite.templateFrom('https://music.example/search?q=miles+davis&page=1', 'miles davis'),
      'https://music.example/search?q={q}&page=1',
    );
    expect(
      CustomSite.templateFrom('https://e.org/find/miles%20davis', 'miles davis'),
      'https://e.org/find/{q}',
    );
    const site = CustomSite(id: 'a', name: 'E', home: 'https://e.org', search: 'https://e.org/s?q={q}');
    expect(site.searchUri('a&b').toString(), 'https://e.org/s?q=a%26b');
    final back = CustomSite.decode(CustomSite.encode([site])).single;
    expect(back.search, site.search);
    expect(CustomSite.decode('not json'), isEmpty);
  });

  test('only real music is saved', () {
    expect(looksLikeAudio('ID3\x04\x00'.codeUnits, ''), isTrue);
    expect(looksLikeAudio('fLaC\x00\x00'.codeUnits, ''), isTrue);
    expect(looksLikeAudio([0, 0, 0, 0x20, ...'ftypM4A '.codeUnits], ''), isTrue);
    expect(looksLikeAudio([0xFF, 0xFB, 0x90, 0x64], 'application/octet-stream'), isTrue);
    expect(looksLikeAudio('<!DOCTYPE html><html>'.codeUnits, 'text/html'), isFalse);
    expect(looksLikeAudio('{"error":1}'.codeUnits, 'application/json'), isFalse);
    expect(looksLikeAudio('random bytes here'.codeUnits, 'application/octet-stream'), isFalse);
  });

  test('podcast feeds: episodes with show, author, number and cover', () {
    const rss = """<?xml version="1.0"?>
<rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>
  <title>Road Talk</title><itunes:author>Jo Host</itunes:author>
  <itunes:image href="https://e.org/show.jpg"/>
  <item><title>Ep 2: Maps</title><itunes:episode>2</itunes:episode><pubDate>Tue, 03 Mar 2026 10:00:00 GMT</pubDate>
    <enclosure url="https://e.org/ep2.mp3" type="audio/mpeg" length="1"/><itunes:duration>12:30</itunes:duration></item>
  <item><title>Trailer video</title><enclosure url="https://e.org/t.mp4" type="video/mp4"/></item>
  <item><title>Ep 1</title><enclosure url="https://e.org/ep1.m4a?x=1" type="audio/x-m4a"/></item>
</channel></rss>""";
    final (show, author, cover, eps) = Podcasts.parseFeed(rss);
    expect(show, 'Road Talk');
    expect(author, 'Jo Host');
    expect(cover, 'https://e.org/show.jpg');
    expect(eps.length, 2);
    expect(eps.first.track, 2);
    expect(eps.first.year, '2026');
    expect(eps.first.length, const Duration(minutes: 12, seconds: 30));
    expect(eps.first.album, 'Road Talk');
    expect(eps.first.lookUp, isFalse);
    expect(eps.last.ext, 'm4a');
  });

  test('podcasts: their own tab, out of the music, episodes in order', () async {
    SharedPreferences.setMockInitialValues({
      // Someone who saved their tabs before Podcasts existed still gets it.
      'tabs': ['albums', 'songs', 'get'],
    });
    final prefs = await SharedPreferences.getInstance();
    final s = Settings(prefs);
    expect(s.tabs, [LibraryTab.albums, LibraryTab.songs, LibraryTab.podcasts, LibraryTab.get]);
    s.tabs = [LibraryTab.albums, LibraryTab.songs, LibraryTab.get];
    expect(s.tabs.contains(LibraryTab.podcasts), isFalse); // switched off stays off
    final lib = Library(DemoSource(), s);
    await lib.load();
    expect(lib.songs.any((x) => x.podcast), isFalse);
    expect(lib.albums.any((a) => a.title == 'Road Talk'), isFalse);
    final show = lib.podcasts.single;
    expect(show.title, 'Road Talk');
    expect(show.subtitle, 'Jo Host · 5 episodes');
    expect(sortEpisodes(show.songs, 'newest').first.title, 'Last Exit');
    expect(sortEpisodes(show.songs, 'oldest').first.title, 'Maps and Shortcuts');
    expect(sortEpisodes(show.songs, 'title').first.title, 'Fuel Stops');
  });
}
