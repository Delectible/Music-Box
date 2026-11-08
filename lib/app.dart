import 'package:flutter/material.dart';

import 'core/downloads.dart';
import 'core/library.dart';
import 'core/player.dart';
import 'core/playlists.dart';
import 'core/scope.dart';
import 'core/settings.dart';
import 'core/tag_fixer.dart';
import 'core/theme.dart';
import 'screens/home_screen.dart';
import 'screens/library_view.dart';
import 'screens/now_playing.dart';
import 'widgets/art.dart';

class RoadieApp extends StatefulWidget {
  final Settings settings;
  final Library library;
  final Player player;
  final Playlists playlists;

  const RoadieApp({
    super.key,
    required this.settings,
    required this.library,
    required this.player,
    required this.playlists,
  });

  @override
  State<RoadieApp> createState() => _RoadieAppState();
}

class _RoadieAppState extends State<RoadieApp> {
  late final _accent = Accent(widget.settings, widget.player, widget.library);
  final _nav = GlobalKey<NavigatorState>();
  late final _downloads = Downloads(widget.settings, widget.library);
  late final _fixer = TagFixer(widget.library);

  @override
  void initState() {
    super.initState();
    PlayerSheet.opener = (_) {
      final nav = _nav.currentState;
      if (nav == null || widget.player.current == null) return;
      nav.push(nowPlayingRoute(widget.settings));
    };
  }

  @override
  void dispose() {
    _accent.dispose();
    _downloads.dispose();
    _fixer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    return AppScope(
      settings: s,
      library: widget.library,
      player: widget.player,
      playlists: widget.playlists,
      downloads: _downloads,
      fixer: _fixer,
      child: ListenableBuilder(
        listenable: Listenable.merge([s, _accent]),
        builder: (context, _) {
          final accent = _accent.color;
          return MaterialApp(
            title: 'Roadie',
            navigatorKey: _nav,
            debugShowCheckedModeBanner: false,
            themeMode: s.themeMode,
            theme: buildTheme(Brightness.light, accent),
            darkTheme: buildTheme(Brightness.dark, accent, black: s.theme == ThemeChoice.black),
            themeAnimationDuration: motion(s, 500),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(s.textScale)),
              child: child!,
            ),
            home: const HomeScreen(),
          );
        },
      ),
    );
  }
}
