import 'dart:async';

import 'package:flutter/material.dart';

import '../core/crash_log.dart';
import '../core/downloads.dart';
import '../core/preview.dart';
import '../core/scope.dart';
import '../core/sources.dart';
import '../core/tag_fixer.dart';
import 'folders_screen.dart';

List<MusicSource> _sources(BuildContext context) {
  final s = AppScope.of(context).settings;
  return allSources(jamendoKey: s.jamendoKey, lossless: s.preferLossless);
}

/// Search a source, open an album, download songs straight into the library.
class GetMusicScreen extends StatefulWidget {
  const GetMusicScreen({super.key});

  @override
  State<GetMusicScreen> createState() => _GetMusicScreenState();
}

class _GetMusicScreenState extends State<GetMusicScreen> {
  final _query = TextEditingController();
  List<RemoteItem>? _results;
  String? _error;
  bool _busy = false;
  int _searchId = 0;

  Future<void> _search(MusicSource source) async {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    final id = ++_searchId;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await source.search(q);
      if (id != _searchId || !mounted) return;
      if (source is DirectLink && r.isNotEmpty) {
        await _openItem(context, source, r.first);
        return;
      }
      setState(() => _results = r);
    } on Object catch (e, st) {
      CrashLog.record(e, st, where: 'search ${source.id}');
      if (mounted && id == _searchId) setState(() => _error = 'Search failed: $e');
    } finally {
      if (mounted && id == _searchId) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final s = scope.settings;
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final sources = _sources(context);
        final source = sources.where((x) => x.id == s.source).firstOrNull ?? sources.first;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final x in sources)
                            Padding(
                              padding: const EdgeInsets.all(4),
                              child: ChoiceChip(
                                padding: const EdgeInsets.all(8),
                                label: Text(x.name, style: const TextStyle(fontSize: 16)),
                                selected: x.id == source.id,
                                onSelected: (_) => setState(() {
                                  s.source = x.id;
                                  _results = null;
                                  _error = null;
                                }),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  _DownloadsButton(),
                  IconButton(
                    iconSize: 28,
                    padding: const EdgeInsets.all(12),
                    tooltip: 'Download options',
                    icon: const Icon(Icons.settings_suggest_rounded),
                    onPressed: () => showDownloadOptions(context),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _query,
                      style: const TextStyle(fontSize: 19),
                      textInputAction: TextInputAction.search,
                      keyboardType: source is DirectLink ? TextInputType.url : TextInputType.text,
                      decoration: InputDecoration(
                        hintText: source is DirectLink
                            ? 'https://… link to a music file'
                            : 'Search ${source.name}',
                        prefixIcon: Icon(source is DirectLink ? Icons.link_rounded : Icons.search_rounded),
                        filled: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(30),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onSubmitted: (_) => _search(source),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size(110, 56)),
                    onPressed: _busy || source.needsKey ? null : () => _search(source),
                    child: Text(source is DirectLink ? 'Open' : 'Search'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 2, 28, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(source.blurb, style: TextStyle(color: cs.onSurfaceVariant)),
              ),
            ),
            if (_busy) const LinearProgressIndicator(),
            Expanded(child: _body(context, source)),
          ],
        );
      },
    );
  }

  Widget _body(BuildContext context, MusicSource source) {
    if (source.needsKey) return const _JamendoKey();
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
      );
    }
    final r = _results;
    if (r == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            source is DirectLink
                ? 'Paste a link to an MP3, FLAC or other music file. Roadie names and tags it, then adds it to your library.'
                : 'Search for an artist, album or song. Downloads land in your library with covers and tags.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      );
    }
    if (r.isEmpty) return const Center(child: Text('Nothing found'));
    return LayoutBuilder(
      builder: (context, box) {
        final cols = (box.maxWidth / 210).floor().clamp(2, 8);
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 120),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            childAspectRatio: 0.74,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
          ),
          itemCount: r.length,
          itemBuilder: (context, i) => _ItemCard(item: r[i], onTap: () => _openItem(context, source, r[i])),
        );
      },
    );
  }
}

