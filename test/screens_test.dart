import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roadie/app.dart';
import 'package:roadie/core/library.dart';
import 'package:roadie/core/player.dart';
import 'package:roadie/core/playlists.dart';
import 'package:roadie/core/settings.dart';
import 'package:roadie/core/sorting.dart';
import 'package:roadie/core/source.dart';
import 'package:roadie/core/visualizer.dart';
import 'package:roadie/screens/folders_screen.dart';
import 'package:roadie/screens/visualizer_screen.dart';
import 'package:roadie/screens/library_view.dart';
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
    });
    await tester.pumpWidget(a.widget);
    await _settle(tester);
    await _tab(tester, 'Get music');
    expect(find.text('Internet Archive'), findsOneWidget);
    await shot(tester, 'car_9_get_music');
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => const MusicFoldersScreen())));
    await _settle(tester);
    expect(find.textContaining('Hollow Pines'), findsOneWidget);
    await shot(tester, 'car_10_folders');
    a.engine.close();
  });
}
