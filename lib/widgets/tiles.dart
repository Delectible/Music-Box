import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../core/scope.dart';
import 'art.dart';
import 'menus.dart';

/// A song row. The playing song is marked with a moving equaliser.
class SongTile extends StatelessWidget {
  final Song song;
  final VoidCallback onTap;
  final bool compact;
  final bool showArt;
  final int? number; // track number instead of a cover (album view)
  final Widget? trailing;

  const SongTile({
    super.key,
    required this.song,
    required this.onTap,
    this.compact = false,
    this.showArt = true,
    this.number,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: scope.player,
      builder: (context, _) {
        final now = scope.player.current?.id == song.id;
        final artSize = compact ? 40.0 : 56.0;
        return InkWell(
          onTap: onTap,
          onLongPress: () => showSongMenu(context, song),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: compact ? 6 : 8),
            child: Row(
              children: [
                if (number != null)
                  SizedBox(
                    width: 40,
                    child: now
                        ? Equaliser(playing: scope.player.playing, color: cs.primary)
                        : Text(
                            '$number',
                            textAlign: TextAlign.center,
                            style: tt.titleMedium?.copyWith(color: cs.onSurfaceVariant),
                          ),
                  )
                else if (showArt)
                  Stack(
                    children: [
                      Art(albumId: song.albumId, size: artSize),
                      if (now)
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.black45,
                              borderRadius: BorderRadius.circular(artSize * 0.1),
                            ),
                            child: Center(
                              child: Equaliser(playing: scope.player.playing, color: Colors.white),
                            ),
                          ),
                        ),
                    ],
                  ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: (compact ? tt.titleSmall : tt.titleMedium)?.copyWith(
                          color: now ? cs.primary : null,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (!compact || number == null)
                        Text(
                          number != null ? song.artist : '${song.artist} · ${song.album}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(clock(song.duration), style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                trailing ??
                    IconButton(
                      icon: const Icon(Icons.more_vert),
                      onPressed: () => showSongMenu(context, song),
                    ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Three bouncing bars while playing; still bars while paused.
class Equaliser extends StatefulWidget {
  final bool playing;
  final Color color;
  final double size;
  const Equaliser({super.key, required this.playing, required this.color, this.size = 20});

  @override
  State<Equaliser> createState() => _EqualiserState();
}

class _EqualiserState extends State<Equaliser> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(Equaliser old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final on = widget.playing && AppScope.of(context).settings.animations;
    if (on && !_c.isAnimating) _c.repeat();
    if (!on && _c.isAnimating) _c.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value * 6.283;
        double h(double phase, double speed) => 0.3 + 0.7 * (0.5 + 0.5 * _sin(t * speed + phase));
        final hs = [h(0, 2), h(2, 3), h(4, 2.5)];
        return SizedBox.square(
          dimension: widget.size,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final v in hs)
                Container(
                  width: widget.size / 5,
                  height: widget.size * v,
                  decoration: BoxDecoration(color: widget.color, borderRadius: BorderRadius.circular(2)),
                ),
            ],
          ),
        );
      },
    );
  }

  static double _sin(double x) {
    // Cheap sine, good enough for bars.
    x = (x % 6.283185) - 3.141593;
    return -(1.27323954 * x + (x < 0 ? 0.405284735 : -0.405284735) * x * x);
  }
}

/// A row for an album, artist, genre, folder or playlist.
class CollectionTile extends StatelessWidget {
  final Collection item;
  final VoidCallback onTap;
  final bool compact;
  final bool round;

  const CollectionTile({
    super.key,
    required this.item,
    required this.onTap,
    this.compact = false,
    this.round = false,
  });

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final size = compact ? 44.0 : 64.0;
    return InkWell(
      onTap: onTap,
      onLongPress: () => showCollectionMenu(context, item),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: compact ? 6 : 8),
        child: Row(
          children: [
            item.kind == CollectionKind.folder
                ? SizedBox.square(
                    dimension: size,
                    child: Icon(Icons.folder_rounded, size: size * 0.7, color: cs.primary),
                  )
                : Art(
                    albumId: item.artAlbumId,
                    size: size,
                    radius: round ? size / 2 : null,
                    file: item.coverPath,
                  ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w500),
                  ),
                  Text(
                    item.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            IconButton(icon: const Icon(Icons.more_vert), onPressed: () => showCollectionMenu(context, item)),
          ],
        ),
      ),
    );
  }
}

/// A grid square with the title underneath.
class CollectionCard extends StatelessWidget {
  final Collection item;
  final VoidCallback onTap;
  final bool round;

