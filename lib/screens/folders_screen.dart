import 'package:flutter/material.dart';

import '../core/native.dart';
import '../core/scope.dart';

/// Picks a folder on the device; null when cancelled.
Future<String?> pickFolder(BuildContext context, {required String title, String? start}) =>
    Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => _FolderPicker(title: title, start: start),
      ),
    );

/// Which folders the library comes from, and which it skips.
class MusicFoldersScreen extends StatelessWidget {
  const MusicFoldersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final s = scope.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Music folders')),
      body: ListenableBuilder(
        listenable: Listenable.merge([s, scope.library]),
        builder: (context, _) {
          Widget list(String title, String empty, List<String> folders, ValueChanged<List<String>> save) =>
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListTile(
                    title: Text(
                      title,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    trailing: FilledButton.tonalIcon(
                      icon: const Icon(Icons.create_new_folder_rounded),
                      label: const Text('Add'),
                      onPressed: () async {
                        final f = await pickFolder(context, title: title);
                        if (f != null && !folders.contains(f)) save([...folders, f]);
                      },
                    ),
                  ),
                  if (folders.isEmpty)
                    Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text(empty)),
                  for (final f in folders)
                    ListTile(
                      minTileHeight: 60,
                      leading: const Icon(Icons.folder_rounded),
                      title: Text(_short(f)),
                      subtitle: Text('${_count(scope, f)} songs'),
                      trailing: IconButton(
                        tooltip: 'Remove',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => save([...folders]..remove(f)),
                      ),
                    ),
                ],
              );
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: ListView(
                padding: const EdgeInsets.only(bottom: 40),
                children: [
                  list(
                    'Only these folders',
                    'None: songs come from everywhere on the device.',
                    s.includeFolders,
                    (v) => s.includeFolders = v,
                  ),
                  const Divider(height: 32),
                  list(
                    'Never these folders',
                    'None. Add folders like WhatsApp or Recordings to keep them out.',
                    s.excludeFolders,
                    (v) => s.excludeFolders = v,
                  ),
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      '${scope.library.songs.length} of ${scope.library.unfiltered.length} songs on the device are in the library.',
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  static int _count(AppScope scope, String folder) =>
      scope.library.unfiltered.where((s) => s.path.startsWith('$folder/')).length;
}

String _short(String path) => path.replaceFirst(RegExp(r'^/storage/emulated/0'), 'Internal storage');

class _FolderPicker extends StatefulWidget {
  final String title;
  final String? start;
  const _FolderPicker({required this.title, this.start});

  @override
  State<_FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends State<_FolderPicker> {
  List<String> _roots = const [];
  String? _path;
  List<String> _dirs = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _roots = await Native.roots();
    await _open(widget.start ?? _roots.first);
  }

  Future<void> _open(String path) async {
    setState(() {
      _path = path;
      _loading = true;
    });
    var dirs = await Native.listDirs(path);
    if (dirs.isEmpty && mounted) {
      // No storage access (or tests): offer folders that hold music.
      final lib = AppScope.of(context).library.unfiltered;
      dirs = {
        for (final s in lib)
          if (s.path.startsWith('$path/')) s.path.substring(path.length + 1).split('/').first,
      }.where((d) => !d.contains('.')).toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    }
    if (!mounted) return;
    setState(() {
      _dirs = dirs;
      _loading = false;
    });
  }

  bool get _atRoot => _roots.contains(_path);

  @override
  Widget build(BuildContext context) {
    final path = _path;
    return PopScope(
      canPop: path == null || _atRoot,
      onPopInvokedWithResult: (popped, _) {
        if (!popped && path != null) _open(path.substring(0, path.lastIndexOf('/')));
      },
      child: Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: path == null
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  if (_roots.length > 1)
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        children: [
                          for (final r in _roots)
                            Padding(
                              padding: const EdgeInsets.all(4),
                              child: ChoiceChip(
                                label: Text(
                                  r == _roots.first ? 'Internal storage' : 'SD / USB ${r.split('/').last}',
                                ),
                                selected: path.startsWith(r),
                                onSelected: (_) => _open(r),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ListTile(
                    leading: _atRoot
                        ? const Icon(Icons.sd_storage_rounded)
                        : IconButton(
                            tooltip: 'Up',
                            icon: const Icon(Icons.arrow_upward_rounded),
                            onPressed: () => _open(path.substring(0, path.lastIndexOf('/'))),
                          ),
                    title: Text(_short(path), maxLines: 2, overflow: TextOverflow.ellipsis),
                    trailing: FilledButton.icon(
                      style: FilledButton.styleFrom(minimumSize: const Size(140, 52)),
                      onPressed: () => Navigator.of(context).pop(path),
                      icon: const Icon(Icons.check_rounded),
                      label: const Text('Use this folder'),
                    ),
                  ),
                  const Divider(),
                  Expanded(
                    child: _loading
                        ? const Center(child: CircularProgressIndicator())
                        : _dirs.isEmpty
                        ? const Center(child: Text('No folders in here'))
                        : ListView(
                            children: [
                              for (final d in _dirs)
                                ListTile(
                                  minTileHeight: 60,
                                  leading: const Icon(Icons.folder_rounded),
                                  title: Text(d),
                                  trailing: const Icon(Icons.chevron_right_rounded),
                                  onTap: () => _open('$path/$d'),
                                ),
                            ],
                          ),
                  ),
                ],
              ),
      ),
    );
  }
}
