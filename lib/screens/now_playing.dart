import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/models.dart';
import '../core/quality.dart';
import '../core/scope.dart';
import '../core/settings.dart';
import '../core/theme.dart';
import '../widgets/art.dart';
import '../widgets/controls.dart';
import '../widgets/menus.dart';
import 'lyrics_screen.dart';
import 'queue_sheet.dart';
import 'visualizer_screen.dart';

/// Opens the full screen player: slides up from the mini player.
Route<void> nowPlayingRoute(Settings s) => PageRouteBuilder<void>(
  transitionDuration: motion(s, 420),
  reverseTransitionDuration: motion(s, 420),
  opaque: false,
  pageBuilder: (_, _, _) => const NowPlaying(),
  transitionsBuilder: (_, a, _, child) {
    // The same curve the cover flies on (Hero), so page and cover move together.
    final curve = CurvedAnimation(
      parent: a,
      curve: Curves.fastOutSlowIn,
      reverseCurve: Curves.fastOutSlowIn.flipped,
    );
    return SlideTransition(
      position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(curve),
      child: child,
    );
  },
);

/// The full screen player, built to be used at arm's length in a car:
/// huge targets, swipe anywhere to skip, swipe down to close.
class NowPlaying extends StatefulWidget {
  const NowPlaying({super.key});

  @override
  State<NowPlaying> createState() => _NowPlayingState();
}

class _NowPlayingState extends State<NowPlaying> {
  int _lastIndex = 0;
  int _direction = 1; // 1 = forward (next), -1 = back
  double _dragY = 0;

  @override
  void initState() {
    super.initState();
    final scope = AppScope.of(context);
    _lastIndex = scope.player.index;
    if (scope.settings.keepScreenOn) unawaited(WakelockPlus.enable().catchError((Object _) {}));
  }

