import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/crash_log.dart';
import '../core/http.dart';
import '../core/recipe.dart';
import '../core/scope.dart';
import '../core/sources.dart';
import 'get_music_screen.dart';

void openBrowser(BuildContext context, {required Uri url, required String siteName, CustomSite? site}) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BrowserScreen(url: url, siteName: siteName, site: site),
      ),
    );

/// A web browser for sites without a search Roadie understands: browse as
/// usual; music files on each page are listed to preview and download.
class BrowserScreen extends StatefulWidget {
  final Uri url;
  final String siteName;
  final CustomSite? site;
  const BrowserScreen({super.key, required this.url, required this.siteName, this.site});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  late final WebViewController _web;
  String _url = '';
  String _title = '';
  int _progress = 0;
  List<RemoteTrack> _found = const [];

  /// The site as saved (it changes when a search or recipe is saved here).
  late CustomSite? _site = widget.site;

  // Teaching Roadie the site: the taps so far, each marked when a new page
  // followed it (taps that led nowhere aren't steps).
  bool _teaching = false;

  /// File names sites gave with downloads ("night-drive.mp3"), by address.
  final _names = <String, String?>{};
  final _taps = <Map<String, Object?>>[];

  @override
  void initState() {
    super.initState();
    _url = widget.url.toString();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'RoadieTeach',
        onMessageReceived: (m) {
          if (!_teaching) return;
          try {
            final tap = (jsonDecode(m.message) as Map).cast<String, Object?>()..['led'] = false;
            setState(() => _taps.add(tap));
          } on Object {
            // Not a tap.
          }
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) => mounted ? setState(() => _progress = p) : null,
          onUrlChange: (c) => mounted && c.url != null ? setState(() => _url = c.url!) : null,
          onPageStarted: (url) {
            if (!mounted) return;
            setState(() {
              _found = const [];
              // The last tap opened a new page: it's a step.
              if (_teaching && _taps.isNotEmpty && _taps.last['page'] != url) _taps.last['led'] = true;
            });
          },
          onPageFinished: (_) {
            _scan();
            if (_teaching) _web.runJavaScript(teachJs);
          },
          onNavigationRequest: (r) async {
            // Tapping a music file: offer it instead of opening it as a page.
            final u = Uri.tryParse(r.url);
            if (u == null) return NavigationDecision.navigate;
            if (_isAudio(u) || await _isDownload(u)) {
              if (_teaching) {
                unawaited(_learned(u));
              } else {
                _offer([_track(u, '')]);
              }
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onWebResourceError: (e) {
            if (e.isForMainFrame ?? false) CrashLog.note('browser ${widget.siteName}: ${e.description}');
          },
        ),
      )
      ..loadRequest(widget.url);
  }

  /// A link that downloads a music file without saying so in its address
  /// ("download.php?id=5"): looked at while teaching, or when it looks like one.
  Future<bool> _isDownload(Uri u) async {
    final maybe =
        (_teaching && _taps.isNotEmpty) ||
        RegExp(r'(download|/dl/|/get/|/file/|attachment)', caseSensitive: false).hasMatch(u.toString());
    if (!maybe || !u.scheme.startsWith('http')) return false;
    try {
      final c = await RecipeRunner.cookies(u);
      final info = await Http.probe(u, headers: c == null || c.isEmpty ? null : {'Cookie': c});
      if (info.kind == LinkKind.music) _names[u.toString()] = info.fileName;
      return info.kind == LinkKind.music;
    } on Object {
      return false;
    }
  }

