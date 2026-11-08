import 'dart:async';

import 'package:flutter/material.dart';

import '../core/crash_log.dart';
import '../core/downloads.dart';
import '../core/http.dart';
import '../core/preview.dart';
import '../core/scope.dart';
import '../core/sources.dart';
import '../core/tag_fixer.dart';
import 'browser_screen.dart';
import 'folders_screen.dart';

List<MusicSource> _sources(BuildContext context) {
  final s = AppScope.of(context).settings;
  return allSources(jamendoKey: s.jamendoKey, lossless: s.preferLossless);
}

/// One source's part of a search.
class _Result {
  List<RemoteItem>? items;
  String? error;
  bool get loading => items == null && error == null;
}

/// Search one or more sources at once, open an album, download songs
/// straight into the library. Added websites open in the browser.
class GetMusicScreen extends StatefulWidget {
  const GetMusicScreen({super.key});

  @override
  State<GetMusicScreen> createState() => _GetMusicScreenState();
}

class _GetMusicScreenState extends State<GetMusicScreen> {
  final _query = TextEditingController();
  Map<String, _Result>? _results;
  String _searched = '';
  bool _checking = false;
  int _searchId = 0;

  List<String> _ticked(List<MusicSource> builtIn, List<CustomSite> sites) {
    final ids = {...builtIn.map((x) => x.id), ...sites.map((x) => x.id)};
    final t = AppScope.of(context).settings.sources.where(ids.contains).toList();
    return t.isEmpty ? [builtIn.first.id] : t;
  }

  void _toggle(String id, List<String> ticked) {
    final s = AppScope.of(context).settings;
    if (id == 'link') {
      // A pasted link isn't a search: it's on its own.
      s.sources = ['link'];
    } else if (ticked.contains(id)) {
      final next = [...ticked]..remove(id);
      s.sources = next.isEmpty ? [id] : next;
    } else {
      s.sources = [...ticked.where((x) => x != 'link'), id];
    }
    setState(() => _results = null);
  }