  @override
  void dispose() {
    unawaited(WakelockPlus.disable().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([scope.player, scope.settings]),
      builder: (context, _) {
        final p = scope.player;
        final song = p.current;
        if (song == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.of(context).maybePop();
          });
          return const SizedBox();
        }
        if (p.index != _lastIndex) {
          _direction = p.index > _lastIndex ? 1 : -1;
          _lastIndex = p.index;
        }
        final s = scope.settings;
        final swipe = s.swipeToSkip;
        return Transform.translate(
          offset: Offset(0, _dragY),
          child: GestureDetector(
            onVerticalDragUpdate: (d) => setState(() => _dragY = (_dragY + d.delta.dy).clamp(0, 600)),
            onVerticalDragEnd: (d) {
              if (_dragY > 140 || (d.primaryVelocity ?? 0) > 700) {
                Navigator.of(context).pop();
              } else {
                setState(() => _dragY = 0);
              }
            },
            child: SkipSwipe(
              enabled: swipe,
              onNext: p.next,
              onPrevious: p.previous,
              child: Scaffold(
                backgroundColor: Colors.transparent,
                body: Stack(
                  fit: StackFit.expand,
                  children: [
                    _Backdrop(song: song),
                    SafeArea(
                      child: Column(
                        children: [
                          _TopBar(song: song),
                          Expanded(
                            child: switch (s.playerStyle) {
                              PlayerStyle.cover => _CoverLayout(song: song, direction: _direction),
                              PlayerStyle.glance => _GlanceLayout(song: song, direction: _direction),
                              PlayerStyle.record => _RecordLayout(song: song, direction: _direction),
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

final _blurs = <String, Future<ui.Image?>>{};

/// The cover blurred once into a small picture. Blurring the full screen
/// every frame (as it drifts) was too much for head units; a small, already
/// blurred picture just gets scaled.
Future<ui.Image?> _blurred(String path) {
  final hit = _blurs.remove(path);
  if (hit != null) return _blurs[path] = hit;
  if (_blurs.length >= 6) _blurs.remove(_blurs.keys.first);
  return _blurs[path] = () async {
    try {
      final codec = await ui.instantiateImageCodec(await File(path).readAsBytes(), targetWidth: 96);
      final src = (await codec.getNextFrame()).image;
      final rec = ui.PictureRecorder();
      Canvas(rec).drawImage(
        src,
        Offset.zero,
        Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: 3.5, sigmaY: 3.5, tileMode: TileMode.clamp),
      );
      final out = await rec.endRecording().toImage(src.width, src.height);
      src.dispose();
      return out;
    } on Object {
      return null;
    }
  }();
}

/// The cover, blurred, behind everything; or the accent as a soft glow.
class _Backdrop extends StatelessWidget {
  final Song song;
  const _Backdrop({required this.song});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final cs = Theme.of(context).colorScheme;
    final black = scope.settings.blackNow && Theme.of(context).brightness == Brightness.dark;
    final base = black ? Colors.black : cs.surface;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: base),
        if (scope.settings.blurBackground)
          FutureBuilder<String?>(
            future: scope.library.source.art(song.albumId, 160),
            builder: (context, snap) => AnimatedSwitcher(
              duration: motion(scope.settings, 600),
              // Full screen: the default layout let the small blurred picture
              // shrink to its own size (a square drifting behind the record).
              layoutBuilder: (current, previous) =>
                  Stack(fit: StackFit.expand, children: [...previous, ?current]),
              child: snap.data == null
                  ? _Glow(key: ValueKey('g${song.albumId}'), color: albumHue(song.albumId))
                  : FutureBuilder<ui.Image?>(
                      key: ValueKey(snap.data),
                      future: _blurred(snap.data!),
                      builder: (context, img) => img.data == null
                          ? _Glow(color: albumHue(song.albumId))
                          : _Drift(
                              child: RawImage(
                                width: double.infinity,
                                height: double.infinity,
                                image: img.data,
                                fit: BoxFit.cover,
                                filterQuality: FilterQuality.medium,
                                color: Colors.white.withValues(alpha: black ? 0.35 : 0.55),
                                colorBlendMode: BlendMode.modulate,
                              ),
                            ),
                    ),
            ),
          )
        else
          _Glow(color: cs.primary),
        // Darken so text always reads.
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [base.withValues(alpha: 0.35), base.withValues(alpha: 0.75)],
            ),
          ),
        ),
      ],
    );
  }
}

class _Glow extends StatelessWidget {
  final Color color;
  const _Glow({super.key, required this.color});

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: RadialGradient(
        center: const Alignment(-0.6, -0.5),
        radius: 1.3,
        colors: [color.withValues(alpha: 0.55), color.withValues(alpha: 0.0)],
      ),
    ),
  );
}

class _TopBar extends StatelessWidget {
  final Song song;
  const _TopBar({required this.song});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    // Phones: smaller buttons so they all fit.
    final b = MediaQuery.sizeOf(context).width < 560 ? 46.0 : 60.0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          BigIconButton(
            icon: Icons.keyboard_arrow_down_rounded,
            size: b,
            tooltip: 'Close',
            onTap: () => Navigator.of(context).pop(),
          ),
          // Car screens: the system clock is often hidden. Phones show it already.
          if (scope.settings.showClock &&
              MediaQuery.sizeOf(context).width > MediaQuery.sizeOf(context).height)
            const _Clock(),
          const Spacer(),
          if (song.podcast)
            ListenableBuilder(
              listenable: scope.settings,
              builder: (context, _) {
                const speeds = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
                final v = scope.settings.podcastSpeed;
                return TextButton(
                  style: TextButton.styleFrom(minimumSize: Size(b * 1.2, b)),
                  onPressed: () =>
                      scope.settings.podcastSpeed = speeds[(speeds.indexOf(v) + 1) % speeds.length],
                  child: Text(
                    '${v == v.roundToDouble() ? v.toStringAsFixed(0) : v}×',
                    style: TextStyle(fontSize: b * 0.36, fontWeight: FontWeight.w700),
                  ),
                );
              },
            ),
          if (scope.settings.lyrics && !song.podcast)
            BigIconButton(
              icon: Icons.lyrics_rounded,
              size: b,
              tooltip: 'Lyrics',
              onTap: () => openLyrics(context),
            ),
          BigIconButton(
            icon: Icons.graphic_eq_rounded,
            size: b,
            tooltip: 'Visualiser',
            onTap: () => openVisualizer(context),
          ),
          _StylePicker(),
          ListenableBuilder(
            listenable: scope.playlists,
            builder: (context, _) {
              final fav = scope.playlists.isFavourite(song.id);
              return BigIconButton(
                icon: fav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                size: b,
                active: fav,
                tooltip: 'Favourite',
                onTap: () => scope.playlists.toggleFavourite(song.id),
              );
            },
          ),
          BigIconButton(
            icon: Icons.queue_music_rounded,
            size: b,
            tooltip: 'Queue',
            onTap: () => showQueue(context),
          ),
          BigIconButton(
            icon: Icons.more_vert_rounded,
            size: b,
            tooltip: 'More',
            onTap: () => showSongMenu(context, song),
          ),
        ],
      ),
    );
  }
}

