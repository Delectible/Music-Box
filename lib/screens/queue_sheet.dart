import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/scope.dart';
import '../widgets/art.dart';
import '../widgets/tiles.dart';

/// The queue: tap to jump, drag to reorder, swipe away to remove.
Future<void> showQueue(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  constraints: const BoxConstraints(maxWidth: 760),
  builder: (_) => const FractionallySizedBox(heightFactor: 0.85, child: _Queue()),
);

class _Queue extends StatefulWidget {
  const _Queue();
  @override
  State<_Queue> createState() => _QueueState();
}

class _QueueState extends State<_Queue> {
  late final ScrollController _scroll;

  @override
  void initState() {
    super.initState();
    final p = AppScope.of(context).player;
    _scroll = ScrollController(initialScrollOffset: (p.index * 72.0 - 72).clamp(0, double.infinity));
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = AppScope.of(context).player;
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        final left = p.queue.skip(p.index).fold(Duration.zero, (a, s) => a + s.duration);
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Queue · ${plural(p.queue.length, 'song')} · ${total(left)} left',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Shuffle',
                    isSelected: p.shuffle,
                    icon: const Icon(Icons.shuffle_rounded),
                    onPressed: () => p.setShuffle(!p.shuffle),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ReorderableListView.builder(
                scrollController: _scroll,
                itemCount: p.queue.length,
                buildDefaultDragHandles: false,
                onReorderItem: p.move,
                itemBuilder: (context, i) {
                  final s = p.queue[i];
                  final now = i == p.index;
                  return Dismissible(
                    key: ValueKey('q$i-${s.id}'),
                    direction: now ? DismissDirection.none : DismissDirection.endToStart,
                    onDismissed: (_) => p.removeAt(i),
                    background: Container(
                      color: cs.errorContainer,
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 24),
                      child: Icon(Icons.delete_outline_rounded, color: cs.onErrorContainer),
                    ),
                    child: Material(
                      color: now ? cs.primary.withValues(alpha: 0.12) : Colors.transparent,
                      child: ListTile(
                        minTileHeight: 72,
                        onTap: () => p.jumpTo(i),
                        leading: now
                            ? SizedBox.square(
                                dimension: 48,
                                child: Center(
                                  child: Equaliser(playing: p.playing, color: cs.primary, size: 24),
                                ),
                              )
                            : Opacity(
                                opacity: i < p.index ? 0.5 : 1,
                                child: Art(albumId: s.albumId, size: 48),
                              ),
                        title: Text(
                          s.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: now ? cs.primary : null, fontWeight: FontWeight.w500),
                        ),
                        subtitle: Text(s.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: ReorderableDragStartListener(
                          index: i,
                          child: const Padding(
                            padding: EdgeInsets.all(12),
                            child: Icon(Icons.drag_handle_rounded),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
