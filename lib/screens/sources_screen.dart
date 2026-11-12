import 'package:flutter/material.dart';

import '../core/scope.dart';
import '../core/settings.dart';
import '../core/sources.dart';
import '../core/ytdlp.dart';

void openSources(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SourcesScreen()));

IconData sourceIcon(String id) => switch (id) {
  'soundcloud' => Icons.cloud_rounded,
  'archive' => Icons.account_balance_rounded,
  'youtube' => Icons.smart_display_rounded,
  'podcasts' => Icons.podcasts_rounded,
  'jamendo' => Icons.music_note_rounded,
  'ccmixter' => Icons.graphic_eq_rounded,
  'link' => Icons.link_rounded,
  _ => Icons.public_rounded,
};

List<MusicSource> builtIns(Settings s) => allSources(jamendoKey: s.jamendoKey, lossless: s.losslessFor);

/// Get music's sources: drag to reorder, remove any, add built-ins back or
/// a new site, and each one's own settings.
class SourcesScreen extends StatelessWidget {
  const SourcesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).settings;
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final builtIn = {for (final x in builtIns(s)) x.id: x};
        final sites = {for (final x in CustomSite.decode(s.customSitesJson)) x.id: x};
        final order = s.sourceOrder.where((id) => builtIn.containsKey(id) || sites.containsKey(id)).toList();
        final missing = builtInSources.where((id) => !order.contains(id)).toList();
        String name(String id) => builtIn[id]?.name ?? sites[id]?.name ?? id;
        String blurb(String id) => builtIn[id]?.blurb ?? sites[id]?.home ?? '';
        return Scaffold(
          appBar: AppBar(title: const Text('Download sources')),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _add(context, missing, builtIn),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Add a source'),
          ),
          body: order.isEmpty
              ? const Center(child: Text('No sources. Add one to search and download music.'))
              : ReorderableListView(
                  buildDefaultDragHandles: false,
                  padding: const EdgeInsets.only(bottom: 100),
                  header: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                    child: Text(
                      'Drag to reorder. Tap one for its settings.',
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  ),
                  onReorderItem: (from, to) {
                    final o = [...order];
                    o.insert(to, o.removeAt(from));
                    s.sourceOrder = o;
                  },
                  children: [
                    for (var i = 0; i < order.length; i++)
                      ListTile(
                        key: ValueKey(order[i]),
                        minTileHeight: 72,
                        leading: ReorderableDragStartListener(
                          index: i,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.drag_handle_rounded),
                              const SizedBox(width: 12),
                              Icon(sourceIcon(order[i]), color: cs.primary),
                            ],
                          ),
                        ),
                        title: Text(name(order[i])),
                        subtitle: Text(blurb(order[i]), maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () => sites[order[i]] != null
                            ? editSite(context, sites[order[i]])
                            : _settings(context, order[i], name(order[i])),
                        trailing: IconButton(
                          tooltip: 'Remove',
                          icon: const Icon(Icons.remove_circle_outline_rounded),
                          onPressed: () {
                            s.sourceOrder = [...order]..remove(order[i]);
                            s.sources = s.sources.where((x) => x != order[i]).toList();
                          },
                        ),
                      ),
                  ],
                ),
        );
      },
    );
  }

  /// Built-ins that were removed, or a new site.
  static Future<void> _add(BuildContext context, List<String> missing, Map<String, MusicSource> builtIn) =>
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        constraints: const BoxConstraints(maxWidth: 640),
        builder: (sheet) {
          final s = AppScope.of(context).settings;
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final id in missing)
                  ListTile(
                    leading: Icon(sourceIcon(id)),
                    title: Text('Add back ${builtIn[id]?.name ?? id}'),
                    subtitle: Text(builtIn[id]?.blurb ?? ''),
                    onTap: () {
                      s.sourceOrder = [...s.sourceOrder, id];
                      Navigator.of(sheet).pop();
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.add_link_rounded),
                  title: const Text('A website…'),
                  subtitle: const Text('Any free music site, by its address'),
                  onTap: () {
                    Navigator.of(sheet).pop();
                    editSite(context, null);
                  },
                ),
              ],
            ),
          );
        },
      );

  /// A built-in source's own settings.
  static Future<void> _settings(BuildContext context, String id, String name) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (sheet) {
      final s = AppScope.of(context).settings;
      return ListenableBuilder(
        listenable: s,
        builder: (sheet, _) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheet).bottom),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  leading: Icon(sourceIcon(id)),
                  title: Text(name, style: Theme.of(sheet).textTheme.titleLarge),
                ),
                if (id == 'soundcloud') ...[
                  SwitchListTile(
                    secondary: const Icon(Icons.high_quality_rounded),
                    title: const Text('The artist\'s original file when they allow it'),
                    subtitle: const Text('Often WAV, FLAC or high-quality MP3; otherwise the best stream'),
                    value: s.losslessFor(id),
                    onChanged: (v) => s.setLossless(id, v),
                  ),
                  const YtdlpPanel(),
                ],
                if (losslessSources.contains(id))
                  SwitchListTile(
                    secondary: const Icon(Icons.high_quality_rounded),
                    title: const Text('Prefer lossless (FLAC)'),
                    subtitle: const Text('Bigger files; MP3 when there\'s no FLAC'),
                    value: s.losslessFor(id),
                    onChanged: (v) => s.setLossless(id, v),
                  ),
                if (id == 'jamendo') const _JamendoKeyField(),
                if (id == 'youtube')
                  const ListTile(
                    leading: Icon(Icons.info_outline_rounded),
                    title: Text('Saved as AAC (M4A), the best quality YouTube offers for audio'),
                  ),
                if (id == 'podcasts')
                  const ListTile(
                    leading: Icon(Icons.info_outline_rounded),
                    title: Text('Episodes come straight from each show\'s own feed; tags aren\'t looked up'),
                  ),
                if (id == 'link')
                  const ListTile(
                    leading: Icon(Icons.info_outline_rounded),
                    title: Text(
                      'Paste a link to a music file, a podcast feed, a YouTube video or a web page',
                    ),
                  ),
                SwitchListTile(
                  secondary: const Icon(Icons.travel_explore_rounded),
                  title: const Text('Look up missing tags and covers'),
                  subtitle: const Text('For every source, on MusicBrainz'),
                  value: s.lookUpDownloads,
                  onChanged: (v) => s.lookUpDownloads = v,
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _JamendoKeyField extends StatefulWidget {
  const _JamendoKeyField();

  @override
  State<_JamendoKeyField> createState() => _JamendoKeyFieldState();
}

class _JamendoKeyFieldState extends State<_JamendoKeyField> {
  late final _c = TextEditingController(text: AppScope.of(context).settings.jamendoKey);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
    child: TextField(
      controller: _c,
      decoration: const InputDecoration(
        labelText: 'Jamendo Client ID',
        helperText: 'Free from developer.jamendo.com',
        border: OutlineInputBorder(),
      ),
      onChanged: (v) => AppScope.of(context).settings.jamendoKey = v.trim(),
    ),
  );
}

