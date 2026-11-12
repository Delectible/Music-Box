import 'dart:convert';

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'dart:async';
import 'dart:io';

import 'package:roadie/core/downloads.dart';
import 'package:roadie/core/http.dart';
import 'package:roadie/core/library.dart';
import 'package:roadie/core/metadata.dart';
import 'package:roadie/core/models.dart';
import 'package:roadie/core/settings.dart';
import 'package:roadie/core/source.dart';
import 'package:roadie/core/sources.dart';
import 'package:roadie/core/sorting.dart';
import 'package:roadie/core/lyrics.dart';
import 'package:roadie/core/player.dart';
import 'package:roadie/core/playlists.dart';
import 'package:roadie/core/quality.dart';
import 'package:roadie/core/smart.dart';
import 'package:roadie/core/visualizer.dart';
import 'package:roadie/core/matcher.dart';
import 'package:roadie/core/ytdlp.dart';
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

  test('lyrics: LRC lines in time order, the line playing now', () {
    final l = Lyrics(
      lines: Lyrics.parseLrc('[ar:x]\n[00:12.50]Second\n[00:05.00][01:00.00]First and again\n[00:20]Third'),
      source: 't',
    );
    expect(l.lines.map((x) => x.text).toList(), ['First and again', 'Second', 'Third', 'First and again']);
    expect(l.lineAt(const Duration(seconds: 2)), -1);
    expect(l.lineAt(const Duration(seconds: 13)), 1);
    expect(l.lineAt(const Duration(minutes: 2)), 3);
  });

  test('quality badge text', () {
    final hi = Quality.from({
      'format': 'FLAC 24 bits',
      'sampleRate': '96000',
      'bitsPerSample': 24,
      'lossless': true,
    }, 'a.flac')!;
    expect(hi.label, 'FLAC 24-bit · 96 kHz');
    expect(hi.hiRes, isTrue);
    final cd = Quality.from({
      'format': 'FLAC 16 bits',
      'sampleRate': '44100',
      'bitsPerSample': 16,
      'lossless': true,
    }, 'a.flac')!;
    expect(cd.label, 'FLAC 16-bit · 44.1 kHz');
    expect(cd.hiRes, isFalse);
    final mp3 = Quality.from({'format': 'MPEG-1 Layer 3', 'bitRate': '320', 'sampleRate': '44100'}, 'a.mp3')!;
    expect(mp3.label, 'MP3 320 kbps');
  });

  test('day and night', () async {
    SharedPreferences.setMockInitialValues({});
    final s = Settings(await SharedPreferences.getInstance());
    expect(s.isNight(DateTime(2026, 1, 1, 12)), isFalse);
    expect(s.isNight(DateTime(2026, 1, 1, 21)), isTrue);
    expect(s.isNight(DateTime(2026, 1, 1, 5)), isTrue);
  });

  test('smart playlists and duplicates', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final lib = Library(DemoSource(), Settings(prefs));
    await lib.load();
    final engine = SilentEngine();
    final p = Player(engine, prefs);
    final lists = Playlists(prefs);
    final smart = smartPlaylists(lib, p, lists, now: DateTime(2025, 11, 1));
    final trip = smart.firstWhere((c) => c.key == 'smart:trip');
    expect(trip.duration, greaterThanOrEqualTo(const Duration(hours: 2)));
    expect(smart.any((c) => c.key == 'smart:never'), isTrue);
    expect(smart.any((c) => c.key == 'smart:most'), isFalse); // nothing played yet
    final a = lib.songs.first;
    final copy = Song(
      id: 999,
      uri: '/x/copy.flac',
      path: '/x/copy.flac',
      title: '${a.title} (2019 Remaster)',
      artist: a.artist.toUpperCase(),
      album: 'Best Of',
      albumArtist: a.artist,
      albumId: 50,
      genre: a.genre,
      year: 2019,
      track: 1,
      disc: 1,
      duration: a.duration + const Duration(seconds: 2),
      added: a.added,
      modified: a.modified,
      size: a.size * 4,
    );
    final d = findDuplicates([...lib.songs, copy], (x, y) => y.size.compareTo(x.size));
    expect(d.length, 1);
    expect(d.single.first.id, 999); // the bigger copy first
    engine.close();
  });

  test('podcasts: carry on where you left off, played at 90%', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final lib = Library(DemoSource(), Settings(prefs));
    await lib.load();
    final engine = SilentEngine();
    final p = Player(engine, prefs);
    final eps = lib.podcasts.single.songs;
    await p.playAll(eps, start: 0);
    engine.advance(const Duration(minutes: 7));
    await Future<void>.delayed(Duration.zero);
    expect(p.resumeAt(eps.first.id), const Duration(minutes: 7));
    expect(p.isPlayed(eps.first.id), isFalse);
    engine.advance(eps.first.duration * 0.95);
    await Future<void>.delayed(Duration.zero);
    expect(p.isPlayed(eps.first.id), isTrue);
    expect(p.resumeAt(eps.first.id), isNull);
    // Remembered across restarts.
    final again = Player(SilentEngine(), prefs);
    expect(again.isPlayed(eps.first.id), isTrue);
    engine.close();
  });

  test('yt-dlp errors: what an update can fix, in plain words', () {
    const clientId = 'ERROR: [soundcloud] Unable to extract client id; please report this issue';
    expect(Ytdlp.looksBroken(clientId), isTrue);
    expect(Ytdlp.looksBroken('ERROR: [soundcloud] 123: HTTP Error 404: Not Found'), isFalse);
    expect(
      Ytdlp.looksBroken('ERROR: <urlopen error [Errno 7] No address associated with hostname>'),
      isFalse,
    );
    expect(
      Ytdlp.friendly('ERROR: [soundcloud] 1: Requested format is not available'),
      contains('30-second preview'),
    );
    expect(Ytdlp.friendly('ERROR: [soundcloud] 1: HTTP Error 404: Not Found'), contains('removed'));
    expect(Ytdlp.friendly('ERROR: <urlopen error timed out>'), contains('internet'));
  });

  test('SoundCloud: tracks from yt-dlp details, never Go+ previews', () {
    final sc = SoundCloud();
    expect(sc.format, startsWith('download/'));
    expect(sc.format, contains('[format_id!*=preview]'));
    expect(SoundCloud(original: false).format.startsWith('download'), isFalse);
    final t = sc.trackOf({
      'title': 'Lumen Coast - Exit 42 (Official Audio)',
      'uploader': 'nightlabel',
      'webpage_url': 'https://soundcloud.com/nightlabel/exit-42',
      'duration': 201.5,
      'upload_date': '20240312',
      'genre': 'Synthwave',
      'thumbnails': [
        {'id': 'large', 'url': 'https://i1.sndcdn.com/a-large.jpg', 'width': 100},
        {'id': 't500x500', 'url': 'https://i1.sndcdn.com/a-t500x500.jpg', 'width': 500},
      ],
    });
    expect(t.artist, 'Lumen Coast');
    expect(t.title, startsWith('Exit 42'));
    expect(t.year, '2024');
    expect(t.genre, 'Synthwave');
    expect(t.cover, contains('t500x500'));
    expect(t.viaYtdlp, isTrue);
    expect(SoundCloud.isLink(Uri.parse('https://on.soundcloud.com/abc')), isTrue);
    expect(SoundCloud.isLink(Uri.parse('https://example.com/x')), isFalse);
  });

  test('Matcher: picks the real song, not remixes, previews or other songs', () {
    double sc(String t, String up, int secs) => SongMatcher.score(
      title: 'Night Drive (feat. Ava Lane)',
      artist: 'Lumen Coast, Ava Lane',
      length: const Duration(seconds: 214),
      candTitle: t,
      candUploader: up,
      candLength: Duration(seconds: secs),
    );
    final real = sc('Night Drive (feat. Ava Lane)', 'Lumen Coast', 213);
    final reup = sc('Lumen Coast - Night Drive', 'some fan', 215);
    expect(real, greaterThanOrEqualTo(SongMatcher.threshold));
    expect(reup, greaterThanOrEqualTo(SongMatcher.threshold));
    expect(sc('Night Drive (Remix)', 'Lumen Coast', 240), lessThan(SongMatcher.threshold));
    expect(sc('Night Drive', 'Lumen Coast', 30), lessThan(SongMatcher.threshold)); // Go+ clip
    expect(sc('Night Drive (sped up)', 'Lumen Coast', 170), lessThan(SongMatcher.threshold));
    expect(sc('Daylight', 'Lumen Coast', 214), 0);
    expect(sc('Night Drive', 'Other Band', 330), lessThan(SongMatcher.threshold));
    expect(real, greaterThan(sc('Night Drive', 'Other Band', 214)));
    // A remix is fine when that's the song asked for.
    expect(
      SongMatcher.score(
        title: 'Night Drive (Remix)',
        artist: 'Lumen Coast',
        length: const Duration(seconds: 240),
        candTitle: 'Lumen Coast - Night Drive (Remix)',
        candUploader: 'x',
        candLength: const Duration(seconds: 241),
      ),
      greaterThanOrEqualTo(SongMatcher.threshold),
    );
    expect(SongMatcher.coreTitle('Song - Remastered 2011'), 'Song');
    expect(SongMatcher.artistsOf('A, B & C feat. D'), ['A', 'B', 'C', 'D']);
  });

  test('Spotify: song details from an embed page, songs found on SoundCloud', () {
    final entity = {
      'type': 'album',
      'name': 'Coastlines',
      'subtitle': 'Lumen Coast',
      'releaseDate': {'isoString': '2021-05-01T00:00:00Z'},
      'trackList': [
        {
          'uri': 'spotify:track:1111111111111111111111',
          'title': 'Night Drive',
          'subtitle': 'Lumen Coast, Ava Lane',
          'duration': 214000,
        },
        {
          'uri': 'spotify:track:2222222222222222222222',
          'title': 'Gone',
          'subtitle': 'Lumen Coast',
          'duration': 180000,
          'isPlayable': false,
        },
        {
          'uri': 'spotify:track:3333333333333333333333',
          'title': 'Harbour',
          'subtitle': 'Lumen Coast',
          'duration': 200000,
        },
      ],
      'visualIdentity': {
        'image': [
          {'url': 'https://image-cdn.example/image/ab67616d00004851abc', 'maxWidth': 64},
          {'url': 'https://image-cdn.example/image/ab67616d00001e02abc', 'maxWidth': 300},
        ],
      },
    };
    final page =
        '<script id="__NEXT_DATA__" type="application/json">${jsonEncode({
          'props': {
            'pageProps': {
              'state': {
                'data': {'entity': entity},
              },
            },
          },
        })}</script>';
    final item = Spotify.itemOf('album', 'x', page);
    expect(item.title, 'Coastlines');
    expect(item.cover, endsWith('ab67616d0000b273abc'));
    final list = (item.data! as List).cast<RemoteTrack>();
    expect(list.length, 2); // not the unplayable one
    expect(list.first.artist, 'Lumen Coast, Ava Lane');
    expect(list.first.album, 'Coastlines');
    expect(list.first.year, '2021');
    expect(list.first.track, 1);
    expect(list.first.length, const Duration(seconds: 214));
    expect(list.first.findOnSoundCloud, isTrue);
    expect(list.first.url.toString(), 'https://open.spotify.com/track/1111111111111111111111');
    expect(Spotify.isLink(Uri.parse('https://open.spotify.com/intl-de/playlist/abc')), isTrue);
    expect(() => Spotify.itemOf('track', 'x', '<html></html>'), throwsA(isA<UnsupportedLink>()));
  });

  test('slow connections: speed from yt-dlp, wrong clock, close matches', () {
    expect(
      Ytdlp.speedOf('[download]  45.2% of ~  3.20MiB at  120.00KiB/s ETA 00:15 (frag 3/40)'),
      120 * 1024,
    );
    expect(Ytdlp.speedOf('[download]  12.0% of 5.1MiB at 1.50MiB/s ETA 00:03'), 1.5 * 1024 * 1024);
    expect(Ytdlp.speedOf('[download] Destination: x.mp3'), isNull);
    expect(
      Ytdlp.friendly('ERROR: <urlopen error [SSL: CERTIFICATE_VERIFY_FAILED] certificate is not yet valid>'),
      Ytdlp.badClock,
    );
    expect(Ytdlp.looksBroken('certificate verify failed: certificate is not yet valid'), isFalse);
    expect(YtdlpFailure(Ytdlp.friendly('ERROR: Read timed out.'), '').network, isTrue);
    // A cover with the right length: not good enough to take, close enough to ask.
    final cover = SongMatcher.score(
      title: 'Coming Home',
      artist: 'Lumen Coast',
      length: const Duration(seconds: 249),
      candTitle: 'Coming Home - Lumen Coast (Cover)',
      candUploader: 'someone sings',
      candLength: const Duration(seconds: 249),
    );
    expect(cover, lessThan(SongMatcher.threshold));
    expect(cover, greaterThanOrEqualTo(SongMatcher.closeFrom));
  });

  test('yt-dlp: offline and blocked networks are not "SoundCloud changed"', () {
    const refused =
        "ERROR: x: Unable to download API page: ('Unable to connect to proxy', NewConnectionError(\"Failed to establish a new connection: [Errno 111] Connection refused\")); please report this issue on https://github.com/yt-dlp/yt-dlp/issues";
    const dns =
        "ERROR: [soundcloud] Unable to download webpage: Failed to resolve 'soundcloud.com' ([Errno 7] No address associated with hostname); please report this issue";
    const portal =
        'ERROR: x: Unable to download API page: [SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed: self-signed certificate in certificate chain (_ssl.c:1035); please report this issue';
    for (final e in [refused, dns, portal]) {
      expect(Ytdlp.looksBroken(e), isFalse, reason: e);
    }
    expect(Ytdlp.friendly(refused), Ytdlp.noInternet);
    expect(Ytdlp.friendly(dns), Ytdlp.noInternet);
    expect(Ytdlp.friendly(portal), Ytdlp.blockedNetwork);
    // A real site change still heals.
    expect(
      Ytdlp.looksBroken('ERROR: [soundcloud] Unable to extract client id; please report this issue'),
      isTrue,
    );
  });

  test('yt-dlp: DRM / Go+ uploads look elsewhere; plugin is well-formed', () {
    final drm = Ytdlp.friendly('ERROR: [soundcloud] 1195313011: This video is DRM protected');
    expect(drm, Ytdlp.drm);
    expect(YtdlpFailure(drm, '').unavailable, isTrue);
    final goPlus = Ytdlp.friendly('ERROR: [soundcloud] 257041362: Requested format is not available.');
    expect(YtdlpFailure(goPlus, '').unavailable, isTrue);
    expect(YtdlpFailure(Ytdlp.noInternet, '').unavailable, isFalse);
    expect(Ytdlp.looksBroken('ERROR: [soundcloud] 1: This video is DRM protected'), isFalse);
    expect(Ytdlp.plugin, contains("plugin_name='roadie'"));
    expect(Ytdlp.plugin, contains("'Checking thumbnail extension'"));
  });
}
