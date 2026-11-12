import 'dart:io';

import 'package:flutter/material.dart';

import '../core/crash_log.dart';
import '../core/format.dart';
import '../core/metadata.dart';
import '../core/models.dart';
import '../core/native.dart';
import '../core/scope.dart';
import '../core/tag_fixer.dart';

/// Deletes [songs]' files from the device after asking; [what] names them
/// ("Night Drive", "this song").
Future<void> deleteSongs(BuildContext context, List<Song> songs, {required String what}) async {
  if (songs.isEmpty) return;
  final scope = AppScope.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.delete_forever_rounded),
      title: Text('Delete $what?'),
      content: SingleChildScrollView(
        child: Text(
          '${plural(songs.length, 'file')} will be removed from this device for good:\n\n'
          '${songs.take(10).map((s) => s.path).join('\n')}'
          '${songs.length > 10 ? '\n…and ${songs.length - 10} more' : ''}',
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (ok != true) return;
  if (!await TagFixer.ensureWrite()) {
    messenger.showSnackBar(const SnackBar(content: Text('Roadie needs access to your files to delete them')));
    return;
  }
  // Don't pull the file out from under the player.
  final p = scope.player;
  if (p.current != null && songs.any((s) => s.id == p.current!.id)) {
    if (p.hasNext) {
      await p.next();
    } else {
      await p.pause();
    }
  }
  var n = 0;
  for (final s in songs) {
    try {
      final f = File(s.path);
      if (f.existsSync()) f.deleteSync();
      n++;
    } on Object catch (e, st) {
      CrashLog.record(e, st, where: 'delete ${s.path}');
    }
  }
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        n == songs.length
            ? 'Deleted ${plural(n, 'file')}'
            : 'Deleted $n of ${songs.length} (see Problem reports)',
      ),
    ),
  );
  await rescan(scope.library, [for (final s in songs) s.path]);
}

/// Edit tags for one song, or the same fields across many (album, playlist).
Future<void> editTags(BuildContext context, List<Song> songs, {required String what}) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _EditTags(songs: songs, what: what),
        fullscreenDialog: true,
      ),
    );

class _EditTags extends StatefulWidget {
  final List<Song> songs;
  final String what;
  const _EditTags({required this.songs, required this.what});

  @override
  State<_EditTags> createState() => _EditTagsState();
}

class _EditTagsState extends State<_EditTags> {
  /// key → label; single songs get every field, groups the shared ones.
  static const _all = {
    'title': 'Title',
    'artist': 'Artist',
    'album': 'Album',
    'albumArtist': 'Album artist',
    'genre': 'Genre',
    'year': 'Year',
    'track': 'Track',
    'disc': 'Disc',
  };
  static const _shared = ['artist', 'album', 'albumArtist', 'genre', 'year', 'disc'];

  final _c = <String, TextEditingController>{};
  final _start = <String, String>{}; // value shown at first ('' when mixed)
  final _mixed = <String>{};
  bool _loading = true;
  bool _saving = false;

  bool get _one => widget.songs.length == 1;
  List<String> get _keys => _one ? _all.keys.toList() : _shared;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final values = <String, Set<String>>{for (final k in _keys) k: {}};
    for (final s in widget.songs) {
      var t = TagValues.ofSong(s);
      try {
        t = TagValues.fromMap(await Native.readTags(s.path)).fill(t);
      } on Object {
        // Unreadable: the library's view of it.
      }
      final m = t.toMap();
      for (final k in _keys) {
        values[k]!.add(m[k] ?? '');
      }
    }
    for (final k in _keys) {
      final v = values[k]!;
      if (v.length > 1) _mixed.add(k);
      _start[k] = v.length == 1 ? v.first : '';
      _c[k] = TextEditingController(text: _start[k]);
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final changed = {
      for (final k in _keys)
        if (_c[k]!.text.trim() != _start[k]) k: _c[k]!.text.trim(),
    };
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final lib = AppScope.of(context).library;
    if (changed.isEmpty) return nav.pop();
    if (!await TagFixer.ensureWrite()) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Roadie needs access to your files to change tags')),
      );
      return;
    }
    setState(() => _saving = true);
    var failed = 0;
    for (final s in widget.songs) {
      try {
        await Native.writeTags(s.path, changed);
      } on Object catch (e, st) {
        failed++;
        CrashLog.record(e, st, where: 'edit tags ${s.path}');
      }
    }
    nav.pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          failed == 0
              ? 'Saved ${plural(widget.songs.length, 'song')}'
              : '$failed of ${widget.songs.length} couldn\'t be changed (see Problem reports)',
        ),
      ),
    );
    await rescan(lib, [for (final s in widget.songs) s.path]);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final wide = MediaQuery.sizeOf(context).width > 800;
    return Scaffold(
      appBar: AppBar(
        title: Text(_one ? 'Edit tags' : 'Edit tags · ${plural(widget.songs.length, 'song')}'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              onPressed: _loading || _saving ? null : _save,
              child: _saving
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Save'),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Text(widget.what, style: Theme.of(context).textTheme.titleMedium),
                    if (!_one)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          'Changes apply to every song. Fields marked "different in each" are left alone unless you type in them.',
                          style: TextStyle(color: cs.onSurfaceVariant),
                        ),
                      ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 16,
                      runSpacing: 16,
                      children: [
                        for (final k in _keys)
                          SizedBox(
                            width: wide && (k == 'year' || k == 'track' || k == 'disc')
                                ? 200
                                : (wide ? 420 : double.infinity),
                            child: TextField(
                              controller: _c[k],
                              keyboardType: k == 'year' || k == 'track' || k == 'disc'
                                  ? TextInputType.number
                                  : null,
                              textCapitalization: TextCapitalization.words,
                              decoration: InputDecoration(
                                labelText: _all[k],
                                hintText: _mixed.contains(k) ? 'Different in each' : null,
                                border: const OutlineInputBorder(),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