/// Add (site == null) or edit a website source.
Future<void> editSite(BuildContext context, CustomSite? site) async {
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
                  helperText: 'Where {q} is, your search words go. Or set it later from the browser\'s menu.',
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
    s.sourceOrder = s.sourceOrder.where((x) => x != site.id).toList();
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
      if (site == null) {
        s.sources = [...s.sources.where((x) => x != 'link'), next.id];
        s.sourceOrder = [...s.sourceOrder, next.id];
      }
    }
  }
  name.dispose();
  home.dispose();
  search.dispose();
}

/// The downloader behind SoundCloud (yt-dlp): version, update now, the
/// daily background check and which release line to follow.
class YtdlpPanel extends StatefulWidget {
  const YtdlpPanel({super.key});

  @override
  State<YtdlpPanel> createState() => _YtdlpPanelState();
}

class _YtdlpPanelState extends State<YtdlpPanel> {
  late Future<String> _version = Ytdlp.version();
  bool _checking = false;
  String? _result;

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _result = null;
    });
    String r;
    try {
      final s = await Ytdlp.update();
      r = s == 'DONE' ? 'Updated' : (s == 'ALREADY_UP_TO_DATE' ? 'Already up to date' : s);
    } on Object catch (e) {
      r = 'Couldn\'t check: $e';
    }
    if (!mounted) return;
    setState(() {
      _checking = false;
      _result = r;
      _version = Ytdlp.version();
    });
  }

  static String _ago(String last) {
    final ms = int.tryParse(last.split('|').first);
    if (ms == null) return 'never';
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (d.inMinutes < 2) return 'just now';
    if (d.inHours < 2) return '${d.inMinutes} min ago';
    if (d.inDays < 2) return '${d.inHours} h ago';
    return '${d.inDays} days ago';
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).settings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 24),
        FutureBuilder<String>(
          future: _version,
          builder: (context, v) => ListTile(
            leading: const Icon(Icons.system_update_rounded),
            title: Text('Downloader: yt-dlp ${v.data ?? '…'}'),
            subtitle: Text(
              _result ??
                  'Last checked ${_ago(s.ytdlpLastCheck)}. Updates fix SoundCloud changes, no new app needed.',
            ),
            trailing: _checking
                ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
                : TextButton(onPressed: _check, child: const Text('Check now')),
          ),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.update_rounded),
          title: const Text('Check for updates in the background'),
          subtitle: const Text('Once a day, when there\'s internet'),
          value: s.ytdlpAutoUpdate,
          onChanged: (v) => s.ytdlpAutoUpdate = v,
        ),
        ListTile(
          leading: const Icon(Icons.alt_route_rounded),
          title: const Text('Release line'),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Stable'),
                  selected: s.ytdlpChannel == 'stable',
                  onSelected: (_) => s.ytdlpChannel = 'stable',
                ),
                ChoiceChip(
                  label: const Text('Nightly (newest fixes)'),
                  selected: s.ytdlpChannel == 'nightly',
                  onSelected: (_) => s.ytdlpChannel = 'nightly',
                ),
              ],
            ),
          ),
        ),
        if (s.ytdlpChannel == 'stable')
          SwitchListTile(
            secondary: const Icon(Icons.healing_rounded),
            title: const Text('Try nightly when stable can\'t fix a failure'),
            subtitle: const Text('Fixes often land in nightly first'),
            value: s.ytdlpNightlyFallback,
            onChanged: (v) => s.ytdlpNightlyFallback = v,
          ),
      ],
    );
  }
}
