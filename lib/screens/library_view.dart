import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/scope.dart';
import '../core/smart.dart';
import '../core/sorting.dart';
import '../widgets/menus.dart';
import '../widgets/tiles.dart';

/// One library tab's list, drawn the way its view options say.
class LibraryView extends StatefulWidget {
  final LibraryTab tab;
  const LibraryView({super.key, required this.tab});

  @override
  State<LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends State<LibraryView> with AutomaticKeepAliveClientMixin {
  final _scroll = ScrollController();

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scope = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([scope.library, scope.settings, scope.playlists]),
      builder: (context, _) {
        final opts = scope.settings.view(widget.tab);
        final lib = scope.library;
        final slivers = <Widget>[];
        if (widget.tab == LibraryTab.songs) {
          final songs = sortSongs(lib.songs, opts.sort, opts.descending, scope.player);
          slivers.add(SliverToBoxAdapter(child: _PlayBar(songs: songs)));
          final favs = [for (final id in scope.playlists.favs.songIds) ?lib.byId[id]];
          if (scope.settings.favouritesShelf && favs.isNotEmpty) {
            slivers.add(
              SliverToBoxAdapter(
                child: _Shelf(
                  title: 'Favourites',
                  icon: Icons.favorite_rounded,
                  onPlay: () => scope.player.playAll(favs),
                  items: [
                    for (final s in favs)
                      Collection(
                        kind: CollectionKind.album,
                        key: 'fav${s.id}',
                        title: s.title,
                        subtitle: s.artist,
                        songs: [s],
                        artAlbumId: s.albumId,
                      ),
                  ],
                  onTap: (i) => scope.player.playAll(favs, start: i),
                ),
              ),
            );
          }
          slivers.addAll(_songSlivers(context, songs, opts));
        } else {
          final items = switch (widget.tab) {
            LibraryTab.albums => lib.albums,
            LibraryTab.artists => lib.artists,
            LibraryTab.genres => lib.genres,
            LibraryTab.years => lib.years,
            LibraryTab.folders => lib.folders,
            LibraryTab.playlists => scope.playlists.collections(lib.byId),
            LibraryTab.podcasts => lib.podcasts,
            _ => const <Collection>[],
          };
          final sorted = sortCollections(items, opts.sort, opts.descending, scope.player);
          if (widget.tab == LibraryTab.playlists) {
            final smart = smartPlaylists(lib, scope.player, scope.playlists);
            if (smart.isNotEmpty) {
              slivers.add(
                SliverToBoxAdapter(
                  child: _Shelf(
                    title: 'Smart playlists',
                    icon: Icons.auto_awesome_rounded,
                    items: smart,
                    onTap: (i) => openCollection(context, smart[i]),
                  ),
                ),
              );
              slivers.add(const SliverToBoxAdapter(child: SectionHeader('Your playlists')));
            }
          }
          slivers.addAll(_collectionSlivers(context, sorted, opts));
        }
        slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 120)));
        return Scrollbar(
          controller: _scroll,
          interactive: true,
          thickness: 10,
          radius: const Radius.circular(5),
          child: CustomScrollView(controller: _scroll, slivers: slivers),
        );
      },
    );
  }

  List<Widget> _songSlivers(BuildContext context, List<Song> songs, ViewOptions opts) {
    final scope = AppScope.of(context);
    final compact = opts.mode == ViewMode.compact;
    void play(int i) {
      scope.player.playAll(songs, start: i);
      if (scope.settings.openPlayerOnPlay) PlayerSheet.open(context);
    }

    if (opts.mode == ViewMode.grid || opts.mode == ViewMode.cards) {
      // Songs as covers: a quick-pick wall for the car.
      return [
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          sliver: SliverGrid.builder(
            gridDelegate: _grid(context, opts, big: opts.mode == ViewMode.cards),
            itemCount: songs.length,
            itemBuilder: (context, i) {
              final s = songs[i];
              return CollectionCard(
                item: Collection(
                  kind: CollectionKind.album,
                  key: 'song${s.id}',
                  title: s.title,
                  subtitle: s.artist,
                  songs: [s],
                  artAlbumId: s.albumId,
                ),
                onTap: () => play(i),
              );
            },
          ),
        ),
      ];
    }
    final headers = opts.headers ? _headers(songs.length, (i) => _songSection(songs[i], opts.sort)) : null;
    return [
      SliverList.builder(
        itemCount: songs.length,
        itemBuilder: (context, i) {
          final tile = SongTile(song: songs[i], compact: compact, onTap: () => play(i));
          final h = headers?[i];
          return h == null
              ? tile
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [SectionHeader(h), tile]);
        },
      ),
    ];
  }

  List<Widget> _collectionSlivers(BuildContext context, List<Collection> items, ViewOptions opts) {
    final round = widget.tab == LibraryTab.artists;
    if (items.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Text(
              switch (widget.tab) {
                LibraryTab.playlists => 'No playlists yet',
                LibraryTab.podcasts => 'No podcasts yet. Find some in Get music › Podcasts.',
                _ => 'Nothing here yet',
              },
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ),
      ];
    }
    switch (opts.mode) {
      case ViewMode.list || ViewMode.compact:
        final headers = opts.headers
            ? _headers(items.length, (i) => _collectionSection(items[i], opts.sort))
            : null;
        return [
          SliverList.builder(
            itemCount: items.length,
            itemBuilder: (context, i) {
              final tile = CollectionTile(
                item: items[i],
                compact: opts.mode == ViewMode.compact,
                round: round,
                onTap: () => openCollection(context, items[i]),
              );
              final h = headers?[i];
              return h == null
                  ? tile
                  : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [SectionHeader(h), tile]);
            },
          ),
        ];
      case ViewMode.grid:
        return [
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            sliver: SliverGrid.builder(
              gridDelegate: _grid(context, opts),
              itemCount: items.length,
              itemBuilder: (context, i) => CollectionCard(
                item: items[i],
                round: round,
                onTap: () => openCollection(context, items[i]),
              ),
            ),
          ),
        ];
      case ViewMode.cards:
        final w = MediaQuery.sizeOf(context).width;
        return [
          SliverPadding(
            padding: const EdgeInsets.all(14),
            sliver: SliverGrid.builder(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: opts.columns > 0 ? opts.columns : (w / 320).ceil().clamp(1, 6),
                mainAxisSpacing: 14,
                crossAxisSpacing: 14,
                childAspectRatio: 1.9,
              ),
              itemCount: items.length,
              itemBuilder: (context, i) =>
                  BigCard(item: items[i], onTap: () => openCollection(context, items[i])),
            ),
          ),
        ];
    }
  }

  SliverGridDelegate _grid(BuildContext context, ViewOptions opts, {bool big = false}) {
    final w = MediaQuery.sizeOf(context).width;
    final cols = opts.columns > 0 ? opts.columns : (w / (big ? 260 : 170)).floor().clamp(2, 8);
    return SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: cols, childAspectRatio: 0.78);
  }

  /// Header text where a new section starts, keyed by index.
  Map<int, String> _headers(int n, String? Function(int) section) {
    final out = <int, String>{};
    String? last;
    for (var i = 0; i < n; i++) {
      final s = section(i);
      if (s != null && s != last) out[i] = s;
      last = s;
    }
    return out;
  }

  String? _songSection(Song s, SortKey k) => sectionOf(
    k,
    title: s.title,
    artist: k == SortKey.albumArtist ? s.albumArtist : s.artist,
    album: s.album,
    year: s.year,
  );

  String? _collectionSection(Collection c, SortKey k) =>
      sectionOf(k == SortKey.artist ? SortKey.artist : k, title: c.title, artist: c.subtitle, year: c.year);
}

