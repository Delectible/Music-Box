import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../core/scope.dart';
import '../widgets/art.dart';
import '../widgets/menus.dart';
import '../widgets/mini_player.dart';
import '../widgets/tiles.dart';
import 'library_view.dart';

/// Episodes in [order]: newest / oldest (episode number, then when added),
/// by number, or by title.
List<Song> sortEpisodes(List<Song> eps, String order) {
  int when(Song a, Song b) {
    final n = a.track.compareTo(b.track);
    if (a.track > 0 && b.track > 0 && n != 0) return n;
    final y = a.year.compareTo(b.year);
    return y != 0 ? y : a.added.compareTo(b.added);
  }

  final out = [...eps];
  switch (order) {
    case 'oldest':
      out.sort(when);
    case 'number':
      out.sort((a, b) {
        final n = a.track.compareTo(b.track);
        return n != 0 ? n : when(a, b);
      });
    case 'title':
      out.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    default:
      out.sort((a, b) => when(b, a));
  }
  return out;
}

/// One podcast: its episodes, sorted and filtered, played / unplayed.
class PodcastScreen extends StatelessWidget {
  final Collection show;
  const PodcastScreen({super.key, required this.show});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final s = scope.settings;
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final wide = MediaQuery.sizeOf(context).width > MediaQuery.sizeOf(context).height;
    return ListenableBuilder(
      listenable: Listenable.merge([s, scope.library, scope.player]),
      builder: (context, _) {
        // The show as it is now (episodes added or removed since it opened).
        final now = scope.library.podcasts.where((p) => p.key == show.key).firstOrNull ?? show;
        final p = scope.player;
        final all = sortEpisodes(now.songs, s.episodeOrder);
        final unplayed = all.where((e) => !p.isPlayed(e.id)).length;
        final eps = s.unplayedOnly ? all.where((e) => !p.isPlayed(e.id)).toList() : all;

        void play(int i) {
          p.playAll(eps, start: i);
          if (s.openPlayerOnPlay) PlayerSheet.open(context);
        }

        final info = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(now.title, style: tt.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
            if (now.songs.first.albumArtist.isNotEmpty)
              Text(now.songs.first.albumArtist, style: tt.titleMedium),
            const SizedBox(height: 4),
            Text(
              '${plural(now.songs.length, 'episode')} · $unplayed unplayed · ${total(now.duration)}',
              style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size(150, 52)),
                  onPressed: eps.isEmpty ? null : () => play(0),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Play'),
                ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(52, 52)),
                  onPressed: () => showCollectionMenu(context, now),
                  icon: const Icon(Icons.more_horiz_rounded),
                  label: const Text('More'),
                ),
              ],
            ),
          ],
        );
        final header = Padding(
          padding: const EdgeInsets.all(20),
          child: wide
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Art(albumId: now.artAlbumId, size: 260),
                    const SizedBox(height: 16),
                    info,
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Art(albumId: now.artAlbumId, size: 120),
                    const SizedBox(width: 20),
                    Expanded(child: info),
                  ],
                ),
        );

        final controls = Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final (k, label) in const [
                ('newest', 'Newest'),
                ('oldest', 'Oldest'),
                ('number', 'Episode number'),
                ('title', 'Title'),
              ])
                ChoiceChip(
                  label: Text(label),
                  selected: s.episodeOrder == k,
                  onSelected: (_) => s.episodeOrder = k,
                ),
              FilterChip(
                label: const Text('Unplayed only'),
                selected: s.unplayedOnly,
                onSelected: (v) => s.unplayedOnly = v,
              ),
            ],
          ),
        );

        final list = <Widget>[
          controls,
          if (eps.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: Text('All played')),
            ),
          for (var i = 0; i < eps.length; i++)
            SongTile(
              song: eps[i],
              showArt: false,
              number: eps[i].track > 0 ? eps[i].track : null,
              onTap: () => play(i),
              trailing: _EpisodeState(song: eps[i]),
            ),
          const SizedBox(height: 120),
        ];

        return Scaffold(
          appBar: AppBar(title: wide ? Text(now.title) : null),
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
      },
    );
  }
}

/// Played (tick), part-heard (ring and time left) or new.
class _EpisodeState extends StatelessWidget {
  final Song song;
  const _EpisodeState({required this.song});

  @override
  Widget build(BuildContext context) {
    final p = AppScope.of(context).player;
    final cs = Theme.of(context).colorScheme;
    if (p.isPlayed(song.id)) {
      return Tooltip(
        message: 'Played',
        child: Icon(Icons.check_circle_rounded, color: cs.primary),
      );
    }
    final at = p.resumeAt(song.id);
    if (at == null || song.duration == Duration.zero) return const SizedBox(width: 24);
    final left = song.duration - at;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('${left.inMinutes} min left', style: TextStyle(color: cs.onSurfaceVariant)),
        const SizedBox(width: 8),
        SizedBox.square(
          dimension: 22,
          child: CircularProgressIndicator(
            value: (at.inMilliseconds / song.duration.inMilliseconds).clamp(0, 1),
            strokeWidth: 3,
            backgroundColor: cs.onSurface.withValues(alpha: 0.12),
          ),
        ),
      ],
    );
  }
}