Future<void> _openItem(BuildContext context, MusicSource source, RemoteItem item) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _ItemScreen(source: source, item: item),
      ),
    );

class _ItemCard extends StatelessWidget {
  final RemoteItem item;
  final VoidCallback onTap;
  const _ItemCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: _Cover(url: item.cover, single: item.single),
            ),
            const SizedBox(height: 8),
            Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            Text(
              [
                item.artist,
                if (item.year.isNotEmpty) item.year,
                if (item.single) 'Song',
              ].where((x) => x.isNotEmpty).join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _Cover extends StatelessWidget {
  final String? url;
  final bool single;
  const _Cover({required this.url, this.single = false});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final none = Container(
      color: cs.surfaceContainerHigh,
      child: Icon(
        single ? Icons.music_note_rounded : Icons.album_rounded,
        size: 48,
        color: cs.onSurfaceVariant,
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: url == null
          ? none
          : Image.network(
              url!,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => none,
              frameBuilder: (_, child, frame, sync) {
                return frame == null && !sync ? none : child;
              },
            ),
    );
  }
}

/// An album / collection: pick songs to download.
class _ItemScreen extends StatefulWidget {
  final MusicSource source;
  final RemoteItem item;
  const _ItemScreen({required this.source, required this.item});

  @override
  State<_ItemScreen> createState() => _ItemScreenState();
}

class _ItemScreenState extends State<_ItemScreen> {
  List<RemoteTrack>? _tracks;
  final _picked = <int>{};
  String? _error;

  late final Preview _preview;

  @override
  void initState() {
    super.initState();
    _preview = AppScope.of(context).preview;
    _load();
  }

  @override
  void dispose() {
    _preview.stop();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final t = await widget.source.tracks(widget.item);
      if (!mounted) return;
      setState(() {
        _tracks = t;
        _picked.addAll(List.generate(t.length, (i) => i));
      });
    } on Object catch (e, st) {
      CrashLog.record(e, st, where: 'tracks ${widget.source.id} ${widget.item.id}');
      if (mounted) setState(() => _error = 'Couldn\'t load the songs: $e');
    }
  }

  Future<void> _download() async {
    final t = _tracks;
    if (t == null || _picked.isEmpty) return;
    final scope = AppScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    if (!await TagFixer.ensureWrite()) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Roadie needs access to your files to save downloads')),
      );
      return;
    }
    final list = [
      for (var i = 0; i < t.length; i++)
        if (_picked.contains(i)) t[i],
    ];
    scope.downloads.add(list);
    final folder = await scope.downloads.folder();
    messenger.showSnackBar(
      SnackBar(
        content: Text('Downloading ${list.length} ${list.length == 1 ? 'song' : 'songs'} to $folder'),
        action: SnackBarAction(label: 'Show', onPressed: () => openDownloads(context)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final tt = Theme.of(context).textTheme;
    final t = _tracks;
    final wide = MediaQuery.sizeOf(context).width > 700;
    final header = Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox.square(
            dimension: wide ? 180 : 120,
            child: _Cover(url: item.cover, single: item.single),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.title, style: tt.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text([item.artist, item.year].where((x) => x.isNotEmpty).join(' · '), style: tt.titleMedium),
                Text(widget.source.name, style: tt.bodyMedium),
                const SizedBox(height: 16),
                FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size(200, 56)),
                  onPressed: t == null || _picked.isEmpty ? null : _download,
                  icon: const Icon(Icons.download_rounded),
                  label: Text(
                    t == null
                        ? 'Download'
                        : _picked.length == t.length
                        ? 'Download all ${t.length}'
                        : 'Download ${_picked.length}',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    return Scaffold(
      appBar: AppBar(actions: [_DownloadsButton()]),
      body: _error != null
          ? Center(child: Text(_error!))
          : t == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 40),
              children: [
                header,
                if (t.isEmpty)
                  const Padding(padding: EdgeInsets.all(24), child: Text('No downloadable songs here')),
                if (t.length > 1)
                  CheckboxListTile(
                    title: const Text('All'),
                    value: _picked.length == t.length ? true : (_picked.isEmpty ? false : null),
                    tristate: true,
                    onChanged: (_) => setState(() {
                      if (_picked.length == t.length) {
                        _picked.clear();
                      } else {
                        _picked.addAll(List.generate(t.length, (i) => i));
                      }
                    }),
                  ),
                for (var i = 0; i < t.length; i++)
                  _TrackRow(
                    track: t[i],
                    showArtist: t[i].artist.isNotEmpty && t[i].artist != item.artist,
                    picked: _picked.contains(i),
                    onPicked: (v) => setState(() => v ? _picked.add(i) : _picked.remove(i)),
                  ),
              ],
            ),
    );
  }
}

