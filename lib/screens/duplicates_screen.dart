import 'dart:io';

import 'package:flutter/material.dart';

import '../core/crash_log.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../core/quality.dart';
import '../core/scope.dart';
import '../core/smart.dart';
import '../core/tag_fixer.dart';
import '../widgets/art.dart';

void openDuplicates(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DuplicatesScreen()));

/// The same song more than once: shows each copy's quality, keeps the best.
class DuplicatesScreen extends StatefulWidget {
  const DuplicatesScreen({super.key});

  @override
  State<DuplicatesScreen> createState() => _DuplicatesScreenState();
}

class _DuplicatesScreenState extends State<DuplicatesScreen> {
  List<List<Song>>? _groups;
  final _q = <int, Quality?>{};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  /// Higher is better: lossless, then bit depth, sample rate, bit rate, size.
  int _score(Song s) {
    final q = _q[s.id];
    if (q == null) return s.size ~/ 1000;
    return (q.lossless ? 1 << 40 : 0) +
        q.bits * (1 << 32) +
        (q.khz * 1000).round() * (1 << 12) +
        q.kbps * 4 +
        s.size ~/ 1000000;
  }

  Future<void> _scan() async {
    final lib = AppScope.of(context).library;
    final rough = findDuplicates(lib.songs, (a, b) => b.size.compareTo(a.size));
    for (final g in rough) {
      for (final s in g) {
        _q[s.id] = await Quality.of(s);
      }
    }
    if (!mounted) return;
    setState(() => _groups = findDuplicates(lib.songs, (a, b) => _score(b).compareTo(_score(a))));
  }

  Future<void> _delete(List<Song> songs) async {
    if (songs.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${plural(songs.length, 'file')}?'),
        content: Text(
          'These files are removed from the device for good:\n\n${songs.map((s) => s.path).take(8).join('\n')}'
          '${songs.length > 8 ? '\n…and ${songs.length - 8} more' : ''}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final scope = AppScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    if (!await TagFixer.ensureWrite()) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Roadie needs access to your files to delete them')),
      );
      return;
    }
    setState(() => _busy = true);
    var n = 0;
    for (final s in songs) {
      try {
        File(s.path).deleteSync();
        n++;
      } on Object catch (e, st) {
        CrashLog.record(e, st, where: 'delete duplicate ${s.path}');
      }
    }
    await rescan(scope.library, [for (final s in songs) s.path]);
    if (!mounted) return;
    setState(() => _busy = false);
    messenger.showSnackBar(SnackBar(content: Text('Deleted ${plural(n, 'file')}')));
    await _scan();
  }

  @override
  Widget build(BuildContext context) {
    final g = _groups;
    final cs = Theme.of(context).colorScheme;
    final extra = g == null ? 0 : g.fold(0, (n, x) => n + x.length - 1);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Duplicates'),
        actions: [
          if (g != null && g.isNotEmpty)
            TextButton(
              onPressed: _busy ? null : () => _delete([for (final x in g) ...x.skip(1)]),
              child: Text('Keep the best of each ($extra to delete)'),
            ),
        ],
        bottom: _busy
            ? const PreferredSize(preferredSize: Size.fromHeight(3), child: LinearProgressIndicator())
            : null,
      ),
      body: g == null
          ? const Center(child: CircularProgressIndicator())
          : g.isEmpty
          ? const Center(child: Text('No duplicates found'))
          : ListView(
              padding: const EdgeInsets.only(bottom: 40),
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    '${plural(g.length, 'song')} with more than one copy. The best copy (lossless, then highest '
                    'quality) is first and kept; nothing is deleted until you confirm.',
                  ),
                ),
                for (final group in g)
                  Card.filled(
                    color: cs.surfaceContainer,
                    margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ListTile(
                            leading: Art(albumId: group.first.albumId, size: 48),
                            title: Text('${group.first.title} · ${group.first.artist}'),
                            trailing: TextButton(
                              onPressed: _busy ? null : () => _delete(group.skip(1).toList()),
                              child: const Text('Keep best'),
                            ),
                          ),
                          for (var i = 0; i < group.length; i++)
                            ListTile(
                              dense: true,
                              leading: Icon(
                                i == 0 ? Icons.star_rounded : Icons.content_copy_rounded,
                                color: i == 0 ? cs.primary : cs.onSurfaceVariant,
                              ),
                              title: Text(
                                [
                                  _q[group[i].id]?.label ?? group[i].fileName.split('.').last.toUpperCase(),
                                  sizeText(group[i].size),
                                  clock(group[i].duration),
                                  group[i].album,
                                ].join(' · '),
                              ),
                              subtitle: Text(group[i].path, maxLines: 2, overflow: TextOverflow.ellipsis),
                              trailing: i == 0
                                  ? Text(
                                      'Keep',
                                      style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600),
                                    )
                                  : IconButton(
                                      tooltip: 'Delete this copy',
                                      icon: const Icon(Icons.delete_outline_rounded),
                                      onPressed: _busy ? null : () => _delete([group[i]]),
                                    ),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

String sizeText(int b) =>
    b >= 1 << 20 ? '${(b / (1 << 20)).toStringAsFixed(1)} MB' : '${(b / 1024).round()} KB';
