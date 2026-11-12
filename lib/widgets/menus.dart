import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/scope.dart';
import '../screens/collection_screen.dart';
import '../screens/podcast_screen.dart';
import '../screens/file_actions.dart';
import '../screens/fix_tags_sheet.dart';
import '../screens/song_info_screen.dart';
import 'art.dart';

void openCollection(BuildContext context, Collection c) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) =>
        c.kind == CollectionKind.podcast ? PodcastScreen(show: c) : CollectionScreen(collection: c),
  ),
);

void _toast(BuildContext context, String text) => ScaffoldMessenger.of(context)
  ..hideCurrentSnackBar()
  ..showSnackBar(
    SnackBar(content: Text(text), behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 2)),
  );

Future<void> showSongMenu(BuildContext context, Song song) {
  final scope = AppScope.of(context);
  return _sheet(
    context,
    header: ListTile(
      leading: Art(albumId: song.albumId, size: 52),
      title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${song.artist} · ${song.album}', maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
    items: [
      (
        Icons.playlist_play_rounded,
        'Play next',
        () {
          scope.player.playNext([song]);
          _toast(context, 'Plays next');
        },
      ),
      (
        Icons.queue_music_rounded,
        'Add to queue',
        () {
          scope.player.addToQueue([song]);
          _toast(context, 'Added to queue');
        },
      ),
      (
        scope.playlists.isFavourite(song.id) ? Icons.favorite_rounded : Icons.favorite_border_rounded,
        scope.playlists.isFavourite(song.id) ? 'Remove from Favourites' : 'Add to Favourites',
        () => scope.playlists.toggleFavourite(song.id),
      ),
      (Icons.playlist_add_rounded, 'Add to playlist…', () => addToPlaylist(context, [song])),
      (
        Icons.album_rounded,
        'Go to album',
        () {
          final a = scope.library.album(song.albumId);
          if (a != null) openCollection(context, a);
        },
      ),
      (
        Icons.person_rounded,
        'Go to artist',
        () {
          final a = scope.library.artist(song.artist);
          if (a != null) openCollection(context, a);
        },
      ),
      if (song.podcast)
        (
          scope.player.isPlayed(song.id) ? Icons.remove_done_rounded : Icons.done_all_rounded,
          scope.player.isPlayed(song.id) ? 'Mark as not played' : 'Mark as played',
          () => scope.player.markPlayed(song.id, !scope.player.isPlayed(song.id)),
        ),
      (Icons.info_outline_rounded, 'Song info', () => openSongInfo(context, song)),
      (
        Icons.edit_rounded,
        'Edit tags…',
        () => editTags(context, [song], what: '${song.title} · ${song.artist}'),
      ),
      (Icons.auto_fix_high_rounded, 'Fix tags…', () => showFixTags(context, song)),
      (
        Icons.delete_outline_rounded,
        'Delete from device…',
        () => deleteSongs(context, [song], what: '"${song.title}"'),
      ),
    ],
  );
}

Future<void> showCollectionMenu(BuildContext context, Collection c) {
  final scope = AppScope.of(context);
  final playlist = c.kind == CollectionKind.playlist ? scope.playlists.byKey(c.key) : null;
  return _sheet(
    context,
    header: ListTile(
      leading: Art(albumId: c.artAlbumId, size: 52),
      title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(c.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
    items: [
      (Icons.play_arrow_rounded, 'Play', () => scope.player.playAll(c.songs)),
      (Icons.shuffle_rounded, 'Shuffle', () => scope.player.playAll(c.songs, shuffled: true)),
      (
        Icons.playlist_play_rounded,
        'Play next',
        () {
          scope.player.playNext(c.songs);
          _toast(context, 'Plays next');
        },
      ),
      (
        Icons.queue_music_rounded,
        'Add to queue',
        () {
          scope.player.addToQueue(c.songs);
          _toast(context, 'Added to queue');
        },
      ),
      if (c.kind != CollectionKind.playlist)
        (Icons.playlist_add_rounded, 'Add to playlist…', () => addToPlaylist(context, c.songs)),
      (Icons.edit_rounded, 'Edit tags…', () => editTags(context, c.songs, what: c.title)),
      (Icons.auto_fix_high_rounded, 'Fix tags', () => fixTagsFor(context, c.songs, onlyIncomplete: false)),
      if (c.kind == CollectionKind.album ||
          c.kind == CollectionKind.folder ||
          c.kind == CollectionKind.podcast)
        (
          Icons.delete_outline_rounded,
          c.kind == CollectionKind.album ? 'Delete album from device…' : 'Delete from device…',
          () => deleteSongs(context, c.songs, what: '"${c.title}" (${c.songs.length} songs)'),
        ),
      if (playlist != null && playlist.id != 'fav') ...[
        (
          Icons.edit_rounded,
          'Rename',
          () => _renamePlaylist(context, playlist.name, (n) => scope.playlists.rename(playlist, n)),
        ),
        (Icons.delete_outline_rounded, 'Delete playlist', () => scope.playlists.delete(playlist)),
      ],
    ],
  );
}

Future<void> _sheet(
  BuildContext context, {
  required Widget header,
  required List<(IconData, String, VoidCallback)> items,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  constraints: const BoxConstraints(maxWidth: 640),
  builder: (sheet) => SafeArea(
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          header,
          const Divider(),
          for (final (icon, label, action) in items)
            ListTile(
              leading: Icon(icon),
              title: Text(label),
              minTileHeight: 60,
              onTap: () {
                Navigator.pop(sheet);
                action();
              },
            ),
        ],
      ),
    ),
  ),
);

Future<void> addToPlaylist(BuildContext context, List<Song> songs) async {
  final scope = AppScope.of(context);
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (sheet) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            leading: const Icon(Icons.add_rounded),
            title: const Text('New playlist'),
            minTileHeight: 60,
            onTap: () {
              Navigator.pop(sheet);
              _renamePlaylist(context, '', (name) {
                scope.playlists.add(scope.playlists.create(name), songs);
                _toast(context, 'Added to $name');
              });
            },
          ),
          for (final p in scope.playlists.all)
            ListTile(
              leading: Icon(p.id == 'fav' ? Icons.favorite_rounded : Icons.queue_music_rounded),
              title: Text(p.name),
              subtitle: Text('${p.songIds.length} songs'),
              minTileHeight: 60,
              onTap: () {
                Navigator.pop(sheet);
                scope.playlists.add(p, songs);
                _toast(context, 'Added to ${p.name}');
              },
            ),
        ],
      ),
    ),
  );
}

Future<void> _renamePlaylist(BuildContext context, String initial, void Function(String) done) async {
  final ctrl = TextEditingController(text: initial);
  final name = await showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(initial.isEmpty ? 'New playlist' : 'Rename playlist'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Name'),
        onSubmitted: (v) => Navigator.pop(d, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(d, ctrl.text), child: const Text('Save')),
      ],
    ),
  );
  ctrl.dispose();
  if (name != null && name.trim().isNotEmpty) done(name.trim());
}
