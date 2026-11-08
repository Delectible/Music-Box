import 'dart:ui';

import 'package:flutter/material.dart';

import '../core/lyrics.dart';
import '../core/models.dart';
import '../core/scope.dart';
import '../core/theme.dart';
import '../widgets/art.dart';
import '../widgets/controls.dart';

void openLyrics(BuildContext context) => Navigator.of(context).push(
  PageRouteBuilder<void>(
    opaque: false,
    transitionDuration: const Duration(milliseconds: 380),
    pageBuilder: (_, _, _) => const LyricsScreen(),
    transitionsBuilder: (_, a, _, child) => FadeTransition(
      opacity: a,
      child: ScaleTransition(scale: Tween(begin: 1.04, end: 1.0).animate(a), child: child),
    ),
  ),
);

/// Synced lyrics over the blurred cover: the current line large and bright,
/// the view keeps it in place; tap a line to jump there.
class LyricsScreen extends StatelessWidget {
  const LyricsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final p = AppScope.of(context).player;
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        final song = p.current;
        if (song == null) return const SizedBox();
        return Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            fit: StackFit.expand,
            children: [
              ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 60, sigmaY: 60),
                child: Opacity(
                  opacity: 0.5,
                  child: FittedBox(
                    fit: BoxFit.cover,
                    child: Art(albumId: song.albumId, size: 400, radius: 0),
                  ),
                ),
              ),
              const ColoredBox(color: Color(0x88000000)),
              SafeArea(
                child: Column(
                  children: [
                    Row(
                      children: [
                        BigIconButton(
                          icon: Icons.keyboard_arrow_down_rounded,
                          size: 56,
                          color: Colors.white,
                          tooltip: 'Close',
                          onTap: () => Navigator.of(context).pop(),
                        ),
                        Art(albumId: song.albumId, size: 44, radius: 8),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                song.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                song.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white70, fontSize: 15),
                              ),
                            ],
                          ),
                        ),
                        const PlayPauseButton(size: 52, background: Colors.white24, foreground: Colors.white),
                        const SizedBox(width: 12),
                      ],
                    ),
                    Expanded(
                      child: _Words(song: song, key: ValueKey(song.id)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Words extends StatefulWidget {
  final Song song;
  const _Words({super.key, required this.song});

  @override
  State<_Words> createState() => _WordsState();
}

class _WordsState extends State<_Words> {
  final _scroll = ScrollController();
  late final Future<Lyrics?> _lyrics = Lyrics.of(widget.song);
  final _keys = <int, GlobalKey>{};
  int _shown = -2;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _follow(int i) {
    if (i == _shown) return;
    _shown = i;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _keys[i < 0 ? 0 : i]?.currentContext;
      if (ctx == null || !mounted) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.38,
        duration: motion(AppScope.of(context).settings, 450),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final p = scope.player;
    final big = MediaQuery.sizeOf(context).width > 700;
    final size = big ? 34.0 : 26.0;
    return FutureBuilder<Lyrics?>(
      future: _lyrics,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator(color: Colors.white));
        }
        final l = snap.data;
        if (l == null) {
          return const Center(
            child: Text(
              'No lyrics found for this song',
              style: TextStyle(color: Colors.white70, fontSize: 20),
            ),
          );
        }
        if (!l.synced) {
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 80),
            child: Text(
              l.plain,
              style: TextStyle(color: Colors.white, fontSize: size * 0.8, height: 1.5),
            ),
          );
        }
        return ValueListenableBuilder<Duration>(
          valueListenable: p.position,
          builder: (context, pos, _) {
            final now = l.lineAt(pos);
            _follow(now);
            return ShaderMask(
              // Lines fade out toward the top and bottom edges.
              shaderCallback: (r) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.white, Colors.white, Colors.transparent],
                stops: [0, 0.12, 0.85, 1],
              ).createShader(r),
              blendMode: BlendMode.dstIn,
              child: ListView.builder(
                controller: _scroll,
                padding: EdgeInsets.fromLTRB(28, MediaQuery.sizeOf(context).height * 0.3, 28, 300),
                itemCount: l.lines.length + 1,
                itemBuilder: (context, i) {
                  if (i == l.lines.length) {
                    return Padding(
                      padding: const EdgeInsets.only(top: 24),
                      child: Text('Lyrics: ${l.source}', style: const TextStyle(color: Colors.white38)),
                    );
                  }
                  final line = l.lines[i];
                  final on = i == now;
                  final past = i < now;
                  return InkWell(
                    key: _keys.putIfAbsent(i, GlobalKey.new),
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => p.seek(line.at),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                      child: AnimatedDefaultTextStyle(
                        duration: motion(scope.settings, 300),
                        curve: Curves.easeOut,
                        style: TextStyle(
                          fontFamily: font,
                          fontSize: on ? size * 1.15 : size,
                          fontWeight: on ? FontWeight.w700 : FontWeight.w600,
                          height: 1.25,
                          color: on ? Colors.white : Colors.white.withValues(alpha: past ? 0.35 : 0.5),
                        ),
                        child: Text(line.text.isEmpty ? '♪' : line.text),
                      ),
                    ),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}