  Future<void> _search(List<MusicSource> sources, List<CustomSite> sites, List<String> ticked) async {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    final id = ++_searchId;
    if (ticked.contains('link')) {
      final link = sources.firstWhere((x) => x.id == 'link');
      final messenger = ScaffoldMessenger.of(context);
      setState(() => _checking = true);
      try {
        final r = await link.search(q);
        if (!mounted) return;
        if (r.isEmpty) {
          messenger.showSnackBar(const SnackBar(content: Text('That isn\'t a web link')));
        } else {
          await openRemoteItem(context, link, r.first);
        }
      } on LinkIsPage catch (e) {
        // A web page: look for the music on it.
        if (!mounted) return;
        messenger.showSnackBar(
          const SnackBar(
            content: Text('That\'s a web page, not a music file. Looking for music files on it…'),
          ),
        );
        openBrowser(context, url: e.url, siteName: e.url.host);
      } on Object catch (e, st) {
        if (e is! UnsupportedLink) CrashLog.record(e, st, where: 'link $q');
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Can\'t download that'),
            content: Text(e is UnsupportedLink ? e.message : friendlyError(e)),
            actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK'))],
          ),
        );
      } finally {
        if (mounted) setState(() => _checking = false);
      }
      return;
    }
    final results = <String, _Result>{for (final t in ticked) t: _Result()};
    setState(() {
      _results = results;
      _searched = q;
    });
    for (final t in ticked) {
      final src = sources.where((x) => x.id == t).firstOrNull;
      final r = results[t]!;
      if (src == null) {
        r.items = const []; // an added site: opened from its card
        continue;
      }
      if (src.needsKey) {
        r.error = 'key';
        continue;
      }
      unawaited(
        src
            .search(q)
            .then((items) => r.items = items)
            .catchError((Object e, StackTrace st) {
              CrashLog.record(e, st, where: 'search ${src.id}');
              r.error = friendlyError(e);
              return const <RemoteItem>[];
            })
            .whenComplete(() {
              if (mounted && id == _searchId) setState(() {});
            }),
      );
    }
    setState(() {});
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
        final sites = CustomSite.decode(s.customSitesJson);
        final ticked = _ticked(sources, sites);
        final link = ticked.contains('link');
        final names = [
          for (final t in ticked)
            sources.where((x) => x.id == t).firstOrNull?.name ??
                sites.where((x) => x.id == t).firstOrNull?.name ??
                t,
        ];
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
                              child: FilterChip(
                                padding: const EdgeInsets.all(8),
                                label: Text(x.name, style: const TextStyle(fontSize: 16)),
                                selected: ticked.contains(x.id),
                                onSelected: (_) => _toggle(x.id, ticked),
                              ),
                            ),
                          for (final x in sites)
                            Padding(
                              padding: const EdgeInsets.all(4),
                              child: GestureDetector(
                                onLongPress: () => _editSite(context, x),
                                child: FilterChip(
                                  padding: const EdgeInsets.all(8),
                                  avatar: const Icon(Icons.public_rounded, size: 18),
                                  label: Text(x.name, style: const TextStyle(fontSize: 16)),
                                  selected: ticked.contains(x.id),
                                  onSelected: (_) => _toggle(x.id, ticked),
                                ),
                              ),
                            ),
                          Padding(
                            padding: const EdgeInsets.all(4),
                            child: ActionChip(
                              padding: const EdgeInsets.all(8),
                              avatar: const Icon(Icons.add_rounded),
                              label: const Text('Add a site', style: TextStyle(fontSize: 16)),
                              onPressed: () => _editSite(context, null),
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
                      keyboardType: link ? TextInputType.url : TextInputType.text,
                      decoration: InputDecoration(
                        hintText: link ? 'https://… link to a music file' : 'Search ${names.join(', ')}',
                        prefixIcon: Icon(link ? Icons.link_rounded : Icons.search_rounded),
                        filled: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(30),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onSubmitted: (_) => _search(sources, sites, ticked),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size(110, 56)),
                    onPressed: () => _search(sources, sites, ticked),
                    child: Text(link ? 'Open' : 'Search'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 2, 28, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  ticked.length > 1
                      ? 'Searching ${ticked.length} sources at once. Long-press an added site to edit it.'
                      : (sources.where((x) => x.id == ticked.first).firstOrNull?.blurb ??
                            'Your site: opens in the browser, music files on each page can be downloaded'),
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
              ),
            ),
            if (_checking || (_results?.values.any((r) => r.loading) ?? false))
              const LinearProgressIndicator(),
            Expanded(child: _body(context, sources, sites, ticked)),
          ],
        );
      },
    );
  }

  Widget _body(BuildContext context, List<MusicSource> sources, List<CustomSite> sites, List<String> ticked) {
    final r = _results;
    final tt = Theme.of(context).textTheme;
    if (r == null) {
      final open = sites.where((x) => ticked.contains(x.id)).toList();
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (ticked.contains('jamendo') && sources.firstWhere((x) => x.id == 'jamendo').needsKey)
            const _JamendoKey(),
          Text(
            ticked.contains('link')
                ? 'Paste a link to an MP3, FLAC or other music file. Roadie names and tags it, then adds it to your library.'
                : 'Search for an artist, album or song. Tick more than one source to search them all at once. '
                      'Downloads land in your library with covers and tags.',
            textAlign: TextAlign.center,
            style: tt.titleMedium,
          ),
          for (final x in open)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Center(
                child: FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(minimumSize: const Size(240, 56)),
                  onPressed: () => openBrowser(context, url: x.homeUri, siteName: x.name, site: x),
                  icon: const Icon(Icons.public_rounded),
                  label: Text('Browse ${x.name}'),
                ),
              ),
            ),
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        final cols = (box.maxWidth / 210).floor().clamp(2, 8);
        final slivers = <Widget>[];
        for (final e in r.entries) {
          final src = sources.where((x) => x.id == e.key).firstOrNull;
          final site = sites.where((x) => x.id == e.key).firstOrNull;
          final res = e.value;
          final name = src?.name ?? site?.name ?? e.key;
          slivers.add(
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
                child: Row(
                  children: [
                    Text(name, style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(width: 12),
                    if (res.loading)
                      const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2.5))
                    else if (site == null && res.error == null)
                      Text('${res.items!.length} found', style: tt.bodyMedium),
                  ],
                ),
              ),
            ),
          );
          if (site != null) {
            slivers.add(
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(minimumSize: const Size(260, 56)),
                      onPressed: () => openBrowser(
                        context,
                        url: site.search.contains('{q}') ? site.searchUri(_searched) : site.homeUri,
                        siteName: site.name,
                        site: site,
                      ),
                      icon: const Icon(Icons.open_in_browser_rounded),
                      label: Text(
                        site.search.contains('{q}')
                            ? 'See "$_searched" on ${site.name}'
                            : 'Browse ${site.name}',
                      ),
                    ),
                  ),
                ),
              ),
            );
          } else if (res.error == 'key') {
            slivers.add(const SliverToBoxAdapter(child: _JamendoKey()));
          } else if (res.error != null) {
            slivers.add(
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Text('Search failed: ${res.error}'),
                ),
              ),
            );
          } else if (res.items != null && res.items!.isEmpty) {
            slivers.add(
              const SliverToBoxAdapter(
                child: Padding(padding: EdgeInsets.symmetric(horizontal: 18), child: Text('Nothing found')),
              ),
            );
          } else if (res.items != null) {
            slivers.add(
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                sliver: SliverGrid.builder(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: cols,
                    childAspectRatio: 0.74,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                  ),
                  itemCount: res.items!.length,
                  itemBuilder: (context, i) => _ItemCard(
                    item: res.items![i],
                    onTap: () => openRemoteItem(context, src!, res.items![i]),
                  ),
                ),
              ),
            );
          }
        }
        slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 120)));
        return CustomScrollView(slivers: slivers);
      },
    );
  }

  /// Add (site == null) or edit a website source.
  Future<void> _editSite(BuildContext context, CustomSite? site) async {
    final s = AppScope.of(context).settings;
    final name = TextEditingController(text: site?.name ?? '');
    final home = TextEditingController(text: site?.home ?? 'https://');
    final search = TextEditingController(text: site?.search ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(site == null ? 'Add a site' : 'Edit ${site.name}'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: home,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(labelText: 'Home page', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: search,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Search address (optional)',
                    hintText: 'https://example.org/search?q={q}',
                    helperText:
                        'Where {q} is, your search words go. Or set it later from the browser\'s menu.',
                    helperMaxLines: 3,
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          if (site != null)
            TextButton(onPressed: () => Navigator.of(context).pop('delete'), child: const Text('Remove')),
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop('save'), child: const Text('Save')),
        ],
      ),
    );
    final sites = CustomSite.decode(s.customSitesJson);
    if (result == 'delete' && site != null) {
      s.customSitesJson = CustomSite.encode(sites.where((x) => x.id != site.id).toList());
      s.sources = s.sources.where((x) => x != site.id).toList();
    } else if (result == 'save') {
      var url = home.text.trim();
      if (!url.startsWith('http')) url = 'https://$url';
      final u = Uri.tryParse(url);
      if (u != null && u.host.isNotEmpty) {
        final n = name.text.trim().isEmpty ? u.host : name.text.trim();
        var q = search.text.trim();
        if (q.isNotEmpty && !q.startsWith('http')) q = 'https://$q';
        final next = CustomSite(
          id: site?.id ?? 'site-${DateTime.now().millisecondsSinceEpoch}',
          name: n,
          home: url,
          search: q,
        );
        s.customSitesJson = CustomSite.encode(
          site == null ? [...sites, next] : [for (final x in sites) x.id == site.id ? next : x],
        );
        if (site == null) s.sources = [...s.sources.where((x) => x != 'link'), next.id];
      }
    }
    name.dispose();
    home.dispose();
    search.dispose();
  }
}

