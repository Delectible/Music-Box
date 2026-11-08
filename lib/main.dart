import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/audio.dart';
import 'core/library.dart';
import 'core/player.dart';
import 'core/playlists.dart';
import 'core/settings.dart';
import 'core/source.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final settings = Settings(prefs);
  final source = MediaStoreSource();
  final engine = await AudioEngine.start(source);
  final player = Player(engine, prefs)..previousRestarts = () => settings.previousRestarts;
  void syncEngine() => engine.restartOnPrevious = settings.previousRestarts;
  settings.addListener(syncEngine);
  syncEngine();
  final library = Library(source, settings);
  final playlists = Playlists(prefs);
  runApp(RoadieApp(settings: settings, library: library, player: player, playlists: playlists));
  await library.load(ask: true);
  if (library.state == LibraryState.ready) {
    unawaited(player.restore(library.byId, autoplay: settings.resumeOnStart));
  }
}