/// Switches player layout in place (also in Settings).
class _StylePicker extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).settings;
    return PopupMenuButton<PlayerStyle>(
      tooltip: 'Player style',
      icon: const Icon(Icons.dashboard_customize_rounded, size: 30),
      padding: const EdgeInsets.all(15),
      initialValue: s.playerStyle,
      onSelected: (v) => s.playerStyle = v,
      itemBuilder: (_) => [
        for (final v in PlayerStyle.values)
          PopupMenuItem(
            value: v,
            height: 60,
            child: ListTile(title: Text(v.label), subtitle: Text(v.blurb), contentPadding: EdgeInsets.zero),
          ),
      ],
    );
  }
}

class _Clock extends StatefulWidget {
  const _Clock();
  @override
  State<_Clock> createState() => _ClockState();
}

class _ClockState extends State<_Clock> {
  Timer? _t;
  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 15), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = TimeOfDay.now();
    final use24 = MediaQuery.alwaysUse24HourFormatOf(context);
    final h = use24 ? t.hour : (t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod);
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Text(
        '$h:${t.minute.toString().padLeft(2, '0')}',
        style: const TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w500,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// Slides the old song out and the new one in, the way the skip went.
class _TrackSwitcher extends StatelessWidget {
  final int songId;
  final int direction;
  final Widget child;
  final Axis axis;
  const _TrackSwitcher({
    required this.songId,
    required this.direction,
    required this.child,
    this.axis = Axis.horizontal,
  });

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).settings;
    return AnimatedSwitcher(
      duration: motion(s, 380),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (current, previous) =>
          Stack(alignment: Alignment.center, children: [...previous, ?current]),
      transitionBuilder: (child, a) {
        final incoming = child.key == ValueKey(songId);
        final dx = (incoming ? 1.0 : -1.0) * direction * 0.25;
        final begin = axis == Axis.horizontal ? Offset(dx, 0) : Offset(0, dx);
        return FadeTransition(
          opacity: a,
          child: SlideTransition(
            position: Tween(begin: begin, end: Offset.zero).animate(a),
            child: ScaleTransition(scale: Tween(begin: 0.92, end: 1.0).animate(a), child: child),
          ),
        );
      },
      child: KeyedSubtree(key: ValueKey(songId), child: child),
    );
  }
}

class _Titles extends StatelessWidget {
  final Song song;
  final double size;
  final TextAlign align;
  final int maxLines;
  const _Titles({required this.song, required this.size, this.align = TextAlign.start, this.maxLines = 2});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final cross = align == TextAlign.center ? CrossAxisAlignment.center : CrossAxisAlignment.start;
    return Column(
      crossAxisAlignment: cross,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          song.title,
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
          textAlign: align,
          style: TextStyle(fontSize: size, fontWeight: FontWeight.w600, height: 1.1),
        ),
        SizedBox(height: size * 0.25),
        // Tap the artist or the album to go to it.
        _Link(
          onTap: () {
            final lib = AppScope.of(context).library;
            final a =
                lib.artist(song.artist) ??
                lib.artist(song.artist.split(RegExp(r'\s*(?:;|,|&|/| feat\.? | ft\.? )\s*')).first) ??
                lib.artist(song.albumArtist);
            if (a != null) openCollection(context, a);
          },
          child: Text(
            song.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: align,
            style: TextStyle(fontSize: size * 0.6, color: cs.primary, fontWeight: FontWeight.w500),
          ),
        ),
        _Link(
          onTap: () {
            final a = AppScope.of(context).library.album(song.albumId);
            if (a != null) openCollection(context, a);
          },
          child: Text(
            song.album,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: align,
            style: TextStyle(fontSize: size * 0.5, color: cs.onSurfaceVariant),
          ),
        ),
        SizedBox(height: size * 0.3),
        QualityBadge(song: song, size: (size * 0.42).clamp(12.0, 18.0)),
      ],
    );
  }
}

/// A line of text that opens something when tapped (with a soft press
/// highlight and a bit of extra height to hit).
class _Link extends StatelessWidget {
  final VoidCallback onTap;
  final Widget child;
  const _Link({required this.onTap, required this.child});

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(10),
    child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4), child: child),
  );
}

/// Previous, play, next (and shuffle / repeat either side).
class _Transport extends StatelessWidget {
  final double size;
  const _Transport({required this.size});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final p = scope.player;
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, box) {
        // Shrink to fit a narrow screen.
        final size = this.size * 4.6 > box.maxWidth ? box.maxWidth / 4.6 : this.size;
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ShuffleButton(size: size * 0.7),
            BigIconButton(
              icon: Icons.skip_previous_rounded,
              size: size,
              tooltip: 'Previous',
              onTap: p.previous,
            ),
            PlayPauseButton(size: size * 1.15, background: cs.primary, foreground: cs.onPrimary),
            BigIconButton(icon: Icons.skip_next_rounded, size: size, tooltip: 'Next', onTap: p.next),
            RepeatButton(size: size * 0.7),
          ],
        );
      },
    );
  }
}

