import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/format.dart';
import '../core/player.dart';
import '../core/scope.dart';
import '../core/theme.dart';

/// Play / pause that morphs between the two.
class PlayPauseButton extends StatefulWidget {
  final double size;
  final Color background;
  final Color foreground;
  final double radius;
  const PlayPauseButton({
    super.key,
    required this.size,
    required this.background,
    required this.foreground,
    this.radius = -1,
  });

  @override
  State<PlayPauseButton> createState() => _PlayPauseButtonState();
}

class _PlayPauseButtonState extends State<PlayPauseButton> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 260));

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
        final playing = scope.player.playing;
        playing ? _c.forward() : _c.reverse();
        final r = widget.radius < 0 ? widget.size / 2 : widget.radius;
        return AnimatedContainer(
          duration: motion(scope.settings, 260),
          curve: Curves.easeOutBack,
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: widget.background,
            // Rounder while playing, a touch squarer when paused.
            borderRadius: BorderRadius.circular(playing ? r : r * 0.62),
            boxShadow: [
              BoxShadow(
                color: widget.background.withValues(alpha: 0.35),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(r),
              onTap: scope.player.toggle,
              child: Center(
                child: AnimatedIcon(
                  icon: AnimatedIcons.play_pause,
                  progress: _c,
                  size: widget.size * 0.5,
                  color: widget.foreground,
                  semanticLabel: playing ? 'Pause' : 'Play',
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A round icon button with a big hit area.
class BigIconButton extends StatelessWidget {
  final IconData icon;
  final double size;
  final VoidCallback? onTap;
  final Color? color;
  final bool active;
  final String? tooltip;
  final Widget? badge;

  const BigIconButton({
    super.key,
    required this.icon,
    required this.size,
    this.onTap,
    this.color,
    this.active = false,
    this.tooltip,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = color ?? cs.onSurface;
    return Tooltip(
      message: tooltip ?? '',
      child: Material(
        type: MaterialType.transparency,
        child: InkResponse(
          onTap: onTap,
          radius: size * 0.7,
          child: SizedBox.square(
            dimension: size,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(
                  icon,
                  size: size * 0.55,
                  color: active ? cs.primary : c.withValues(alpha: onTap == null ? 0.3 : 1),
                ),
                if (active)
                  Positioned(
                    bottom: size * 0.1,
                    child: Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(color: cs.primary, shape: BoxShape.circle),
                    ),
                  ),
                if (badge != null) Positioned(right: size * 0.18, top: size * 0.18, child: badge!),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shuffle and repeat, which light up when on.
class ShuffleButton extends StatelessWidget {
  final double size;
  final Color? color;
  const ShuffleButton({super.key, required this.size, this.color});

  @override
  Widget build(BuildContext context) {
    final p = AppScope.of(context).player;
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) => BigIconButton(
        icon: Icons.shuffle_rounded,
        size: size,
        color: color,
        active: p.shuffle,
        tooltip: 'Shuffle',
        onTap: () => p.setShuffle(!p.shuffle),
      ),
    );
  }
}

class RepeatButton extends StatelessWidget {
  final double size;
  final Color? color;
  const RepeatButton({super.key, required this.size, this.color});

  @override
  Widget build(BuildContext context) {
    final p = AppScope.of(context).player;
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) => BigIconButton(
        icon: p.repeat == Repeat.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
        size: size,
        color: color,
        active: p.repeat != Repeat.off,
        tooltip: 'Repeat',
        onTap: p.cycleRepeat,
      ),
    );
  }
}

/// Seek bar with times. Holds its own value while dragging.
/// The seek bar: the part already played is a wave that ripples while the
/// song plays and settles flat when it's paused (or while you drag).
class SeekBar extends StatefulWidget {
  final Color? color;
  final double thickness;
  final double fontSize;
  const SeekBar({super.key, this.color, this.thickness = 8, this.fontSize = 16});

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> with TickerProviderStateMixin {
  double? _drag;
  late final Ticker _ticker;
  final _phase = ValueNotifier(0.0);
  late final _amp = AnimationController(vsync: this, duration: const Duration(milliseconds: 450));
  Duration _last = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((t) {
      final dt = (t - _last).inMicroseconds / 1e6;
      _last = t;
      _phase.value = (_phase.value + dt * 2.2) % 1;
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    _amp.dispose();
    _phase.dispose();
    super.dispose();
  }

  void _sync(bool playing, bool animate) {
    final wave = playing && _drag == null;
    if (wave && _amp.status != AnimationStatus.forward && _amp.value < 1) _amp.forward();
    if (!wave && _amp.status != AnimationStatus.reverse && _amp.value > 0) _amp.reverse();
    final run = wave && animate;
    if (run && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    } else if (!run && _ticker.isActive && _amp.value == 0) {
      _ticker.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final p = scope.player;
    final cs = Theme.of(context).colorScheme;
    final c = widget.color ?? cs.onSurface;
    return ListenableBuilder(
      listenable: Listenable.merge([p.position, p]),
      builder: (context, _) {
        final total = p.duration.inMilliseconds.toDouble();
        final pos =
            _drag ?? p.position.value.inMilliseconds.toDouble().clamp(0, total > 0 ? total : 1).toDouble();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _sync(p.playing, scope.settings.animations);
        });
        final style = TextStyle(
          fontSize: widget.fontSize,
          color: c.withValues(alpha: 0.75),
          fontFeatures: const [FontFeature.tabularFigures()],
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LayoutBuilder(
              builder: (context, box) {
                double at(double dx) => total <= 0 ? 0 : (dx / box.maxWidth).clamp(0.0, 1.0) * total;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: total > 0
                      ? (d) => p.seek(Duration(milliseconds: at(d.localPosition.dx).round()))
                      : null,
                  onHorizontalDragStart: total > 0
                      ? (d) => setState(() => _drag = at(d.localPosition.dx))
                      : null,
                  onHorizontalDragUpdate: total > 0
                      ? (d) => setState(() => _drag = at(d.localPosition.dx))
                      : null,
                  onHorizontalDragEnd: total > 0
                      ? (_) {
                          final v = _drag;
                          setState(() => _drag = null);
                          if (v != null) p.seek(Duration(milliseconds: v.round()));
                        }
                      : null,
                  child: SizedBox(
                    height: 40,
                    width: double.infinity,
                    child: CustomPaint(
                      painter: _WavePainter(
                        progress: total > 0 ? pos / total : 0,
                        phase: _phase,
                        amp: _amp,
                        played: cs.primary,
                        rest: c.withValues(alpha: 0.16),
                        thickness: widget.thickness,
                        dragging: _drag != null,
                      ),
                    ),
                  ),
                );
              },
            ),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: [
                  Text(clock(Duration(milliseconds: pos.round())), style: style),
                  const Spacer(),
                  Text('-${clock(Duration(milliseconds: (total - pos).round()))}', style: style),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _WavePainter extends CustomPainter {
  final double progress;
  final ValueNotifier<double> phase;
  final Animation<double> amp;
  final Color played, rest;
  final double thickness;
  final bool dragging;

  _WavePainter({
    required this.progress,
    required this.phase,
    required this.amp,
    required this.played,
    required this.rest,
    required this.thickness,
    required this.dragging,
  }) : super(repaint: Listenable.merge([phase, amp]));

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    final r = thickness * 0.9; // thumb radius
    final x = (r + (size.width - 2 * r) * progress.clamp(0.0, 1.0));
    final stroke = thickness * 0.6;
    // The rest of the song: a calm straight line.
    canvas.drawLine(
      Offset(x + r + 4, mid),
      Offset(size.width - stroke / 2, mid),
      Paint()
        ..color = rest
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round,
    );
    // Played: a wave that ripples toward the thumb.
    final a = Curves.easeInOut.transform(amp.value) * thickness * 0.55;
    const wavelength = 30.0;
    final path = Path()..moveTo(stroke / 2, mid);
    final end = max(stroke / 2, x - r - 3);
    for (var px = stroke / 2; px <= end; px += 2) {
      // Fades in from the ends so it meets the thumb and the start cleanly.
      final edge = min(1.0, min(px, end - px) / 12);
      final y = mid + sin((px / wavelength - phase.value) * 2 * pi) * a * edge;
      path.lineTo(px, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = played
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    // The thumb: a tall rounded bar, bigger while dragging.
    final h = dragging ? thickness * 3.4 : thickness * 2.6;
    final w = dragging ? thickness * 1.1 : thickness * 0.8;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(x, mid), width: w, height: h),
        Radius.circular(w / 2),
      ),
      Paint()..color = played,
    );
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.progress != progress || old.played != played || old.rest != rest || old.dragging != dragging;
}

/// Sideways swipe to skip that ignores the phone's own gestures: swipes that
/// start at the left / right edge (back) or on the gesture bar (switch
/// apps), and short flicks.
class SkipSwipe extends StatefulWidget {
  final bool enabled;
  final VoidCallback onNext;
  final VoidCallback onPrevious;
  final Widget child;
  const SkipSwipe({
    super.key,
    required this.enabled,
    required this.onNext,
    required this.onPrevious,
    required this.child,
  });

  /// True when [global] is where Android's back / home / app-switch gestures start.
  static bool inSystemZone(BuildContext context, Offset global) {
    final size = MediaQuery.sizeOf(context);
    final g = MediaQuery.systemGestureInsetsOf(context);
    final pad = MediaQuery.viewPaddingOf(context);
    final left = g.left > 32 ? g.left : 32.0;
    final right = g.right > 32 ? g.right : 32.0;
    var bottom = g.bottom > pad.bottom ? g.bottom : pad.bottom;
    if (bottom < 28) bottom = 28;
    return global.dx < left || global.dx > size.width - right || global.dy > size.height - bottom;
  }

  @override
  State<SkipSwipe> createState() => _SkipSwipeState();
}

class _SkipSwipeState extends State<SkipSwipe> {
  bool _ignore = false;
  double _dx = 0;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return GestureDetector(
      // Where the finger went down, not where the drag was recognised.
      dragStartBehavior: DragStartBehavior.down,
      onHorizontalDragStart: (d) {
        _ignore = SkipSwipe.inSystemZone(context, d.globalPosition);
        _dx = 0;
      },
      onHorizontalDragUpdate: (d) => _dx += d.delta.dx,
      onHorizontalDragCancel: () => _ignore = true,
      onHorizontalDragEnd: (d) {
        if (_ignore || _dx.abs() < 60) return;
        final v = d.primaryVelocity ?? 0;
        if (v < -250 && _dx < 0) widget.onNext();
        if (v > 250 && _dx > 0) widget.onPrevious();
      },
      child: widget.child,
    );
  }
}