Future<void> openRemoteItem(BuildContext context, MusicSource source, RemoteItem item) =>
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
    String? playlist;
    if (list.length > 1) {
      if (!mounted) return;
      final choice = await _askPlaylist(context, widget.item.title);
      if (choice == null) return; // cancelled
      playlist = choice.isEmpty ? null : choice;
    }
    scope.downloads.add(list, playlist: playlist);
    final folder = await scope.downloads.folder();
    messenger.showSnackBar(
      SnackBar(
        content: Text('Downloading ${list.length} ${list.length == 1 ? 'song' : 'songs'} to $folder'),
        action: SnackBarAction(label: 'Show', onPressed: () => openDownloads(context)),
      ),
    );
  }

  /// Null: cancelled. Empty: just download. Otherwise the playlist name.
  static Future<String?> _askPlaylist(BuildContext context, String suggested) async {
    final name = TextEditingController(text: suggested);
    var make = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('Keep them together?'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Also save as a playlist'),
                  subtitle: const Text('In this order, in Playlists, once they\'ve downloaded'),
                  value: make,
                  onChanged: (v) => set(() => make = v),
                ),
                if (make)
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(
                      labelText: 'Playlist name',
                      border: OutlineInputBorder(),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Download')),
          ],
        ),
      ),
    );
    final n = name.text.trim();
    name.dispose();
    if (ok != true) return null;
    return make ? (n.isEmpty ? suggested : n) : '';
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