  /// Starts teaching: the search page first, then tap a song, then the
  /// download button(s) until the file comes.
  Future<void> _teach() async {
    var site = _site;
    if (site == null) return;
    if (!site.search.contains('{q}')) {
      if (!await _useAsSearch()) return;
      site = _site!;
    }
    if (!mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Teach Roadie ${site!.name}'),
        content: const Text(
          'On the search results:\n\n'
          '1. Tap a song.\n'
          '2. Tap the download button, and any more buttons it takes, until the file starts.\n\n'
          'Roadie remembers the steps and repeats them by itself when you search this site in Get music.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Start')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    setState(() {
      _teaching = true;
      _taps.clear();
    });
    await _web.runJavaScript(teachJs);
  }

  /// The taps led to a music file: save them as the site's recipe.
  Future<void> _learned(Uri file) async {
    final site = _site;
    final steps = [
      for (var i = 0; i < _taps.length; i++)
        if (_taps[i]['led'] == true || i == _taps.length - 1) _taps[i],
    ];
    setState(() => _teaching = false);
    final recipe = SiteRecipe.fromTaps(steps);
    if (site == null || recipe == null) {
      _offer([_track(file, '')]);
      return;
    }
    final s = AppScope.of(context).settings;
    final saved = site.copyWith(recipe: recipe);
    s.customSitesJson = CustomSite.encode([
      for (final c in CustomSite.decode(s.customSitesJson)) c.id == site.id ? saved : c,
    ]);
    _site = saved;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Learned'),
        content: Text(
          'Searching ${site.name} in Get music now finds songs and downloads them like the other sources '
          '(${recipe.steps.length + 1} ${recipe.steps.isEmpty ? 'step' : 'steps'}). '
          'If the site changes and it stops working, teach it again.',
        ),
        actions: [FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK'))],
      ),
    );
    if (mounted) _offer([_track(file, '')]);
  }

  static bool _isAudio(Uri u) =>
      RegExp(r'\.(mp3|flac|m4a|aac|ogg|oga|opus|wav|aiff?)$', caseSensitive: false).hasMatch(u.path);

  Future<void> _scan() async {
    try {
      var raw = await _web.runJavaScriptReturningResult(scanJs);
      // Android hands back the JSON string itself encoded as a string.
      if (raw is String && raw.startsWith('"')) raw = jsonDecode(raw) as Object;
      final m = jsonDecode('$raw') as Map<String, Object?>;
      final title = '${m['title'] ?? ''}';
      final items = (m['items'] as List? ?? const []).cast<Map<String, Object?>>();
      if (!mounted) return;
      setState(() {
        _title = title;
        _found = [for (final i in items) _track(Uri.parse('${i['u']}'), '${i['t'] ?? ''}')];
      });
    } on Object catch (e) {
      CrashLog.note('browser scan failed: $e');
    }
  }

  RemoteTrack _track(Uri u, String text) {
    // The name the site sent with the file beats an address like "/get?id=5".
    final file =
        _names[u.toString()] ?? Uri.decodeComponent(u.pathSegments.isEmpty ? 'track' : u.pathSegments.last);
    final dot = file.lastIndexOf('.');
    final ext = dot > 0 ? file.substring(dot + 1).toLowerCase() : 'mp3';
    final stem = dot > 0 ? file.substring(0, dot) : file;
    // Link text like "Download" or "MP3" isn't a title.
    final useText =
        text.length > 2 &&
        !RegExp(
          r'^(download|mp3|flac|ogg|wav|play|listen|link|here|file)\b',
          caseSensitive: false,
        ).hasMatch(text);
    return RemoteTrack(
      title: useText ? text : stem.replaceAll('_', ' ').trim(),
      url: u,
      ext: DirectLink.audioExts.contains(ext) ? ext : 'mp3',
      quality: ext.toUpperCase(),
    );
  }

  void _offer(List<RemoteTrack> tracks) {
    if (tracks.isEmpty) return;
    openRemoteItem(
      context,
      PageSource(widget.siteName),
      RemoteItem(
        source: 'page',
        id: _url,
        title: _title.isNotEmpty ? _title : widget.siteName,
        artist: Uri.tryParse(_url)?.host ?? '',
        data: tracks,
        single: tracks.length == 1,
      ),
    );
  }