class _UpNext extends StatelessWidget {
  const _UpNext();

  @override
  Widget build(BuildContext context) {
    final p = AppScope.of(context).player;
    final next = p.upNext;
    final cs = Theme.of(context).colorScheme;
    if (next == null) return const SizedBox(height: 56);
    return Material(
      color: cs.onSurface.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => showQueue(context),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Art(albumId: next.albumId, size: 40),
              const SizedBox(width: 12),
              Text('Up next  ', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 15)),
              Expanded(
                child: Text(
                  '${next.title} · ${next.artist}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                ),
              ),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }
}

/// Big cover beside (or above) the titles and controls.
class _CoverLayout extends StatelessWidget {
  final Song song;
  final int direction;
  const _CoverLayout({required this.song, required this.direction});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).settings;
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth > box.maxHeight * 1.1;
        final b = s.buttonSize;
        Widget cover(double size) => GestureDetector(
          onTap: AppScope.of(context).player.toggle,
          child: _Breathe(
            child: _SwipeDeck(
              song: song,
              direction: direction,
              style: _DeckStyle.cover,
              travel: size,
              builder: (song, live) {
                final art = DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: artRadius(s.artShape, size),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: Theme.of(context).brightness == Brightness.dark ? 0.4 : 0.15,
                        ),
                        blurRadius: 40,
                        offset: const Offset(0, 12),
                      ),
                    ],
                  ),
                  child: Art(albumId: song.albumId, size: size),
                );
                return live
                    ? Hero(
                        tag: 'now-art',
                        flightShuttleBuilder: nowArtShuttle,
                        createRectTween: nowArtRectTween,
                        child: art,
                      )
                    : art;
              },
            ),
          ),
        );
        if (wide) {
          final size = (box.maxHeight - 32).clamp(120.0, box.maxWidth * 0.45);
          return Padding(
            padding: const EdgeInsets.fromLTRB(32, 0, 32, 16),
            child: Row(
              children: [
                cover(size),
                const SizedBox(width: 40),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _TrackSwitcher(
                        songId: song.id,
                        direction: direction,
                        axis: Axis.vertical,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: _Titles(song: song, size: 34),
                        ),
                      ),
                      const _Entrance(order: 1, child: SeekBar()),
                      _Entrance(order: 2, child: _Transport(size: b)),
                      const _Entrance(order: 3, child: _UpNext()),
                    ],
                  ),
                ),
              ],
            ),
          );
        }
        final size = (box.maxWidth - 64).clamp(120.0, box.maxHeight * 0.48);
        return Padding(
          padding: const EdgeInsets.fromLTRB(28, 8, 28, 20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Short screens / big text: the cover gives way so the rest fits.
              Flexible(child: FittedBox(child: cover(size))),
              _TrackSwitcher(
                songId: song.id,
                direction: direction,
                child: _Titles(song: song, size: 28, align: TextAlign.center),
              ),
              const _Entrance(order: 1, child: SeekBar()),
              _Entrance(order: 2, child: _Transport(size: b * 0.9)),
              const _Entrance(order: 3, child: _UpNext()),
            ],
          ),
        );
      },
    );
  }
}

