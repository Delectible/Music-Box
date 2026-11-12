import 'dart:async';

import 'package:flutter/material.dart';

import 'core/downloads.dart';
import 'core/native.dart';
import 'core/library.dart';
import 'core/player.dart';
import 'core/playlists.dart';
import 'core/preview.dart';
import 'core/scope.dart';
import 'core/settings.dart';
import 'core/tag_fixer.dart';
import 'core/theme.dart';
import 'screens/get_music_screen.dart';
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
  final _messenger = GlobalKey<ScaffoldMessengerState>();

  /// When a run of downloads finishes, say how it went, wherever you are.
  DownloadReport? _told;
  bool _toldSlow = false;
  void _report() {
    if (_downloads.slowHint && !_toldSlow) {
      _toldSlow = true;
      _messenger.currentState?.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          content: Text(
            'The connection looks slow. Download 2 at a time instead of ${widget.settings.downloadThreads}?',
          ),
          action: SnackBarAction(
            label: 'Use 2',
            onPressed: () {
              widget.settings.downloadThreads = 2;
              _downloads.dismissSlowHint();
            },
          ),
        ),
      );
    }
    final r = _downloads.report;
    if (r == null || identical(r, _told)) return;
    _told = r;
    final bad = r.failed.length;
    _messenger.currentState?.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text(
          'Downloads finished: ${r.saved.length + r.already.length} of ${r.total} saved'
          '${r.close.isNotEmpty ? ' · ${r.close.length} close matches to check' : ''}'
          '${bad > 0 ? ' · $bad didn\'t work' : ''}',
        ),
        action: SnackBarAction(
          label: 'See list',
          onPressed: () {
            final ctx = _nav.currentContext;
            if (ctx != null) openDownloads(ctx);
          },
        ),
      ),
    );
  }

  late final _downloads = Downloads(widget.settings, widget.library, widget.playlists);
  late final _fixer = TagFixer(widget.library);
  late final _preview = Preview(widget.player);

  int _warmed = -1;
  void _warm() {
    final id = widget.player.current?.albumId;
    final ctx = _nav.currentContext;
    if (id == null || id == _warmed || ctx == null) return;
    _warmed = id;
    unawaited(warmCover(ctx, id));
  }

  BarsMode? _barsNow;
  void _bars() {
    final b = widget.settings.bars;
    if (b == _barsNow) return;
    _barsNow = b;
    unawaited(Native.immersive(b.index));
  }

  // Day & night theme: look at the clock every minute.
  Timer? _clock;
  bool _night = false;

  @override
  void initState() {
    super.initState();
    _night = widget.settings.isNight();
    _clock = Timer.periodic(const Duration(minutes: 1), (_) {
      final n = widget.settings.isNight();
      if (n != _night && mounted) setState(() => _night = n);
    });
    widget.player.addListener(_warm);
    _downloads.addListener(_report);
    widget.settings.addListener(_bars);
    _bars();
    PlayerSheet.opener = (_) {
      final nav = _nav.currentState;
      if (nav == null || widget.player.current == null) return;
      nav.push(nowPlayingRoute(widget.settings));
    };
  }

  @override
  void dispose() {
    _clock?.cancel();
    widget.player.removeListener(_warm);
    widget.settings.removeListener(_bars);
    _accent.dispose();
    _downloads.dispose();
    _fixer.dispose();
    _preview.dispose();
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
      preview: _preview,
      child: ListenableBuilder(
        listenable: Listenable.merge([s, _accent]),
        builder: (context, _) {
          final accent = _accent.color;
          return MaterialApp(
            title: 'Roadie',
            navigatorKey: _nav,
            scaffoldMessengerKey: _messenger,
            debugShowCheckedModeBanner: false,
            themeMode: s.themeMode,
            theme: buildTheme(Brightness.light, accent),
            darkTheme: buildTheme(Brightness.dark, accent, black: s.blackNow),
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