  /// Saves this page's address as the site's search, with {q} for the words.
  Future<bool> _useAsSearch() async {
    final site = _site;
    if (site == null) return false;
    final words = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Use this page for searching'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Search for something on the site first. What words did you search for?'),
            const SizedBox(height: 12),
            TextField(
              controller: words,
              autofocus: true,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Save')),
        ],
      ),
    );
    final w = words.text.trim();
    words.dispose();
    if (ok != true || w.isEmpty || !mounted) return false;
    final template = CustomSite.templateFrom(_url, w);
    final messenger = ScaffoldMessenger.of(context);
    if (!template.contains('{q}')) {
      messenger.showSnackBar(
        SnackBar(content: Text('"$w" isn\'t in this page\'s address, so it can\'t be reused')),
      );
      return false;
    }
    final s = AppScope.of(context).settings;
    final sites = CustomSite.decode(s.customSitesJson);
    final saved = site.copyWith(search: template);
    s.customSitesJson = CustomSite.encode([for (final c in sites) c.id == site.id ? saved : c]);
    _site = saved;
    messenger.showSnackBar(
      SnackBar(content: Text('Searching ${site.name} from Get music now opens its results here')),
    );
    return true;
  }

  void _forget() {
    final site = _site;
    if (site == null) return;
    final s = AppScope.of(context).settings;
    final saved = site.copyWith(forget: true);
    s.customSitesJson = CustomSite.encode([
      for (final c in CustomSite.decode(s.customSitesJson)) c.id == site.id ? saved : c,
    ]);
    setState(() => _site = saved);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (popped, _) async {
        if (popped) return;
        final nav = Navigator.of(context);
        if (await _web.canGoBack()) {
          await _web.goBack();
        } else {
          nav.pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _title.isNotEmpty ? _title : widget.siteName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(_url, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Back',
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: () => _web.goBack(),
            ),
            IconButton(
              tooltip: 'Forward',
              icon: const Icon(Icons.arrow_forward_rounded),
              onPressed: () => _web.goForward(),
            ),
            IconButton(
              tooltip: 'Reload',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: () => _web.reload(),
            ),
            if (_site != null)
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'search') _useAsSearch();
                  if (v == 'teach') _teach();
                  if (v == 'forget') _forget();
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'teach', child: Text('Teach Roadie to download from this site')),
                  const PopupMenuItem(value: 'search', child: Text('Use this page for searching this site')),
                  if (_site!.recipe != null)
                    const PopupMenuItem(value: 'forget', child: Text('Forget what Roadie learned here')),
                ],
              ),
          ],
          bottom: _progress < 100
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(3),
                  child: LinearProgressIndicator(value: _progress / 100, minHeight: 3),
                )
              : null,
        ),
        body: Column(
          children: [
            if (_teaching) _TeachBar(taps: _taps.length, onCancel: () => setState(() => _teaching = false)),
            Expanded(child: WebViewWidget(controller: _web)),
          ],
        ),
        floatingActionButton: _found.isEmpty
            ? null
            : FloatingActionButton.extended(
                backgroundColor: cs.primary,
                foregroundColor: cs.onPrimary,
                onPressed: () => _offer(_found),
                icon: const Icon(Icons.library_music_rounded),
                label: Text('${_found.length} music ${_found.length == 1 ? 'file' : 'files'} here'),
              ),
      ),
    );
  }
}

/// What to do next while teaching.
class _TeachBar extends StatelessWidget {
  final int taps;
  final VoidCallback onCancel;
  const _TeachBar({required this.taps, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(
          children: [
            Icon(Icons.school_rounded, color: cs.onTertiaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                taps == 0
                    ? 'Teaching: tap a song in the results'
                    : 'Now tap the download button, and any more it takes, until the file starts',
                style: TextStyle(color: cs.onTertiaryContainer, fontSize: 16),
              ),
            ),
            TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: onCancel,
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}