/// Huge text and three giant buttons: read and hit without looking twice.
class _GlanceLayout extends StatelessWidget {
  final Song song;
  final int direction;
  const _GlanceLayout({required this.song, required this.direction});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final p = scope.player;
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth > box.maxHeight;
        final h = (box.maxHeight * (wide ? 0.34 : 0.2)).clamp(80.0, 180.0);
        Widget pad(IconData icon, VoidCallback onTap, {bool primary = false}) => Expanded(
          flex: primary ? 3 : 2,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: primary
                ? ListenableBuilder(
                    listenable: p,
                    builder: (context, _) => _Pad(
                      height: h,
                      color: cs.primary,
                      onTap: onTap,
                      child: AnimatedSwitcher(
                        duration: motion(scope.settings, 200),
                        transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                        child: Icon(
                          p.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                          key: ValueKey(p.playing),
                          size: h * 0.6,
                          color: cs.onPrimary,
                        ),
                      ),
                    ),
                  )
                : _Pad(
                    height: h,
                    color: cs.onSurface.withValues(alpha: 0.1),
                    onTap: onTap,
                    child: Icon(icon, size: h * 0.5),
                  ),
          ),
        );
        return Padding(
          padding: EdgeInsets.fromLTRB(wide ? 32 : 20, 0, wide ? 32 : 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _SwipeDeck(
                  song: song,
                  direction: direction,
                  style: _DeckStyle.glance,
                  travel: box.maxWidth,
                  builder: (song, live) {
                    final art = Art(albumId: song.albumId, size: wide ? 140 : 96);
                    return Row(
                      children: [
                        if (live)
                          Hero(
                            tag: 'now-art',
                            flightShuttleBuilder: nowArtShuttle,
                            createRectTween: nowArtRectTween,
                            child: art,
                          )
                        else
                          art,
                        SizedBox(width: wide ? 32 : 20),
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: _Titles(song: song, size: wide ? 52 : 36, maxLines: 2),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              const SeekBar(thickness: 12, fontSize: 20),
              const SizedBox(height: 16),
              Row(
                children: [
                  pad(Icons.skip_previous_rounded, p.previous),
                  pad(Icons.play_arrow_rounded, p.toggle, primary: true),
                  pad(Icons.skip_next_rounded, p.next),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Pad extends StatelessWidget {
  final double height;
  final Color color;
  final VoidCallback onTap;
  final Widget child;
  const _Pad({required this.height, required this.color, required this.onTap, required this.child});

  @override
  Widget build(BuildContext context) => Material(
    color: color,
    borderRadius: BorderRadius.circular(28),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: SizedBox(
        height: height,
        child: Center(child: child),
      ),
    ),
  );
}

/// The cover as the label of a spinning record.
class _RecordLayout extends StatelessWidget {
  final Song song;
  final int direction;
  const _RecordLayout({required this.song, required this.direction});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).settings;
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth > box.maxHeight * 1.1;
        final b = s.buttonSize;
        if (wide) {
          final size = (box.maxHeight - 24).clamp(120.0, box.maxWidth * 0.48);
          return Padding(
            padding: const EdgeInsets.fromLTRB(32, 0, 32, 12),
            child: Row(
              children: [
                _Record(song: song, size: size, direction: direction),
                const SizedBox(width: 40),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _TrackSwitcher(
                        songId: song.id,
                        direction: direction,
                        axis: Axis.vertical,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: _Titles(song: song, size: 34),
                        ),
                      ),
                      const _Entrance(order: 1, child: SeekBar()),
                      _Entrance(order: 2, child: _Transport(size: b)),
                    ],
                  ),
                ),
              ],
            ),
          );
        }
        final size = (box.maxWidth - 48).clamp(120.0, box.maxHeight * 0.5);
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Flexible(
                child: FittedBox(
                  child: _Record(song: song, size: size, direction: direction),
                ),
              ),
              _TrackSwitcher(
                songId: song.id,
                direction: direction,
                child: _Titles(song: song, size: 28, align: TextAlign.center),
              ),
              const _Entrance(order: 1, child: SeekBar()),
              _Entrance(order: 2, child: _Transport(size: b * 0.9)),
            ],
          ),
        );
      },
    );
  }
}

class _Record extends StatefulWidget {
  final Song song;
  final double size;
  final int direction;
  const _Record({required this.song, required this.size, required this.direction});

  @override
  State<_Record> createState() => _RecordState();
}

/// The record's turn, worked out frame by frame from a speed that eases up
/// (as the player opens) and runs down slowly (on pause), so the turn never
/// jumps: the flying label, the landed label and the disc all read it.
class _RecordState extends State<_Record> with SingleTickerProviderStateMixin {
  /// One turn every 3.6 s.
  static const _fullSpeed = 1 / 3.6; // turns a second
  static const _spinUp = _fullSpeed / 0.6; // full speed in 0.6 s
  static const _runDown = _fullSpeed / 1.8; // stops over 1.8 s

  final _turns = ValueNotifier(0.0);
  double _speed = 0;
  bool _on = false;
  Duration _last = Duration.zero;
  late final _ticker = createTicker(_tick);

  void _tick(Duration t) {
    final dt = ((t - _last).inMicroseconds / 1e6).clamp(0.0, 0.1);
    _last = t;
    final target = _on ? _fullSpeed : 0.0;
    _speed = _speed < target ? min(target, _speed + _spinUp * dt) : max(target, _speed - _runDown * dt);
    _turns.value = (_turns.value + _speed * dt) % 1;
    if (_speed == 0 && !_on) _ticker.stop();
  }

