import 'dart:async';

import 'package:flutter/material.dart';

import '../core/crash_log.dart';
import '../core/http.dart';
import '../core/metadata.dart';
import '../core/models.dart';
import '../core/scope.dart';
import '../core/tag_fixer.dart';
import '../widgets/art.dart';

/// Look a song up on MusicBrainz and pick the right match. With [job]
/// (an unsure song from Fix tags) it starts with the matches already found
/// and the pick goes back to that job.
Future<void> showFixTags(BuildContext context, Song song, {FixJob? job}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  constraints: const BoxConstraints(maxWidth: 760),
  builder: (_) => FractionallySizedBox(
    heightFactor: 0.9,
    child: _FixTags(song: song, job: job),
  ),
);

/// Fix the tags of many songs: queued, clear matches written, unsure ones
/// left for you to pick. Opens the Fix tags screen (it keeps going when
/// closed).
Future<void> fixTagsFor(
  BuildContext context,
  List<Song> songs, {
  bool onlyIncomplete = true,
  bool coversOnly = false,
}) async {
  final scope = AppScope.of(context);
  if (!await TagFixer.ensureWrite()) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Roadie needs access to your files to change tags')));
    }
    return;
  }
  scope.fixer.addAll(songs, onlyIncomplete: onlyIncomplete, coversOnly: coversOnly);
  if (context.mounted) openFixQueue(context);
}

void openFixQueue(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const FixQueueScreen()));

/// The top bar's way back to Fix tags while it works or needs you.
class FixTagsButton extends StatelessWidget {
  const FixTagsButton({super.key});

  @override
  Widget build(BuildContext context) {
    final f = AppScope.of(context).fixer;
    return ListenableBuilder(
      listenable: f,
      builder: (context, _) {
        final need = f.needsYou;
        if (!f.running && need == 0) return const SizedBox.shrink();
        return Stack(
          alignment: Alignment.center,
          children: [
            if (f.running)
              SizedBox.square(
                dimension: 44,
                child: CircularProgressIndicator(
                  value: f.jobs.isEmpty ? null : f.finished / f.jobs.length,
                  strokeWidth: 3,
                ),
              ),
            IconButton(
              iconSize: 28,
              padding: const EdgeInsets.all(12),
              tooltip: 'Fix tags',
              onPressed: () => openFixQueue(context),
              icon: Badge(
                isLabelVisible: need > 0,
                label: Text('$need'),
                child: const Icon(Icons.auto_fix_high_rounded),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Every song in the current Fix tags run, grouped like downloads: the
/// ones that need you on top, then what didn't work, what's going, what
/// wasn't found, and what's done.
class FixQueueScreen extends StatelessWidget {
  const FixQueueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final f = AppScope.of(context).fixer;
    return ListenableBuilder(
      listenable: f,
      builder: (context, _) {
        final review = f.jobs.where((j) => j.state == FixState.review).toList();
        final failed = f.jobs.where((j) => j.state == FixState.failed).toList();
        final working = [
          ...f.jobs.where((j) => j.state == FixState.looking || j.state == FixState.writing),
          ...f.jobs.where((j) => j.state == FixState.queued),
        ];
        final missing = f.jobs.where((j) => j.state == FixState.noMatch).toList();
        final done = f.jobs.reversed
            .where((j) => j.state == FixState.fixed || j.state == FixState.unchanged)
            .toList();
        // One flat list, built as it scrolls (a whole library can be in it).
        final rows = <Widget Function()>[
          () => _Summary(fixer: f),
          if (review.isNotEmpty) ...[
            () => _Group(
              'Needs you',
              review.length,
              icon: Icons.priority_high_rounded,
              action: TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: f.leaveAllUnsure,
                child: const Text('Leave all as they are'),
              ),
            ),
            for (final j in review) () => _FixTile(job: j),
          ],
          if (failed.isNotEmpty) ...[
            () => _Group(
              'Didn\'t work',
              failed.length,
              icon: Icons.error_outline_rounded,
              action: TextButton.icon(
                style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: f.retryFailed,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Try all again'),
              ),
            ),
            for (final j in failed) () => _FixTile(job: j),
          ],
          if (working.isNotEmpty) ...[
            () => _Group('Working', working.length, icon: Icons.auto_fix_high_rounded),
            for (final j in working) () => _FixTile(job: j),
          ],
          if (missing.isNotEmpty) ...[
            () => _Group('Not found', missing.length, icon: Icons.search_off_rounded),
            for (final j in missing) () => _FixTile(job: j),
          ],
          if (done.isNotEmpty) ...[
            () => _Group(
              'Done',
              done.length,
              icon: Icons.check_circle_outline_rounded,
              action: TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: f.clearDone,
                child: const Text('Clear'),
              ),
            ),
            for (final j in done) () => _FixTile(job: j),
          ],
        ];
        return Scaffold(
          appBar: AppBar(
            title: const Text('Fix tags'),
            toolbarHeight: 64,
            actions: [
              if (f.running)
                TextButton.icon(
                  style: TextButton.styleFrom(minimumSize: const Size(0, 52)),
                  onPressed: f.cancel,
                  icon: const Icon(Icons.stop_rounded),
                  label: const Text('Stop'),
                ),
              const SizedBox(width: 8),
            ],
          ),
          body: f.jobs.isEmpty
              ? const Center(child: Text('Nothing to fix. Start from Settings, or an album / artist menu.'))
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 40),
                  itemCount: rows.length,
                  itemBuilder: (_, i) => rows[i](),
                ),
        );
      },
    );
  }
}

class _Summary extends StatelessWidget {
  final TagFixer fixer;
  const _Summary({required this.fixer});

  @override
  Widget build(BuildContext context) {
    final f = fixer;
    final cs = Theme.of(context).colorScheme;
    final total = f.jobs.length;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              f.running
                  ? 'Checking ${f.finished} of $total'
                  : 'Checked $total ${total == 1 ? 'song' : 'songs'}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: total == 0 ? 0 : f.finished / total,
                minHeight: 10,
                backgroundColor: cs.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              [
                '${f.count(FixState.fixed)} fixed',
                if (f.needsYou > 0) '${f.needsYou} need you',
                if (f.count(FixState.unchanged) > 0) '${f.count(FixState.unchanged)} left as they were',
                if (f.count(FixState.noMatch) > 0) '${f.count(FixState.noMatch)} not found',
                if (f.count(FixState.failed) > 0) '${f.count(FixState.failed)} didn\'t work',
              ].join(' · '),
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
            if (f.running)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Keeps going if you leave this screen. MusicBrainz takes about one lookup a second.',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  final String title;
  final int count;
  final IconData icon;
  final Widget? action;
  const _Group(this.title, this.count, {required this.icon, this.action});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 12, 4),
      child: Row(
        children: [
          Icon(icon, color: cs.primary, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '$title ($count)',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(color: cs.primary),
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

/// One song: its cover (the match's when there is one), what it is, what
/// it becomes, and how sure.
class _FixTile extends StatelessWidget {
  final FixJob job;
  const _FixTile({required this.job});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final f = AppScope.of(context).fixer;
    final j = job;
    final m = j.best;
    final showMatch =
        m != null && (j.state == FixState.review || j.state == FixState.fixed || j.state == FixState.writing);
    final thumb = j.coverThumb.isNotEmpty ? j.coverThumb : (showMatch ? m.coverThumb : '');
    final cover = thumb.isNotEmpty
        ? ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(
              thumb,
              width: 56,
              height: 56,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Art(albumId: j.song.albumId, size: 56, radius: 8),
            ),
          )
        : Art(albumId: j.song.albumId, size: 56, radius: 8);
    final status = switch (j.state) {
      FixState.queued => 'Waiting',
      FixState.looking => 'Looking it up…',
      FixState.writing => 'Writing tags and cover…',
      FixState.review => 'Not sure: pick the right one',
      FixState.fixed => j.note,
      FixState.unchanged || FixState.noMatch || FixState.failed => j.note,
    };
    final into = showMatch
        ? 'Album: ${m.album}${m.year.isNotEmpty ? ' (${m.year})' : ''}${m.coverUrl.isEmpty ? ' · no cover' : ''}'
        : null;
    return ListTile(
      minTileHeight: 76,
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          cover,
          if (j.state == FixState.looking || j.state == FixState.writing)
            const Positioned.fill(child: Center(child: CircularProgressIndicator(strokeWidth: 3))),
        ],
      ),
      title: Text('${j.song.title} · ${j.song.artist}', maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [?into, ?status].join('\n'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: j.state == FixState.failed ? cs.error : null),
      ),
      onTap: j.state == FixState.review || j.state == FixState.noMatch || j.state == FixState.fixed
          ? () => showFixTags(context, j.song, job: j)
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showMatch && j.confidence > 0) _Sure(value: j.confidence),
          if (j.state == FixState.review) ...[
            const SizedBox(width: 8),
            FilledButton.tonal(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: () => showFixTags(context, j.song, job: j),
              child: const Text('Pick'),
            ),
          ],
          if (j.state == FixState.failed || j.state == FixState.noMatch)
            IconButton(
              tooltip: 'Try again',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: () => f.retry(j),
            ),
        ],
      ),
    );
  }
}

