import 'package:flutter/material.dart';

import '../core/scope.dart';
import '../core/theme.dart';
import '../screens/library_view.dart';
import 'art.dart';
import 'controls.dart';

/// The bar along the bottom while something is queued. Tap or swipe up for
/// the full screen player; swipe sideways to skip.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final p = scope.player;
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        final song = p.current;
        return AnimatedSize(
          duration: motion(scope.settings, 300),
          curve: Curves.easeOutCubic,
          child: song == null
              ? const SizedBox(width: double.infinity)
              : GestureDetector(
                  onTap: () => PlayerSheet.open(context),
                  onVerticalDragEnd: (d) {
                    if ((d.primaryVelocity ?? 0) < -200) PlayerSheet.open(context);
                  },
                  onHorizontalDragEnd: (d) {
                    if (!scope.settings.swipeToSkip) return;
                    final v = d.primaryVelocity ?? 0;
                    if (v < -300) p.next();
                    if (v > 300) p.previous();
                  },
                  child: Container(
                    margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: const [
                        BoxShadow(color: Colors.black26, blurRadius: 16, offset: Offset(0, 4)),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: SafeArea(
                      top: false,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(10, 10, 6, 8),
                            child: Row(
                              children: [
                                Hero(
                                  tag: 'now-art',
                                  child: Art(albumId: song.albumId, size: 52),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: AnimatedSwitcher(
                                    layoutBuilder: (current, previous) => Stack(
                                      alignment: Alignment.centerLeft,
                                      children: [...previous, ?current],
                                    ),
                                    duration: motion(scope.settings, 300),
                                    transitionBuilder: (child, a) => FadeTransition(
                                      opacity: a,
                                      child: SlideTransition(
                                        position: Tween(
                                          begin: const Offset(0, 0.3),
                                          end: Offset.zero,
                                        ).animate(a),
                                        child: child,
                                      ),
                                    ),
                                    child: Column(
                                      key: ValueKey(song.id),
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          song.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                                        ),
                                        Text(
                                          song.artist,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                BigIconButton(icon: Icons.skip_previous_rounded, size: 52, onTap: p.previous),
                                PlayPauseButton(size: 52, background: cs.primary, foreground: cs.onPrimary),
                                BigIconButton(icon: Icons.skip_next_rounded, size: 52, onTap: p.next),
                              ],
                            ),
                          ),
                          ValueListenableBuilder(
                            valueListenable: p.position,
                            builder: (context, pos, _) => LinearProgressIndicator(
                              value: p.duration.inMilliseconds == 0
                                  ? 0
                                  : (pos.inMilliseconds / p.duration.inMilliseconds).clamp(0, 1),
                              minHeight: 3,
                              backgroundColor: Colors.transparent,
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
