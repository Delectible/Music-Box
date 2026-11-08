import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/scope.dart';
import '../widgets/menus.dart';
import '../widgets/mini_player.dart';
import '../widgets/tiles.dart';

void openSearch(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SearchScreen()));

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final lib = scope.library;
    final q = _q.toLowerCase().trim();
    final songs = lib.search(q);
    final List<Collection> albums = q.isEmpty
        ? const []
        : lib.albums.where((a) => a.title.toLowerCase().contains(q)).take(20).toList();
    final List<Collection> artists = q.isEmpty
        ? const []
        : lib.artists.where((a) => a.title.toLowerCase().contains(q)).take(20).toList();
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        title: TextField(
          autofocus: true,
          style: const TextStyle(fontSize: 22),
          decoration: const InputDecoration(hintText: 'Songs, albums, artists', border: InputBorder.none),
          onChanged: (v) => setState(() => _q = v),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              children: [
                if (artists.isNotEmpty) ...[
                  const SectionHeader('Artists'),
                  for (final a in artists)
                    CollectionTile(item: a, round: true, onTap: () => openCollection(context, a)),
                ],
                if (albums.isNotEmpty) ...[
                  const SectionHeader('Albums'),
                  for (final a in albums) CollectionTile(item: a, onTap: () => openCollection(context, a)),
                ],
                if (songs.isNotEmpty) ...[
                  const SectionHeader('Songs'),
                  for (var i = 0; i < songs.length; i++)
                    SongTile(
                      song: songs[i],
                      onTap: () => scope.player.playAll(songs, start: i),
                    ),
                ],
                if (q.isNotEmpty && songs.isEmpty && albums.isEmpty && artists.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(40),
                    child: Center(child: Text('Nothing found')),
                  ),
              ],
            ),
          ),
          const MiniPlayer(),
        ],
      ),
    );
  }
}