String _len(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

/// A song in an album: tap play to stream a preview, tick to download.
class _TrackRow extends StatelessWidget {
  final RemoteTrack track;
  final bool showArtist;
  final bool picked;
  final ValueChanged<bool> onPicked;
  const _TrackRow({
    required this.track,
    required this.showArtist,
    required this.picked,
    required this.onPicked,
  });

  @override
  Widget build(BuildContext context) {
    final pv = AppScope.of(context).preview;
    final cs = Theme.of(context).colorScheme;
    final url = track.previewUrl;
    return ListenableBuilder(
      listenable: pv,
      builder: (context, _) {
        final on = pv.current == url;
        final total = on ? (pv.duration ?? track.length) : null;
        return Column(
          children: [
            ListTile(
              minTileHeight: 68,
              leading: IconButton.filledTonal(
                iconSize: 30,
                tooltip: on ? 'Stop preview' : 'Preview',
                onPressed: () => pv.toggle(url),
                icon: on && pv.loading
                    ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 3))
                    : Icon(on ? Icons.stop_rounded : Icons.play_arrow_rounded),
              ),
              title: Text('${track.track > 0 ? '${track.track}. ' : ''}${track.title}'),
              subtitle: Text(
                [
                  if (showArtist) track.artist,
                  if (on && total != null)
                    '${_len(pv.position)} / ${_len(total)}'
                  else if (track.length != null)
                    _len(track.length!),
                  track.quality,
                ].where((x) => x.isNotEmpty).join(' · '),
              ),
              trailing: Checkbox(value: picked, onChanged: (v) => onPicked(v ?? false)),
              onTap: () => onPicked(!picked),
            ),
            if (on && total != null && total > Duration.zero)
              Padding(
                padding: const EdgeInsets.fromLTRB(76, 0, 24, 8),
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(trackHeight: 4),
                  child: Slider(
                    value: pv.position.inMilliseconds.clamp(0, total.inMilliseconds).toDouble(),
                    max: total.inMilliseconds.toDouble(),
                    onChanged: (v) => pv.seek(Duration(milliseconds: v.round())),
                  ),
                ),
              ),
            if (pv.failed == url)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('This one can\'t be previewed', style: TextStyle(color: cs.error)),
              ),
          ],
        );
      },
    );
  }
}

class _DownloadsButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final d = AppScope.of(context).downloads;
    return ListenableBuilder(
      listenable: d,
      builder: (context, _) => IconButton(
        iconSize: 28,
        padding: const EdgeInsets.all(12),
        tooltip: 'Downloads',
        onPressed: () => openDownloads(context),
        icon: Badge(
          isLabelVisible: d.activeCount > 0,
          label: Text('${d.activeCount}'),
          child: const Icon(Icons.downloading_rounded),
        ),
      ),
    );
  }
}

void openDownloads(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const _DownloadsScreen()));

class _DownloadsScreen extends StatelessWidget {
  const _DownloadsScreen();

