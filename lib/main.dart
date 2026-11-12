import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/audio.dart';
import 'core/crash_log.dart';
import 'core/levelling.dart';
import 'core/library.dart';
import 'core/native.dart';
import 'core/player.dart';
import 'core/playlists.dart';
import 'core/settings.dart';
import 'core/source.dart';
import 'core/ytdlp.dart';
import 'screens/library_view.dart';

void main() => CrashLog.guard(_start);

Future<void> _start() async {
  WidgetsFlutterBinding.ensureInitialized();
  CrashLog.install();
  await CrashLog.init();
  final prefs = await SharedPreferences.getInstance();
  final settings = Settings(prefs);
  final device = await Native.device();
  Settings.deviceRamMb = (device['ramMb'] as num?)?.toInt() ?? 0;
  final source = MediaStoreSource();
  final engine = await AudioEngine.start(source);
  final player = Player(engine, prefs)..previousRestarts = () => settings.previousRestarts;
  final playlists = Playlists(prefs);
  final levelling = Levelling(prefs);

  // How each song sounds: levelled music, podcasts at their own speed.
  engine.soundOf = (s) => SongSound(
    gainDb: s.podcast ? 0 : levelling.gainOf(s, settings.levelMode, settings.preamp),
    speed: s.podcast ? settings.podcastSpeed : 1,
    skipSilence: s.podcast && settings.skipSilence,
  );
  engine.isFavourite = (s) => playlists.isFavourite(s.id);
  engine.onFavourite = (s) => playlists.toggleFavourite(s.id);
  playlists.addListener(engine.refreshNotification);
  void syncEngine() {
    engine
      ..restartOnPrevious = settings.previousRestarts
      ..crossfade = Duration(seconds: settings.crossfade)
      ..albumGapless = settings.albumGapless;
    unawaited(engine.refreshSound());
  }

  // SoundCloud's downloader: release line, healing, daily update check.
  var scheduled = <Object>[];
  void syncYtdlp() {
    Ytdlp.channel = settings.ytdlpChannel;
    Ytdlp.nightlyFallback = settings.ytdlpNightlyFallback;
    final want = [settings.ytdlpAutoUpdate, settings.ytdlpChannel];
    if (want.join() == scheduled.join()) return;
    scheduled = want;
    unawaited(Ytdlp.schedule(enabled: settings.ytdlpAutoUpdate));
  }

  settings.addListener(syncYtdlp);
  syncYtdlp();
  // Start Python / yt-dlp now so the first search or download doesn't wait for it.
  unawaited(Ytdlp.prepare().then((_) => Ytdlp.version()));
  settings.addListener(syncEngine);
  levelling.addListener(() => unawaited(engine.refreshSound()));
  syncEngine();
  // Measure the playing song and the next few ahead of time.
  int? lastId;
  player.addListener(() {
    final c = player.current;
    if (c == null || c.id == lastId || settings.levelMode == LevelMode.off) return;
    lastId = c.id;
    levelling.prepare([c, ...player.queue.skip(player.index + 1).take(3)]);
  });

  final library = Library(source, settings);
  runApp(RoadieApp(settings: settings, library: library, player: player, playlists: playlists));
  await library.load(ask: true);
  if (library.state == LibraryState.ready) {
    await player.restore(library.byId, autoplay: settings.resumeOnStart);
    if (settings.openPlayerOnStart && player.current != null) PlayerSheet.opener?.call(null);
  }
}