  void _sync(bool on) {
    _on = on;
    if (!AppScope.of(context).settings.animations) {
      _speed = 0;
      if (_ticker.isActive) _ticker.stop();
      return;
    }
    if ((on || _speed > 0) && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _turns.dispose();
    super.dispose();
  }

  /// The cover as the record's label, with the spindle hole (which shows by [hole]).
  Widget _label(Song song, double size, double hole, {double? radius}) => SizedBox.square(
    dimension: size * 0.42,
    child: Stack(
      alignment: Alignment.center,
      children: [
        Art(albumId: song.albumId, size: size * 0.42, radius: radius ?? size * 0.21),
        if (hole > 0)
          Opacity(
            opacity: hole.clamp(0, 1),
            child: Container(
              width: size * 0.035,
              height: size * 0.035,
              decoration: const BoxDecoration(color: Color(0xFF0D0D0F), shape: BoxShape.circle),
            ),
          ),
      ],
    ),
  );

  /// The label flying to / from the mini player. Opening, it turns with
  /// the record as it spins up, so it lands exactly where the record is.
  /// Closing, it rolls on to upright, its round shape eases into the mini
  /// player's and the hole fades, all finishing as it lands.
  Widget _shuttle(
    BuildContext context,
    Animation<double> a,
    HeroFlightDirection dir,
    BuildContext from,
    BuildContext to,
  ) {
    final size = widget.size;
    final song = widget.song;
    final label = size * 0.42;
    final small = artRadius(AppScope.of(context).settings.artShape, label).topLeft.x;
    final start = _turns.value;
    // To the nearest upright, whichever way is shorter.
    final rest = start > 0.5 ? 1 - start : -start;
    return AnimatedBuilder(
      animation: Listenable.merge([a, _turns]),
      builder: (context, _) {
        final t = a.value.clamp(0.0, 1.0); // 1 = in the player
        final turns = dir == HeroFlightDirection.push ? _turns.value : start + rest * (1 - t);
        return FittedBox(
          child: Transform.rotate(
            angle: turns * 2 * pi,
            child: _label(song, size, t, radius: small + (label / 2 - small) * t),
          ),
        );
      },
    );
  }

  /// One whole record (disc and label). Only the playing one carries the Hero.
  Widget _record(Song song, bool live) {
    final size = widget.size;
    final label = AnimatedBuilder(
      animation: _turns,
      builder: (context, child) => Transform.rotate(angle: _turns.value * 2 * pi, child: child),
      child: RepaintBoundary(child: _label(song, size, 1)),
    );
    return SizedBox.square(
      dimension: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // The shadow stays put; only the disc turns (drawn once, then just rotated).
          CustomPaint(size: Size.square(size), painter: _VinylShadow()),
          AnimatedBuilder(
            animation: _turns,
            builder: (context, child) => Transform.rotate(angle: _turns.value * 2 * pi, child: child),
            child: RepaintBoundary(
              child: CustomPaint(
                size: Size.square(size),
                painter: _VinylPainter(Theme.of(context).colorScheme.primary),
              ),
            ),
          ),
          if (live)
            Hero(
              tag: 'now-art',
              flightShuttleBuilder: _shuttle,
              createRectTween: nowArtRectTween,
              child: label,
            )
          else
            label,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final p = scope.player;
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        _sync(p.playing && scope.settings.animations);
        return GestureDetector(
          onTap: p.toggle,
          child: _SwipeDeck(
            song: widget.song,
            direction: widget.direction,
            style: _DeckStyle.record,
            travel: widget.size * 1.25,
            builder: _record,
          ),
        );
      },
    );
  }
}

/// The record's soft shadow (doesn't turn, so it isn't redrawn as it spins).
class _VinylShadow extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    canvas.drawCircle(
      size.center(Offset.zero).translate(0, r * 0.04),
      r,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.4)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 24),
    );
  }

  @override
  bool shouldRepaint(_VinylShadow old) => false;
}

enum _DeckStyle { record, cover, glance }

/// The player's picture, which follows a sideways swipe and skips when let
/// go far enough. Each layout has its own move:
/// - record: the whole record slides off one side and the next slides in
///   from the other, dipping slightly as it's swapped (a jukebox change);
/// - cover: the cover turns away like a card and the next turns in;
/// - glance: the picture and titles glide and fade.
class _SwipeDeck extends StatefulWidget {
  final Song song;
  final int direction;
  final _DeckStyle style;
  final double travel;
  final Widget Function(Song song, bool live) builder;
  const _SwipeDeck({
    required this.song,
    required this.direction,
    required this.style,
    required this.travel,
    required this.builder,
  });

  @override
  State<_SwipeDeck> createState() => _SwipeDeckState();
}