  @override
  Widget build(BuildContext context) {
    final d = AppScope.of(context).downloads;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Downloads'),
        actions: [TextButton(onPressed: d.clearFinished, child: const Text('Clear finished'))],
      ),
      body: ListenableBuilder(
        listenable: d,
        builder: (context, _) {
          if (d.jobs.isEmpty) return const Center(child: Text('Nothing downloading'));
          return ListView(
            padding: const EdgeInsets.only(bottom: 40),
            children: [
              FutureBuilder(
                future: d.folder(),
                builder: (context, f) => ListTile(
                  leading: const Icon(Icons.folder_rounded),
                  title: Text('Saving to ${f.data ?? '…'}'),
                ),
              ),
              for (final j in d.jobs.reversed)
                ListTile(
                  minTileHeight: 72,
                  leading: switch (j.state) {
                    JobState.queued => const Icon(Icons.schedule_rounded),
                    JobState.downloading || JobState.tagging => SizedBox.square(
                      dimension: 32,
                      child: CircularProgressIndicator(
                        value: j.state == JobState.tagging || j.progress < 0 ? null : j.progress,
                      ),
                    ),
                    JobState.done => Icon(Icons.check_circle_rounded, color: cs.primary),
                    JobState.skipped => const Icon(Icons.check_circle_outline_rounded),
                    JobState.failed => Icon(Icons.error_rounded, color: cs.error),
                  },
                  title: Text(j.track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    switch (j.state) {
                      JobState.queued => 'Waiting · ${j.track.artist}',
                      JobState.downloading =>
                        j.note ??
                            (j.progress < 0 ? 'Downloading…' : 'Downloading ${(j.progress * 100).round()}%'),
                      JobState.tagging => 'Adding tags and cover…',
                      JobState.done => 'In your library · ${j.track.artist}',
                      JobState.skipped => j.error ?? 'Skipped',
                      JobState.failed => j.error ?? 'Failed',
                    },
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: j.active
                      ? IconButton(
                          tooltip: 'Cancel',
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () => d.cancel(j),
                        )
                      : j.state == JobState.failed
                      ? IconButton(
                          tooltip: 'Retry',
                          icon: const Icon(Icons.refresh_rounded),
                          onPressed: () => d.retry(j),
                        )
                      : null,
                ),
            ],
          );
        },
      ),
    );
  }
}

class _JamendoKey extends StatefulWidget {
  const _JamendoKey();

  @override
  State<_JamendoKey> createState() => _JamendoKeyState();
}

class _JamendoKeyState extends State<_JamendoKey> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Jamendo needs a free key: sign up at developer.jamendo.com, create an app, and paste its Client ID here.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _c,
              decoration: const InputDecoration(labelText: 'Client ID', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(160, 52)),
              onPressed: () {
                final k = _c.text.trim();
                if (k.isNotEmpty) AppScope.of(context).settings.jamendoKey = k;
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Where downloads go and how they're tagged (also in Settings).
Future<void> showDownloadOptions(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  constraints: const BoxConstraints(maxWidth: 680),
  builder: (context) => const SafeArea(child: DownloadOptions()),
);

class DownloadOptions extends StatelessWidget {
  const DownloadOptions({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final s = scope.settings;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FutureBuilder(
            future: scope.downloads.folder(),
            builder: (context, f) => ListTile(
              leading: const Icon(Icons.folder_special_rounded),
              title: const Text('Save downloads to'),
              subtitle: Text(f.data ?? '…'),
              trailing: s.downloadFolder.isEmpty
                  ? null
                  : TextButton(onPressed: () => s.downloadFolder = '', child: const Text('Default')),
              onTap: () async {
                final picked = await pickFolder(context, title: 'Save downloads to', start: f.data);
                if (picked != null) s.downloadFolder = picked;
              },
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.travel_explore_rounded),
            title: const Text('Look up missing tags and covers'),
            subtitle: const Text('From MusicBrainz, an open music database'),
            value: s.lookUpDownloads,
            onChanged: (v) => s.lookUpDownloads = v,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.high_quality_rounded),
            title: const Text('Prefer lossless (FLAC)'),
            subtitle: const Text('Bigger files; MP3 when a source has no FLAC'),
            value: s.preferLossless,
            onChanged: (v) => s.preferLossless = v,
          ),
          if (s.jamendoKey.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.key_rounded),
              title: const Text('Jamendo key'),
              subtitle: Text(s.jamendoKey),
              trailing: TextButton(onPressed: () => s.jamendoKey = '', child: const Text('Remove')),
            ),
        ],
      ),
    );
  }
}
