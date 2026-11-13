import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../core/scope.dart';
import '../widgets/art.dart';
import '../widgets/menus.dart';
import '../widgets/mini_player.dart';
import '../widgets/tiles.dart';
import 'library_view.dart';

/// An album, artist, genre, year, folder or playlist.
class CollectionScreen extends StatelessWidget {
  final Collection collection;
  const CollectionScreen({super.key, required this.collection});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    // A playlist follows its changes (a song removed, a new cover).
    if (collection.kind == CollectionKind.playlist) {
      return ListenableBuilder(
        listenable: scope.playlists,
        builder: (context, _) {
          final live = scope.playlists
              .collections(scope.library.byId)
              .where((x) => x.key == collection.key)
              .firstOrNull;
          // Deleted while open: leave.
          if (live == null) return const SizedBox.shrink();
          return _build(context, live);
        },
      );
    }
    return _build(context, collection);
  }

  Widget _build(BuildContext context, Collection c) {
    final scope = AppScope.of(context);
    final wide = MediaQuery.sizeOf(context).width > MediaQuery.sizeOf(context).height;
    final isAlbum = c.kind == CollectionKind.album;
    final albums = c.kind == CollectionKind.artist ? scope.library.albumsBy(c.title) : const <Collection>[];
    final playlist = c.kind == CollectionKind.playlist ? scope.playlists.byKey(c.key) : null;

    void play(int i) {
      scope.player.playAll(c.songs, start: i);
      if (scope.settings.openPlayerOnPlay) PlayerSheet.open(context);
    }

    final header = _Header(collection: c, wide: wide);
    final list = <Widget>[
      if (albums.length > 1) ...[
        const SectionHeader('Albums'),
        SizedBox(
          // A 160-wide card: its cover plus room for its text at this size.
          height: 160 - 12 + cardTextRoom(context),
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            itemCount: albums.length,
            itemBuilder: (context, i) => SizedBox(
              width: 160,
              child: CollectionCard(item: albums[i], onTap: () => openCollection(context, albums[i])),
            ),
          ),
        ),
        const SectionHeader('Songs'),
      ],
      for (var i = 0; i < c.songs.length; i++)
        SongTile(
          song: c.songs[i],
          number: isAlbum ? c.songs[i].track : null,
          onTap: () => play(i),
          trailing: playlist == null
              ? null
              : IconButton(
                  icon: const Icon(Icons.remove_circle_outline_rounded),
                  tooltip: 'Remove from playlist',
                  onPressed: () => scope.playlists.remove(playlist, c.songs[i].id),
                ),
        ),
      const SizedBox(height: 120),
    ];

    return Scaffold(
      appBar: AppBar(
        title: wide ? Text(c.title) : null,
        actions: [
          IconButton(icon: const Icon(Icons.more_vert), onPressed: () => showCollectionMenu(context, c)),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 340, child: SingleChildScrollView(child: header)),
                      Expanded(child: ListView(children: list)),
                    ],
                  )
                : ListView(children: [header, ...list]),
          ),
          const MiniPlayer(),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final Collection collection;
  final bool wide;
  const _Header({required this.collection, required this.wide});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final c = collection;
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final size = wide ? 260.0 : 220.0;
    final info = [
      if (c.kind == CollectionKind.album) c.songs.first.albumArtist,
      if (c.kind == CollectionKind.album && c.year > 0) '${c.year}',
      plural(c.songs.length, 'song'),
      total(c.duration),
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Column(
        children: [
          Hero(
            tag: 'art-${c.kind.name}-${c.key}',
            child: c.kind == CollectionKind.folder
                ? Icon(Icons.folder_rounded, size: size * 0.6, color: cs.primary)
                : Art(
                    albumId: c.artAlbumId,
                    size: size,
                    radius: c.kind == CollectionKind.artist ? size / 2 : null,
                    file: c.coverPath,
                  ),
          ),
          const SizedBox(height: 16),
          Text(
            c.title,
            textAlign: TextAlign.center,
            style: tt.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            info,
            textAlign: TextAlign.center,
            style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: c.songs.isEmpty ? null : () => scope.player.playAll(c.songs),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Play'),
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 56)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: c.songs.isEmpty ? null : () => scope.player.playAll(c.songs, shuffled: true),
                  icon: const Icon(Icons.shuffle_rounded),
                  label: const Text('Shuffle'),
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 56)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