class _SwipeDeckState extends State<_SwipeDeck> with TickerProviderStateMixin {
  Song? _out;
  int _dir = 1;
  double _outFrom = 0; // where the old one was when the skip began (px)
  double _drag = 0;
  int? _swiped; // the direction of a swipe waiting for the song to change
  Timer? _giveUp;
  late final _swap = AnimationController(vsync: this)
    ..addStatusListener((st) {
      if (st == AnimationStatus.completed) setState(() => _out = null);
    });
  late final _back = AnimationController(vsync: this)
    ..addListener(() => setState(() => _drag = _backTween()));
  double Function() _backTween = () => 0;

  @override
  void didUpdateWidget(_SwipeDeck old) {
    super.didUpdateWidget(old);
    if (old.song.id == widget.song.id) return;
    final s = AppScope.of(context).settings;
    _giveUp?.cancel();
    _back.stop();
    _dir = _swiped ?? widget.direction;
    _swiped = null;
    _out = old.song;
    _outFrom = _drag;
    _drag = 0;
    _swap.duration = motion(s, widget.style == _DeckStyle.glance ? 320 : 450);
    _swap.forward(from: 0);
  }

  @override
  void dispose() {
    _giveUp?.cancel();
    _swap.dispose();
    _back.dispose();
    super.dispose();
  }

  void _springBack() {
    final from = _drag;
    _backTween = () => from * (1 - Curves.easeOutBack.transform(_back.value));
    _back.duration = motion(AppScope.of(context).settings, 300);
    _back.forward(from: 0);
    if (_back.duration == Duration.zero) setState(() => _drag = 0);
  }

  void _end(DragEndDetails d) {
    final p = AppScope.of(context).player;
    final v = d.primaryVelocity ?? 0;
    final far = _drag.abs() > widget.travel * 0.22 || (v.abs() > 700 && _drag.abs() > 24);
    final dir = _drag < 0 ? 1 : -1; // swipe left = next
    if (!far || (v != 0 && v.sign == dir.toDouble() && v.abs() > 300)) {
      _springBack();
      return;
    }
    _swiped = dir;
    unawaited(dir == 1 ? p.next() : p.previous());
    // No new song (end of the queue, or "previous" restarted this one).
    _giveUp = Timer(const Duration(milliseconds: 700), () {
      if (!mounted || _swiped == null) return;
      _swiped = null;
      _springBack();
    });
  }

