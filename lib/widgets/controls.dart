import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

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
class SeekBar extends StatefulWidget {
  final Color? color;
  final double thickness;
  final double fontSize;
  const SeekBar({super.key, this.color, this.thickness = 8, this.fontSize = 16});

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final p = AppScope.of(context).player;
    final cs = Theme.of(context).colorScheme;
    final c = widget.color ?? cs.onSurface;
    return ListenableBuilder(
      listenable: Listenable.merge([p.position, p]),
      builder: (context, _) {
        final total = p.duration.inMilliseconds.toDouble();
        final pos =
            _drag ?? p.position.value.inMilliseconds.toDouble().clamp(0, total > 0 ? total : 1).toDouble();
        final style = TextStyle(
          fontSize: widget.fontSize,
          color: c.withValues(alpha: 0.75),
          fontFeatures: const [FontFeature.tabularFigures()],
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: widget.thickness,
                activeTrackColor: cs.primary,
                inactiveTrackColor: c.withValues(alpha: 0.16),
                thumbShape: RoundSliderThumbShape(enabledThumbRadius: widget.thickness + 2),
                padding: EdgeInsets.zero,
              ),
              child: SizedBox(
                height: 36,
                child: Slider(
                  value: pos,
                  max: total > 0 ? total : 1,
                  onChanged: total > 0 ? (v) => setState(() => _drag = v) : null,
                  onChangeEnd: (v) {
                    p.seek(Duration(milliseconds: v.round()));
                    setState(() => _drag = null);
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
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
