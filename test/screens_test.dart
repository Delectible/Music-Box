import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roadie/screens/close_matches_screen.dart';
import 'package:roadie/screens/get_music_screen.dart' show openDownloads;
import 'package:roadie/core/sources.dart';
import 'package:roadie/core/scope.dart';
import 'package:roadie/core/matcher.dart';
import 'package:roadie/core/downloads.dart';
import 'package:roadie/app.dart';
import 'package:roadie/core/library.dart';
import 'package:roadie/core/player.dart';
import 'package:roadie/core/playlists.dart';
import 'package:roadie/core/settings.dart';
import 'package:roadie/core/sorting.dart';
import 'package:roadie/core/source.dart';
import 'package:roadie/core/visualizer.dart';
import 'package:roadie/core/lyrics.dart';
import 'package:roadie/core/quality.dart';
import 'package:roadie/screens/file_actions.dart';
import 'package:roadie/screens/folders_screen.dart';
import 'package:roadie/screens/sources_screen.dart';
import 'package:roadie/screens/song_info_screen.dart';
import 'package:roadie/screens/visualizer_screen.dart';
import 'package:roadie/screens/library_view.dart';
import 'package:roadie/screens/settings_screen.dart';
import 'package:roadie/widgets/menus.dart' show openCollection;
import 'package:shared_preferences/shared_preferences.dart';

import 'shots.dart';

class _App {
  final Settings settings;
  final Library library;
  final Player player;
  final Playlists playlists;
  final SilentEngine engine;
  _App(this.settings, this.library, this.player, this.playlists, this.engine);

  Widget get widget => RoadieApp(settings: settings, library: library, player: player, playlists: playlists);
}

Future<_App> _app(Map<String, Object> prefs) async {
  SharedPreferences.setMockInitialValues(prefs);
  final p = await SharedPreferences.getInstance();
  final settings = Settings(p);
  final engine = SilentEngine();
  final player = Player(engine, p);
  final library = Library(DemoSource(), settings);
  await library.load();
  final playlists = Playlists(p);
  playlists.add(playlists.create('Road trip'), library.songs.take(12).toList());
  playlists.add(playlists.create('Morning commute'), library.songs.skip(20).take(9).toList());
  playlists.add(playlists.favs, library.songs.skip(5).take(7).toList());
  return _App(settings, library, player, playlists, engine);
}