  const CollectionCard({super.key, required this.item, required this.onTap, this.round = false});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      onLongPress: () => showCollectionMenu(context, item),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: LayoutBuilder(
          builder: (context, c) => Column(
            crossAxisAlignment: round ? CrossAxisAlignment.center : CrossAxisAlignment.start,
            children: [
              item.kind == CollectionKind.folder
                  ? SizedBox.square(
                      dimension: c.maxWidth,
                      child: Icon(Icons.folder_rounded, size: c.maxWidth * 0.7, color: cs.primary),
                    )
                  : Hero(
                      tag: 'art-${item.kind.name}-${item.key}',
                      child: Art(
                        albumId: item.artAlbumId,
                        size: c.maxWidth,
                        radius: round ? c.maxWidth / 2 : null,
                        file: item.coverPath,
                      ),
                    ),
              const SizedBox(height: 8),
              Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
              Text(
                item.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A wide tile with the cover's colour behind the title: genres, playlists.
class BigCard extends StatelessWidget {
  final Collection item;
  final VoidCallback onTap;
  const BigCard({super.key, required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = albumHue(item.artAlbumId < 0 ? item.key.hashCode % 97 : item.artAlbumId);
    final dark = HSLColor.fromColor(c).withLightness(0.28).toColor();
    return Material(
      color: dark,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: () => showCollectionMenu(context, item),
        child: LayoutBuilder(
          builder: (context, box) => Stack(
            children: [
              Positioned(
                right: -box.maxHeight * 0.18,
                bottom: -box.maxHeight * 0.18,
                child: Transform.rotate(
                  angle: 0.35,
                  child: Art(albumId: item.artAlbumId, size: box.maxHeight * 0.9, file: item.coverPath),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                        height: 1.1,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(item.subtitle, style: const TextStyle(color: Colors.white70, fontSize: 14)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Section header in a long list (A, B, C ... or a year).
class SectionHeader extends StatelessWidget {
  final String text;
  const SectionHeader(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
      child: Text(
        text,
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: cs.primary, letterSpacing: 0.5),
      ),
    );
  }
}

/// How tall [style] text is at the current text size ([lines] of it).
double textHeight(BuildContext context, TextStyle? style, {int lines = 1}) {
  final tp = TextPainter(
    // In the app's own font (Jost), as the real text is.
    text: TextSpan(text: 'Ág', style: DefaultTextStyle.of(context).style.merge(style)),
    textScaler: MediaQuery.textScalerOf(context),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  final h = tp.height * lines;
  tp.dispose();
  return h;
}

/// The room under a [CollectionCard]'s cover for its two lines of text.
double cardTextRoom(BuildContext context) {
  final tt = Theme.of(context).textTheme;
  return 12 +
      8 +
      textHeight(context, tt.titleSmall?.copyWith(fontWeight: FontWeight.w600)) +
      textHeight(context, tt.bodySmall) +
      8;
}

/// The least height a [BigCard] needs for its title and subtitle.
double bigCardRoom(BuildContext context) =>
    32 +
    textHeight(context, const TextStyle(fontSize: 22, fontWeight: FontWeight.w600, height: 1.1), lines: 2) +
    4 +
    textHeight(context, const TextStyle(fontSize: 14)) +
    10;

/// A grid whose rows are as tall as their tiles need: [ratio] of the tile's
/// width (at least [min]), plus [below] for the text under it. Fixed shapes
/// let text run into the next row at large text sizes.
class FitGrid extends SliverGridDelegate {
  final int columns;
  final double spacing, crossSpacing, ratio, below, min;
  const FitGrid({
    required this.columns,
    this.spacing = 0,
    this.crossSpacing = 0,
    this.ratio = 1,
    this.below = 0,
    this.min = 0,
  });

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final w = (constraints.crossAxisExtent - crossSpacing * (columns - 1)) / columns;
    final h = (w * ratio < min ? min : w * ratio) + below;
    return SliverGridRegularTileLayout(
      crossAxisCount: columns,
      mainAxisStride: h + spacing,
      crossAxisStride: w + crossSpacing,
      childMainAxisExtent: h,
      childCrossAxisExtent: w,
      reverseCrossAxis: axisDirectionIsReversed(constraints.crossAxisDirection),
    );
  }

  @override
  bool shouldRelayout(FitGrid old) =>
      old.columns != columns ||
      old.spacing != spacing ||
      old.crossSpacing != crossSpacing ||
      old.ratio != ratio ||
      old.below != below ||
      old.min != min;
}