  /// Places one picture: [x] is its offset as a share of the travel (0 =
  /// centre, ±1 = gone off a side).
  Widget _place(Widget child, double x) {
    final w = widget.travel;
    switch (widget.style) {
      case _DeckStyle.record:
        // Dips a little at the far point of the swap.
        final dip = 1 - 0.07 * sin(x.abs().clamp(0.0, 1.0) * pi);
        return Transform.translate(
          offset: Offset(x * w, 0),
          child: Transform.scale(scale: dip, child: child),
        );
      case _DeckStyle.cover:
        final k = x.clamp(-1.0, 1.0);
        return Opacity(
          opacity: (1 - k.abs() * 0.9).clamp(0.0, 1.0),
          child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.0012)
              ..translateByDouble(k * w * 0.55, 0, 0, 1)
              ..rotateY(-k * 0.55)
              ..scaleByDouble(1 - k.abs() * 0.12, 1 - k.abs() * 0.12, 1, 1),
            child: child,
          ),
        );
      case _DeckStyle.glance:
        final k = x.clamp(-1.0, 1.0);
        return Opacity(
          opacity: (1 - k.abs()).clamp(0.0, 1.0),
          child: Transform.translate(offset: Offset(k * w * 0.35, 0), child: child),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.travel;
    final drag = _drag / w;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      dragStartBehavior: DragStartBehavior.down,
      onHorizontalDragStart: (d) {
        _back.stop();
        _giveUp?.cancel();
        _swiped = null;
      },
      onHorizontalDragUpdate: (d) => setState(() => _drag += d.delta.dx),
      onHorizontalDragEnd: _end,
      onHorizontalDragCancel: _springBack,
      child: AnimatedBuilder(
        animation: _swap,
        builder: (context, _) {
          final out = _out;
          final t = out == null ? 1.0 : Curves.easeInOutCubic.transform(_swap.value);
          final from = _outFrom / w;
          return Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              if (out != null)
                IgnorePointer(
                  child: _place(
                    KeyedSubtree(key: ValueKey('out${out.id}'), child: widget.builder(out, false)),
                    from + (-_dir - from) * t,
                  ),
                ),
              _place(
                KeyedSubtree(key: ValueKey(widget.song.id), child: widget.builder(widget.song, true)),
                out == null ? drag : _dir * (1 - t),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _VinylPainter extends CustomPainter {
  final Color accent;
  _VinylPainter(this.accent);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    canvas.drawCircle(c, r, Paint()..color = const Color(0xFF111114));
    final groove = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var g = r * 0.24; g < r * 0.97; g += r / 46) {
      groove.color = Colors.white.withValues(alpha: 0.035 + 0.025 * ((g * 7).floor() % 2));
      canvas.drawCircle(c, g, groove);
    }
    // Sheen: two soft wedges catching the light.
    final rect = Rect.fromCircle(center: c, radius: r);
    final sheen = Paint()
      ..shader = SweepGradient(
        colors: [
          Colors.transparent,
          Colors.white.withValues(alpha: 0.10),
          Colors.transparent,
          Colors.transparent,
          accent.withValues(alpha: 0.12),
          Colors.transparent,
        ],
        stops: const [0.0, 0.08, 0.18, 0.5, 0.58, 0.68],
      ).createShader(rect);
    canvas.drawCircle(c, r * 0.97, sheen);
    canvas.drawCircle(
      c,
      r * 0.97,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white.withValues(alpha: 0.06),
    );
  }

  @override
  bool shouldRepaint(_VinylPainter old) => old.accent != accent;
}

/// The audio quality under the titles: "FLAC 24-bit · 96 kHz" (hi-res in the
/// accent colour, with a sparkle), "MP3 320 kbps".
class QualityBadge extends StatelessWidget {
  final Song song;
  final double size;
  const QualityBadge({super.key, required this.song, this.size = 14});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return FutureBuilder<Quality?>(
      future: Quality.of(song),
      builder: (context, snap) {
        final q = snap.data;
        return AnimatedSwitcher(
          duration: motion(AppScope.of(context).settings, 300),
          child: q == null
              ? SizedBox(key: const ValueKey(0), height: size * 1.9)
              : Container(
                  key: ValueKey(q.label),
                  padding: EdgeInsets.symmetric(horizontal: size * 0.7, vertical: size * 0.25),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(size),
                    border: Border.all(color: (q.hiRes ? cs.primary : cs.onSurface).withValues(alpha: 0.5)),
                    color: q.hiRes ? cs.primary.withValues(alpha: 0.14) : Colors.transparent,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (q.hiRes) ...[
                        Icon(Icons.auto_awesome_rounded, size: size, color: cs.primary),
                        SizedBox(width: size * 0.35),
                      ] else if (q.lossless) ...[
                        Icon(Icons.graphic_eq_rounded, size: size, color: cs.onSurfaceVariant),
                        SizedBox(width: size * 0.35),
                      ],
                      Text(
                        q.hiRes ? 'Hi-Res ${q.label}' : q.label,
                        style: TextStyle(
                          fontSize: size,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.3,
                          color: q.hiRes ? cs.primary : cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
        );
      },
    );
  }
}

/// Fades and slides a part of the player in, one after another, as it opens.
class _Entrance extends StatelessWidget {
  final int order;
  final Widget child;
  const _Entrance({required this.order, required this.child});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).settings;
    if (!s.animations) return child;
    final delay = 0.12 * order;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 420 + (order * 90)),
      curve: Interval(delay / (1 + delay), 1, curve: Curves.easeOutCubic),
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, (1 - t) * 24), child: child),
      ),
    );
  }
}

/// The cover sits back a little while paused and springs forward on play.
class _Breathe extends StatelessWidget {
  final Widget child;
  const _Breathe({required this.child});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return ListenableBuilder(
      listenable: scope.player,
      builder: (context, child) => AnimatedScale(
        scale: scope.player.playing ? 1.0 : 0.9,
        duration: motion(scope.settings, 550),
        curve: scope.player.playing ? Curves.easeOutBack : Curves.easeOutCubic,
        child: child,
      ),
      child: child,
    );
  }
}

/// The blurred cover behind the player drifts slowly (while playing).
class _Drift extends StatefulWidget {
  final Widget child;
  const _Drift({required this.child});

  @override
  State<_Drift> createState() => _DriftState();
}

class _DriftState extends State<_Drift> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(seconds: 24));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return ListenableBuilder(
      listenable: scope.player,
      builder: (context, _) {
        final run = scope.player.playing && scope.settings.animations;
        if (run && !_c.isAnimating) _c.repeat();
        if (!run && _c.isAnimating) _c.stop();
        return AnimatedBuilder(
          animation: _c,
          child: widget.child,
          builder: (context, child) {
            final a = _c.value * 2 * pi;
            return Transform.scale(
              scale: 1.25 + 0.05 * sin(a),
              child: Transform.translate(offset: Offset(cos(a) * 30, sin(a * 2) * 18), child: child),
            );
          },
        );
      },
    );
  }
}