Future<void> _settle(WidgetTester tester, [int ms = 1200]) async {
  for (var i = 0; i < ms ~/ 100; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _tab(WidgetTester tester, String label) async {
  await tester.tap(find.text(label).first);
  await _settle(tester, 600);
}

void main() {
  setUpAll(loadFonts);

  testWidgets('library on the car screen', (tester) async {
    setScreen(tester, car);
    final a = await _app({});
    await tester.pumpWidget(a.widget);
    await _settle(tester);
    expect(find.text('Shuffle all'), findsOneWidget);
    await shot(tester, 'car_1_songs');

    await a.player.playAll(a.library.albums[0].songs, start: 1);
    a.engine.advance(const Duration(seconds: 74));
    await _settle(tester);
    await _tab(tester, 'Albums');
    await shot(tester, 'car_2_albums');
    await _tab(tester, 'Artists');
    await shot(tester, 'car_3_artists');
    await _tab(tester, 'Genres');
    await shot(tester, 'car_4_genres');
    await _tab(tester, 'Playlists');
    await shot(tester, 'car_5_playlists');

    // An album.
    await _tab(tester, 'Albums');
    await tester.tap(find.text('Night Drive').first);
    await _settle(tester);
    await shot(tester, 'car_6_album');
    await tester.pageBack();
    await _settle(tester);

    // Sort and view options.
    await tester.tap(find.byTooltip('Sort and view'));
    await _settle(tester);
    await shot(tester, 'car_7_view_options');
    await tester.tapAt(const Offset(20, 20));
    await _settle(tester);
    a.engine.close();
  });

  for (final style in PlayerStyle.values) {
    testWidgets('full screen player: ${style.name}', (tester) async {
      setScreen(tester, car);
      final a = await _app({'playerStyle': style.name});
      await tester.pumpWidget(a.widget);
      await _settle(tester);
      await a.player.playAll(a.library.albums[0].songs, start: 3);
      a.engine.advance(const Duration(seconds: 96));
      await _settle(tester);
      PlayerSheet.open(tester.element(find.byType(Scaffold).first));
      await _settle(tester);
      expect(find.text('Coastline at 2am'), findsWidgets);
      await shot(tester, 'car_player_${style.name}');

      // A swipe from the screen edge is the phone's back gesture: no skip.
      await tester.flingFrom(const Offset(8, 300), const Offset(400, 0), 2000);
      await _settle(tester);
      expect(a.player.current!.title, 'Coastline at 2am');
      // Swipe to skip.
      await tester.flingFrom(const Offset(640, 300), const Offset(-400, 0), 2000);
      await _settle(tester);
      expect(a.player.current!.title, 'Cruise Control');
      a.engine.close();
    });
  }

  testWidgets('phone', (tester) async {
    setScreen(tester, phone);
    final a = await _app({'theme': ThemeChoice.light.name});
    await tester.pumpWidget(a.widget);
    await _settle(tester);
    await a.player.playAll(a.library.albums[3].songs, start: 0);
    await _settle(tester);
    await _tab(tester, 'Albums');
    await shot(tester, 'phone_1_albums');
    PlayerSheet.open(tester.element(find.byType(Scaffold).first));
    await _settle(tester);
    await shot(tester, 'phone_2_player');
    a.engine.close();
  });

  testWidgets('settings', (tester) async {
    setScreen(tester, car);
    final a = await _app({'view.${LibraryTab.songs.name}': 'title|0|compact|0|1'});
    await tester.pumpWidget(a.widget);
    await _settle(tester);
    await tester.tap(find.byTooltip('Settings'));
    await _settle(tester);
    await shot(tester, 'car_8_settings');
    a.engine.close();
  });

  testWidgets('visualisers', (tester) async {
    setScreen(tester, car);
    final a = await _app({});
    await tester.pumpWidget(a.widget);
    await _settle(tester);
    await a.player.playAll(a.library.albums[0].songs, start: 2);
    await _settle(tester);
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => const VisualizerScreen(simulated: true))));
    await _settle(tester);
    for (final v in VizStyle.values) {
      a.settings.visualizer = v.name;
      // Let the controls hide and the feed get going.
      await _settle(tester, 4600);
      await shot(tester, 'car_viz_${v.index + 1}_${v.name}');
    }
    // Styles cross-fade: halfway through, both are on screen.
    a.settings.visualizer = VizStyle.bars.name;
    await _settle(tester, 1000);
    a.settings.visualizer = VizStyle.scope.name;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await shot(tester, 'car_viz_fade');
    await _settle(tester, 800);
    a.settings.visualizer = VizStyle.waterfall.name;
    await _settle(tester);
    // Swipe to the next style.
    await tester.flingFrom(const Offset(900, 360), const Offset(-500, 0), 2000);
    await _settle(tester);
    expect(a.settings.visualizer, VizStyle.bars.name);
    nav.pop();
    await _settle(tester);
    a.engine.close();
  });

  testWidgets('get music and music folders', (tester) async {
    setScreen(tester, car);
    final a = await _app({
      'excludeFolders': ['/storage/emulated/0/Music/Hollow Pines'],
      'customSites': '[{"id":"site-1","name":"Free Tunes","home":"https://free.example","search":""}]',
      'sources': ['archive', 'ccmixter', 'site-1'],
    });
    await tester.pumpWidget(a.widget);
    await _settle(tester);
    await _tab(tester, 'Get music');
    expect(find.text('Internet Archive'), findsOneWidget);
    expect(find.text('Free Tunes'), findsOneWidget);
    expect(find.textContaining('Searching 3 sources'), findsOneWidget);
    expect(find.text('Browse Free Tunes'), findsOneWidget);
    await shot(tester, 'car_9_get_music');
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => const MusicFoldersScreen())));
    await _settle(tester);
    expect(find.textContaining('Hollow Pines'), findsOneWidget);
    await shot(tester, 'car_10_folders');
    a.engine.close();
  });

  testWidgets('song info', (tester) async {
    setScreen(tester, car);
    final a = await _app({});
    final song = a.library.albums[0].songs[2];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('roadie/library'),
      (call) async => call.method != 'fileInfo'
          ? null
          : {
              'exists': true,
              'bytes': 31457280,
              'modified': DateTime(2025, 3, 4, 21, 15).millisecondsSinceEpoch,
              'canWrite': true,
              'root': '/storage/emulated/0',
              'removable': false,
              'volumeFree': 41 * 1024 * 1024 * 1024,
              'volumeTotal': 128 * 1024 * 1024 * 1024,
              'mediaStore': {
                '_id': '${song.id}',
                'mime_type': 'audio/flac',
                'volume_name': 'external_primary',
              },
              'tags': {
                'format': 'FLAC 16 bits',
                'encoding': 'FLAC 16 bits',
                'bitRate': '1011',
                'variableBitRate': true,
                'sampleRate': '44100',
                'channels': '2',
                'bitsPerSample': 16,
                'lossless': true,
                'durationMs': song.duration.inMilliseconds + 412,
                'tagType': 'FlacTag',
                'fields': [
                  ['TITLE', song.title],
                  ['ARTIST', song.artist],
                  ['ALBUM', song.album],
                  ['DATE', '${song.year}'],
                  ['TRACKNUMBER', '${song.track}'],
                  ['GENRE', song.genre],
                  ['MUSICBRAINZ_TRACKID', '5b11f4ce-a62d-471e-81fc-a69a8278c7da'],
                ],
                'coverMime': 'image/jpeg',
                'coverBytes': 84211,
                'coverWidth': 500,
                'coverHeight': 500,
              },
            },
    );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('roadie/library'),
        null,
      ),
    );
    await tester.pumpWidget(a.widget);
    await _settle(tester);
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => SongInfoScreen(song: song))));
    await _settle(tester);
    expect(find.text('Lossless'), findsWidgets);
    expect(find.textContaining('Internal storage'), findsOneWidget);
    await shot(tester, 'car_11_song_info');
    a.engine.close();
  });

  testWidgets('opening the record player: cover flies onto the label', (tester) async {
    setScreen(tester, phone);
    final a = await _app({'playerStyle': PlayerStyle.record.name});
    await tester.pumpWidget(a.widget);
    await _settle(tester);
    await a.player.playAll(a.library.albums[1].songs, start: 0);
    await _settle(tester);
    await tester.tap(find.text(a.player.current!.title).last);
    for (final ms in [80, 160, 260]) {
      await tester.pump(Duration(milliseconds: ms == 80 ? 80 : (ms == 160 ? 80 : 100)));
      await shot(tester, 'phone_open_${ms}ms');
    }
    await _settle(tester);
    await shot(tester, 'phone_open_done');
    a.engine.close();
  });

  testWidgets('podcasts', (tester) async {
    setScreen(tester, car);
    final a = await _app({});
    await tester.pumpWidget(a.widget);
    await _settle(tester);
    await _tab(tester, 'Podcasts');
    expect(find.text('Road Talk'), findsOneWidget);
    await shot(tester, 'car_12_podcasts');
    await tester.tap(find.text('Road Talk'));
    await _settle(tester);
    expect(find.text('Last Exit'), findsOneWidget);
    await shot(tester, 'car_13_podcast_show');
    a.engine.close();
  });

  testWidgets('player extras: quality badge, lyrics, smart playlists', (tester) async {
    setScreen(tester, car);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('roadie/library'),
      (call) async => call.method == 'readTags'
          ? {'format': 'FLAC 24 bits', 'sampleRate': '96000', 'bitsPerSample': 24, 'lossless': true}
          : null,
    );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('roadie/library'),
        null,
      ),
    );
    Quality.clearCache();
    final a = await _app({'playerStyle': PlayerStyle.cover.name});
    final song = a.library.albums[0].songs[3];
    Lyrics.preload(
      song.id,
      Lyrics(
        lines: Lyrics.parseLrc(
          '[00:00.00]Headlights on the water\n[00:20.00]The radio low and warm\n'
          '[00:40.00]Every exit sign a promise\n[01:00.00]Coastline at 2am\n'
          '[01:20.00]We drive until the morning\n[01:40.00]Nothing left to say',
        ),
        source: 'LRCLIB',
      ),
    );
    await tester.pumpWidget(a.widget);
    await _settle(tester);
    await _tab(tester, 'Playlists');
    expect(find.text('Smart playlists'), findsOneWidget);
    await shot(tester, 'car_14_playlists_smart');
    await a.player.playAll(a.library.albums[0].songs, start: 3);
    a.engine.advance(const Duration(seconds: 66));
    await _settle(tester);
    PlayerSheet.open(tester.element(find.byType(Scaffold).first));
    await _settle(tester, 2000);
    expect(find.textContaining('Hi-Res FLAC 24-bit'), findsOneWidget);
    await shot(tester, 'car_player_badge');
    await tester.tap(find.byTooltip('Lyrics'));
    await _settle(tester, 1500);
    expect(find.text('Coastline at 2am'), findsWidgets);
    await shot(tester, 'car_15_lyrics');
    a.engine.close();
  });

  testWidgets('sources manager and tag editing', (tester) async {
    setScreen(tester, car);
    final a = await _app({
      'sourceOrder': ['youtube', 'archive', 'podcasts', 'link'],
    });
    await tester.pumpWidget(a.widget);
    await _settle(tester);
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => const SourcesScreen())));
    await _settle(tester);
    expect(find.text('YouTube'), findsOneWidget);
    // Added in a later version: SoundCloud goes first for people with a saved order.
    expect(a.settings.sourceOrder.first, 'soundcloud');
    await shot(tester, 'car_16_sources');
    // Removed built-ins can be added back.
    await tester.tap(find.text('Add a source'));
    await _settle(tester);
    expect(find.text('Add back Jamendo'), findsOneWidget);
    await tester.tap(find.text('Add back Jamendo'));
    await _settle(tester);
    expect(a.settings.sourceOrder.last, 'jamendo');
    // Remove one.
    await tester.tap(find.byTooltip('Remove').first);
    await _settle(tester);
    expect(a.settings.sourceOrder.contains('soundcloud'), isFalse);
    expect(a.settings.sourceOrder.first, 'youtube'); // and it stays removed
    nav.pop();
    await _settle(tester);
    // Bulk tag editing for an album (reading tags answers "nothing extra").
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('roadie/library'),
      (call) async => call.method == 'readTags' ? <String, Object?>{} : null,
    );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('roadie/library'),
        null,
      ),
    );
    final album = a.library.albums[0];
    final ctx = tester.element(find.byType(Scaffold).first);
    unawaited(editTags(ctx, album.songs, what: album.title));
    await _settle(tester);
    expect(find.text('Edit tags · 6 songs'), findsOneWidget);
    await shot(tester, 'car_17_edit_tags');
    a.engine.close();
  });

  testWidgets('close matches: wanted vs found, allow and disallow', (tester) async {
    for (final size in [car, phone]) {
      setScreen(tester, size);
      final a = await _app({});
      await tester.pumpWidget(a.widget);
      await _settle(tester);
      final ctx = tester.element(find.byType(Navigator).first);
      final d = AppScope.of(ctx).downloads;
      RemoteTrack want(String t, int secs) => RemoteTrack(
        title: t,
        artist: 'Lumen Coast',
        album: 'Coastlines',
        url: Uri.parse('https://open.spotify.com/track/x$t'),
        ext: 'mp3',
        length: Duration(seconds: secs),
        findOnSoundCloud: true,
        viaYtdlp: true,
      );
      final jobs = [
        reviewJob(
          want('Night Drive', 214),
          Found(
            Uri.parse('https://soundcloud.com/a/b'),
            'Night Drive (Live at the Pier)',
            'coastfan',
            const Duration(seconds: 251),
            null,
            0.45,
          ),
        ),
        reviewJob(
          want('Harbour', 200),
          Found(
            Uri.parse('https://soundcloud.com/a/c'),
            'Lumen Coast - Harbour (Cover)',
            'someone',
            const Duration(seconds: 199),
            null,
            0.5,
          ),
        ),
        reviewJob(
          want('Gone', 180),
          Found(
            Uri.parse('https://soundcloud.com/a/d'),
            'Gone (Extended Mix)',
            'Lumen Coast',
            const Duration(seconds: 302),
            null,
            0.33,
          ),
        ),
      ];
      d.jobs.addAll(jobs);
      openCloseMatches(ctx);
      await _settle(tester);
      expect(find.text('You wanted'), findsWidgets);
      await shot(tester, size == car ? 'car_17_close_matches' : 'phone_close_matches');
      // Its preview is playing: deciding ends it.
      final pv = AppScope.of(ctx).preview..current = Uri.parse('https://soundcloud.com/a/b');
      await tester.tap(find.text('Disallow').first);
      await _settle(tester);
      expect(pv.current, isNull);
      expect(jobs[0].state, JobState.failed);
      expect(jobs[0].error, 'Close match not kept');
      await tester.tap(find.text('Allow all'));
      await _settle(tester);
      expect(jobs[1].forced, Uri.parse('https://soundcloud.com/a/c'));
      expect(d.toReview, isEmpty);
      expect(find.text('Nothing left to check'), findsOneWidget);
      for (final j in jobs) {
        j.cancelled = true;
      }
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('downloads: needs you, downloading, didn\'t work, done', (tester) async {
    for (final size in [car, phone]) {
      setScreen(tester, size);
      final a = await _app({});
      await tester.pumpWidget(a.widget);
      await _settle(tester);
      final ctx = tester.element(find.byType(Navigator).first);
      final d = AppScope.of(ctx).downloads;
      RemoteTrack t(String title) =>
          RemoteTrack(title: title, artist: 'Lumen Coast', url: Uri.parse('https://x/$title'), ext: 'mp3');
      DownloadJob job(String title, JobState s, {String? error, double p = 0}) => DownloadJob(t(title))
        ..state = s
        ..error = error
        ..progress = p;
      d.jobs.addAll([
        job('Harbour', JobState.done),
        job('Gone', JobState.failed, error: 'Not found on SoundCloud'),
        job('Coastlines', JobState.downloading, p: 0.42),
        job('Tide', JobState.queued),
        job('Daylight', JobState.skipped, error: 'Already downloaded'),
        reviewJob(
          t('Night Drive'),
          Found(Uri.parse('https://soundcloud.com/a/b'), 'Night Drive (Live)', 'fan', null, null, 0.4),
        ),
      ]);
      openDownloads(ctx);
      await _settle(tester);
      await shot(tester, size == car ? 'car_18_downloads' : 'phone_downloads');
      final y = {
        for (final w in ['Needs you (1)', 'Downloading (2)', 'Didn\'t work (1)', 'Done (2)'])
          w: tester.getTopLeft(find.text(w)).dy,
      };
      expect(y['Needs you (1)']! < y['Downloading (2)']!, isTrue);
      expect(y['Downloading (2)']! < y['Didn\'t work (1)']!, isTrue);
      await tester.tap(find.text('Clear finished'));
      await tester.pump();
      expect(d.jobs.where((j) => j.state == JobState.review).length, 1); // kept
      for (final j in d.jobs) {
        j.cancelled = true;
      }
      d.jobs.clear();
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('playlist: minus removes the song on screen; covers', (tester) async {
    setScreen(tester, car);
    final a = await _app({});
    await tester.pumpWidget(a.widget);
    await _settle(tester);
    final songs = a.library.albums[0].songs.take(3).toList();
    final p = a.playlists.create('Road trip');
    a.playlists.add(p, songs);
    final ctx = tester.element(find.byType(Navigator).first);
    final c = a.playlists.collections(a.library.byId).firstWhere((x) => x.key == p.id);
    openCollection(ctx, c);
    await _settle(tester);
    expect(find.byTooltip('Remove from playlist'), findsNWidgets(3));
    await tester.tap(find.byTooltip('Remove from playlist').first);
    await _settle(tester);
    expect(find.byTooltip('Remove from playlist'), findsNWidgets(2)); // gone from the screen too
    expect(p.songIds, isNot(contains(songs.first.id)));
    // A song's cover as the playlist's cover, kept when saved and loaded.
    a.playlists.setCover(p, songId: songs.last.id);
    expect(
      a.playlists.collections(a.library.byId).firstWhere((x) => x.key == p.id).artAlbumId,
      songs.last.albumId,
    );
    final again = Playlists(await SharedPreferences.getInstance());
    expect(again.all.firstWhere((x) => x.id == p.id).coverSongId, songs.last.id);
    a.playlists.setCover(p);
    expect(p.coverSongId, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  // A sweep for text running into things: every main screen at car, phone,
  // small phone and tablet sizes, at normal, large and largest text.
  testWidgets('layout sweep: nothing overflows at any size or text scale', (tester) async {
    final problems = <String>{};
    final sizes = {
      'car': car,
      'phone': phone,
      'small': const Size(360, 640),
      'tablet': const Size(1024, 1366),
    };
    for (final MapEntry(key: name, value: size) in sizes.entries) {
      for (final scale in [1.0, 1.3, 1.6]) {
        setScreen(tester, size);
        final where = '$name @${(scale * 100).round()}%';
        var at = '';
        final old = FlutterError.onError;
        FlutterError.onError = (d) {
          final msg = d.exceptionAsString();
          if (msg.contains('overflowed')) {
            final full = d.toString();
            final w = RegExp(r'(lib/[a-z_/]+\.dart:\d+)').firstMatch(full)?.group(1) ?? '?';
            problems.add('$where · $at · $w · ${msg.split('\n').first}');
          } else {
            old?.call(d);
          }
        };
        try {
          final a = await _app({'textScale': scale});
          await tester.pumpWidget(a.widget);
          await _settle(tester);
          await a.player.playAll(a.library.albums[0].songs, start: 1);
          await _settle(tester);
          for (final t in LibraryTab.values.where((t) => t != LibraryTab.get)) {
            at = t.label;
            final byTip = find.byTooltip(t.label);
            final f = byTip.evaluate().isNotEmpty ? byTip.first : find.text(t.label).first;
            if (f.evaluate().isEmpty) continue;
            await tester.tap(f, warnIfMissed: false);
            await _settle(tester, 600);
            if (t == LibraryTab.albums) await shot(tester, 'sweep_albums_${name}_${(scale * 100).round()}');
          }
          at = 'album';
          final ctx = tester.element(find.byType(Navigator).first);
          openCollection(ctx, a.library.albums[1]);
          await _settle(tester);
          Navigator.of(ctx).pop();
          await _settle(tester);
          for (final layout in PlayerStyle.values) {
            at = 'player ${layout.name}';
            a.settings.playerStyle = layout;
            PlayerSheet.open(ctx);
            await _settle(tester);
            Navigator.of(ctx).pop();
            await _settle(tester);
          }
          at = 'get music';
          final g = find.byTooltip('Get music');
          if (g.evaluate().isNotEmpty) {
            await tester.tap(g.first, warnIfMissed: false);
            await _settle(tester, 600);
          }
          at = 'downloads';
          final d = AppScope.of(ctx).downloads;
          RemoteTrack t(String title) => RemoteTrack(
            title: '$title with a rather long name to see it wrap',
            artist: 'Lumen Coast and the Orchestra of Somewhere',
            url: Uri.parse('https://x/$title'),
            ext: 'mp3',
            length: const Duration(seconds: 200),
          );
          final jobs = [
            DownloadJob(t('Done'))..state = JobState.done,
            DownloadJob(t('Failed'))
              ..state = JobState.failed
              ..error = 'Not found on SoundCloud',
            DownloadJob(t('Running'))
              ..state = JobState.downloading
              ..progress = 0.4,
            reviewJob(
              t('Close'),
              Found(
                Uri.parse('https://soundcloud.com/a/b'),
                'A long found title (Live at the Pier, 2019 remaster)',
                'someone uploading',
                const Duration(seconds: 260),
                null,
                0.4,
              ),
            ),
          ];
          d.jobs.addAll(jobs);
          openDownloads(ctx);
          await _settle(tester);
          at = 'close matches';
          openCloseMatches(ctx);
          await _settle(tester);
          Navigator.of(ctx).pop();
          await _settle(tester);
          Navigator.of(ctx).pop();
          await _settle(tester);
          for (final j in jobs) {
            j.cancelled = true;
          }
          d.jobs.clear();
          at = 'sources';
          unawaited(Navigator.of(ctx).push(MaterialPageRoute<void>(builder: (_) => const SourcesScreen())));
          await _settle(tester);
          Navigator.of(ctx).pop();
          await _settle(tester);
          at = 'settings';
          unawaited(Navigator.of(ctx).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen())));
          await _settle(tester);
          Navigator.of(ctx).pop();
          await _settle(tester);
          await tester.pumpWidget(const SizedBox());
          await _settle(tester, 200);
        } finally {
          FlutterError.onError = old;
        }
      }
    }
    if (problems.isNotEmpty) fail('Overflows:\n${problems.join('\n')}');
  });
}