/// "92%": green when sure, amber when not.
class _Sure extends StatelessWidget {
  final int value;
  const _Sure({required this.value});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sure = value >= TagFixer.sureEnough;
    final c = sure ? cs.primary : cs.tertiary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.withValues(alpha: 0.6)),
      ),
      child: Text(
        '$value%',
        style: TextStyle(color: c, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _FixTags extends StatefulWidget {
  final Song song;
  final FixJob? job;
  const _FixTags({required this.song, this.job});

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
    // From Fix tags: the matches it already found.
    final found = widget.job?.matches ?? const [];
    if (found.isNotEmpty) {
      setState(() => _results = found);
      return;
    }
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
    final fixer = AppScope.of(context).fixer;
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    if (!await TagFixer.ensureWrite()) {
      setState(() => _error = 'Roadie needs access to your files to change tags.');
      return;
    }
    setState(() => _applying = m.releaseId);
    final job = widget.job;
    if (job != null) {
      nav.pop();
      await fixer.choose(job, m);
      return;
    }
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
            trailing: widget.job == null || widget.job!.state != FixState.review
                ? null
                : TextButton(
                    style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
                    onPressed: () {
                      AppScope.of(context).fixer.leave(widget.job!);
                      Navigator.of(context).pop();
                    },
                    child: const Text('Leave as it is'),
                  ),
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
                          leading: _CoverThumb(match: m),
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
  final MbMatch match;
  const _CoverThumb({required this.match});

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(6),
    child: Image.network(
      match.coverThumb.isNotEmpty
          ? match.coverThumb
          : 'https://coverartarchive.org/release/${match.releaseId}/front-250',
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