/// Play all / shuffle at the top of Songs.
class _PlayBar extends StatelessWidget {
  final List<Song> songs;
  const _PlayBar({required this.songs});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          FilledButton.icon(
            onPressed: songs.isEmpty ? null : () => scope.player.playAll(songs, shuffled: true),
            icon: const Icon(Icons.shuffle_rounded),
            label: const Text('Shuffle all'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 52),
              padding: const EdgeInsets.symmetric(horizontal: 22),
            ),
          ),
          const SizedBox(width: 10),
          OutlinedButton.icon(
            onPressed: songs.isEmpty ? null : () => scope.player.playAll(songs),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Play'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 52),
              padding: const EdgeInsets.symmetric(horizontal: 22),
            ),
          ),
          const Spacer(),
          Text('${songs.length} songs', style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}

/// Opens the full screen player (set by the shell).
class PlayerSheet {
  static void Function(BuildContext?)? opener;
  static void open(BuildContext context) => opener?.call(context);
}

/// Sort and view options for a tab, in a bottom sheet.
Future<void> showViewOptions(BuildContext context, LibraryTab tab) {
  final settings = AppScope.of(context).settings;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 720),
    builder: (sheet) => ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final o = settings.view(tab);
        void set(ViewOptions v) => settings.setView(tab, v);
        final tt = Theme.of(context).textTheme;
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${tab.label}: sort and view', style: tt.titleLarge),
                const SizedBox(height: 16),
                Text('Sort by', style: tt.labelLarge),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final k in SortKey.forTab(tab))
                      ChoiceChip(
                        label: Text(k.label),
                        selected: o.sort == k,
                        onSelected: (_) => set(o.copyWith(sort: k, descending: k.descendingByDefault)),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                if (o.sort != SortKey.random)
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(
                        value: false,
                        icon: Icon(Icons.arrow_upward_rounded),
                        label: Text('Ascending'),
                      ),
                      ButtonSegment(
                        value: true,
                        icon: Icon(Icons.arrow_downward_rounded),
                        label: Text('Descending'),
                      ),
                    ],
                    selected: {o.descending},
                    onSelectionChanged: (v) => set(o.copyWith(descending: v.first)),
                  ),
                const SizedBox(height: 20),
                Text('View', style: tt.labelLarge),
                const SizedBox(height: 8),
                SegmentedButton<ViewMode>(
                  segments: [
                    for (final m in ViewMode.values)
                      ButtonSegment(value: m, icon: Icon(_modeIcon(m)), label: Text(m.label)),
                  ],
                  selected: {o.mode},
                  onSelectionChanged: (v) => set(o.copyWith(mode: v.first)),
                ),
                if (o.mode == ViewMode.grid || o.mode == ViewMode.cards) ...[
                  const SizedBox(height: 16),
                  Text('Columns: ${o.columns == 0 ? 'fit screen' : o.columns}', style: tt.labelLarge),
                  Slider(
                    value: o.columns.toDouble(),
                    max: 8,
                    divisions: 8,
                    onChanged: (v) => set(o.copyWith(columns: v.round())),
                  ),
                ],
                if (o.mode == ViewMode.list || o.mode == ViewMode.compact)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Section headers'),
                    subtitle: const Text('A, B, C … or years, when the sort allows'),
                    value: o.headers,
                    onChanged: (v) => set(o.copyWith(headers: v)),
                  ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

IconData _modeIcon(ViewMode m) => switch (m) {
  ViewMode.list => Icons.view_list_rounded,
  ViewMode.compact => Icons.view_headline_rounded,
  ViewMode.grid => Icons.grid_view_rounded,
  ViewMode.cards => Icons.view_module_rounded,
};

/// A row of covers to scroll sideways: favourites, smart playlists.
class _Shelf extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Collection> items;
  final void Function(int) onTap;
  final VoidCallback? onPlay;
  const _Shelf({
    required this.title,
    required this.icon,
    required this.items,
    required this.onTap,
    this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final big = MediaQuery.sizeOf(context).width > 900;
    final w = big ? 170.0 : 140.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 12, 0),
          child: Row(
            children: [
              Icon(icon, color: cs.primary, size: 22),
              const SizedBox(width: 10),
              Text(
                title,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              if (onPlay != null)
                TextButton.icon(
                  onPressed: onPlay,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Play'),
                ),
            ],
          ),
        ),
        SizedBox(
          height: w + 64,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            itemCount: items.length,
            itemBuilder: (context, i) => SizedBox(
              width: w,
              child: CollectionCard(item: items[i], onTap: () => onTap(i)),
            ),
          ),
        ),
      ],
    );
  }
}
