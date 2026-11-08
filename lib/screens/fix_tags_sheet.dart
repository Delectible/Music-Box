import 'dart:async';

import 'package:flutter/material.dart';

import '../core/crash_log.dart';
import '../core/http.dart';
import '../core/metadata.dart';
import '../core/models.dart';
import '../core/scope.dart';
import '../core/tag_fixer.dart';
import '../widgets/art.dart';

/// Look a song up on MusicBrainz and pick the right match.
Future<void> showFixTags(BuildContext context, Song song) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  constraints: const BoxConstraints(maxWidth: 760),
  builder: (_) => FractionallySizedBox(heightFactor: 0.9, child: _FixTags(song: song)),
);

/// Fix the tags of many songs: only clear matches are used.
Future<void> fixTagsFor(BuildContext context, List<Song> songs, {bool onlyIncomplete = true}) async {
  final scope = AppScope.of(context);
  if (!await TagFixer.ensureWrite()) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Roadie needs access to your files to change tags')));
    }
    return;
  }
  unawaited(scope.fixer.fixAll(songs, onlyIncomplete: onlyIncomplete));
  if (context.mounted) await showFixProgress(context);
}

Future<void> showFixProgress(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) {
    final f = AppScope.of(context).fixer;
    return ListenableBuilder(
      listenable: f,
      builder: (context, _) => AlertDialog(
        title: Text(f.running ? 'Fixing tags…' : 'Tags fixed'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (f.running) ...[
              LinearProgressIndicator(value: f.total == 0 ? null : f.done / f.total),
              const SizedBox(height: 12),
              Text(f.current, maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 8),
            ],
            Text(
              '${f.done} of ${f.total} checked · ${f.fixed} fixed · ${f.skipped} left as they were'
              '${f.failed > 0 ? ' · ${f.failed} failed (see Problem reports)' : ''}',
            ),
            if (!f.running && f.skipped > 0)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Songs without a clear match are left alone; fix those one at a time from the song menu.',
                ),
              ),
          ],
        ),
        actions: [
          if (f.running) TextButton(onPressed: f.cancel, child: const Text('Stop')),
          TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(f.running ? 'Hide' : 'Done')),
        ],
      ),
    );
  },
);

class _FixTags extends StatefulWidget {
  final Song song;
  const _FixTags({required this.song});

  @override
  State<_FixTags> createState() => _FixTagsState();
}

class _FixTagsState extends State<_FixTags> {
  final _title = TextEditingController();
  final _artist = TextEditingController();
  final _album = TextEditingController();
  TagValues? _current;
  List<MbMatch>? _results;
  String? _error;
  bool _busy = false;
  String? _applying;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final t = await TagFixer.currentTags(widget.song);
    if (!mounted) return;
    _current = t;
    _title.text = t.title;
    _artist.text = t.artist;
    _album.text = t.album;
    await _search();
  }

  Future<void> _search() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await TagFixer.candidates(
        widget.song,
        query: TagValues(title: _title.text, artist: _artist.text, album: _album.text),
      );
      if (mounted) setState(() => _results = r);
    } on Object catch (e, st) {
      CrashLog.record(e, st, where: 'fix tags search');
      if (mounted) setState(() => _error = 'Couldn\'t reach MusicBrainz: ${friendlyError(e)}');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _apply(MbMatch m) async {
    final lib = AppScope.of(context).library;
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    if (!await TagFixer.ensureWrite()) {
      setState(() => _error = 'Roadie needs access to your files to change tags.');
      return;
    }
    setState(() => _applying = m.releaseId);
    try {
      await TagFixer.apply(widget.song.path, _current ?? const TagValues(), m);
      nav.pop();
      messenger.showSnackBar(SnackBar(content: Text('Tags updated: ${m.title} · ${m.album}')));
      await rescan(lib, [widget.song.path]);
    } on Object catch (e, st) {
      CrashLog.record(e, st, where: 'fix tags apply ${widget.song.path}');
      if (mounted) setState(() => _error = 'Couldn\'t write the file: $e');
    }
    if (mounted) setState(() => _applying = null);
  }

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    _album.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final song = widget.song;
    Widget field(TextEditingController c, String label) => Expanded(
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: TextField(
          controller: c,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
          onSubmitted: (_) => _search(),
        ),
      ),
    );
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        children: [
          ListTile(
            leading: Art(albumId: song.albumId, size: 52),
            title: Text('Fix tags', style: tt.titleLarge),
            subtitle: Text(song.fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                field(_title, 'Title'),
                field(_artist, 'Artist'),
                field(_album, 'Album (optional)'),
                IconButton.filledTonal(
                  tooltip: 'Search',
                  iconSize: 28,
                  onPressed: _busy ? null : _search,
                  icon: const Icon(Icons.search_rounded),
                ),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_error!, style: TextStyle(color: cs.error)),
            ),
          Expanded(
            child: _busy && _results == null
                ? const Center(child: CircularProgressIndicator())
                : (_results ?? const []).isEmpty
                ? Center(
                    child: Text(_busy ? 'Searching…' : 'No matches. Try fewer words or fix the spelling.'),
                  )
                : ListView(
                    padding: const EdgeInsets.only(bottom: 24),
                    children: [
                      for (final m in _results!)
                        ListTile(
                          minTileHeight: 72,
                          leading: _CoverThumb(releaseId: m.releaseId),
                          title: Text(
                            '${m.title} · ${m.artist}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            [
                              m.album,
                              if (m.year.isNotEmpty) m.year,
                              if (m.releaseType.isNotEmpty) m.releaseType,
                              if (m.track > 0)
                                'track ${m.track}${m.trackTotal > 0 ? '/${m.trackTotal}' : ''}',
                              if (m.length != null) _len(m.length!),
                              if (m.genre.isNotEmpty) m.genre,
                            ].join(' · '),
                            maxLines: 2,
                          ),
                          trailing: _applying == m.releaseId
                              ? const SizedBox.square(dimension: 28, child: CircularProgressIndicator())
                              : Text('${m.score}%', style: tt.labelLarge),
                          onTap: _applying == null ? () => _apply(m) : null,
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  static String _len(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
}

class _CoverThumb extends StatelessWidget {
  final String releaseId;
  const _CoverThumb({required this.releaseId});

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(6),
    child: Image.network(
      'https://coverartarchive.org/release/$releaseId/front-250',
      width: 52,
      height: 52,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => Container(
        width: 52,
        height: 52,
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        child: const Icon(Icons.album_rounded),
      ),
    ),
  );
}
