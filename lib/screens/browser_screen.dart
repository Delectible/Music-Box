import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/crash_log.dart';
import '../core/scope.dart';
import '../core/sources.dart';
import 'get_music_screen.dart';

void openBrowser(BuildContext context, {required Uri url, required String siteName, CustomSite? site}) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BrowserScreen(url: url, siteName: siteName, site: site),
      ),
    );

/// Collects music file links on the page: <a href="….mp3">, <audio> /
/// <source> elements and og:audio tags.
const _scanJs = r'''
(function(){
  var exts=/\.(mp3|flac|m4a|aac|ogg|oga|opus|wav|alac|aiff?)(\?|#|$)/i, out=[], seen={};
  function add(u,t){ try{ u=new URL(u,location.href).href }catch(e){ return }
    if(!/^https?:/.test(u)||seen[u]) return; seen[u]=1; out.push({u:u,t:(t||'').replace(/\s+/g,' ').trim().slice(0,200)}); }
  document.querySelectorAll('a[href]').forEach(function(a){ var h=a.getAttribute('href')||'';
    if(exts.test(h)||a.hasAttribute('download')&&exts.test(a.href)) add(a.href, a.textContent||a.title||a.getAttribute('download')); });
  document.querySelectorAll('audio[src],audio source[src],video source[type^="audio"]').forEach(function(e){
    var s=e.getAttribute('src'); if(s&&s.indexOf('blob:')!==0) add(s,(e.closest('audio')||e).title||document.title); });
  document.querySelectorAll('meta[property="og:audio"],meta[property="og:audio:url"],meta[property="og:audio:secure_url"]')
    .forEach(function(m){ add(m.content, document.title); });
  return JSON.stringify({title:document.title, items:out});
})()
''';

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

  @override
  void initState() {
    super.initState();
    _url = widget.url.toString();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) => mounted ? setState(() => _progress = p) : null,
          onUrlChange: (c) => mounted && c.url != null ? setState(() => _url = c.url!) : null,
          onPageStarted: (_) => mounted ? setState(() => _found = const []) : null,
          onPageFinished: (_) => _scan(),
          onNavigationRequest: (r) {
            // Tapping a music file: offer it instead of opening it as a page.
            final u = Uri.tryParse(r.url);
            if (u != null && _isAudio(u)) {
              _offer([_track(u, '')]);
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

  static bool _isAudio(Uri u) =>
      RegExp(r'\.(mp3|flac|m4a|aac|ogg|oga|opus|wav|aiff?)$', caseSensitive: false).hasMatch(u.path);

  Future<void> _scan() async {
    try {
      var raw = await _web.runJavaScriptReturningResult(_scanJs);
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
    final file = Uri.decodeComponent(u.pathSegments.isEmpty ? 'track' : u.pathSegments.last);
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
  Future<void> _useAsSearch() async {
    final site = widget.site;
    if (site == null) return;
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
    if (ok != true || w.isEmpty || !mounted) return;
    final template = CustomSite.templateFrom(_url, w);
    final messenger = ScaffoldMessenger.of(context);
    if (!template.contains('{q}')) {
      messenger.showSnackBar(
        SnackBar(content: Text('"$w" isn\'t in this page\'s address, so it can\'t be reused')),
      );
      return;
    }
    final s = AppScope.of(context).settings;
    final sites = CustomSite.decode(s.customSitesJson);
    s.customSitesJson = CustomSite.encode([
      for (final c in sites)
        c.id == site.id ? CustomSite(id: c.id, name: c.name, home: c.home, search: template) : c,
    ]);
    messenger.showSnackBar(SnackBar(content: Text('Searching ${site.name} from Get music now works')));
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
            if (widget.site != null)
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'search') _useAsSearch();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'search', child: Text('Use this page for searching this site')),
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
        body: WebViewWidget(controller: _web),
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
