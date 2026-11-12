import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'crash_log.dart';
import 'http.dart';
import 'sources.dart';

/// One tap the person made while teaching Roadie a site: the link or button,
/// described so it can be found again on a similar page.
class StepSpec {
  /// The link's address as a pattern (numbers and names made general), or
  /// empty for buttons without a link.
  final String href;

  /// Its words ("download mp3"), lower case.
  final String text;

  /// Its kind and classes and those of its two parents: "a.btn.dl<div.box<li".
  final String sig;

  const StepSpec({this.href = '', this.text = '', this.sig = ''});

  factory StepSpec.fromTap(Map<String, Object?> tap) {
    final href = '${tap['href'] ?? ''}';
    return StepSpec(
      href: hrefPattern(href),
      text: normText('${tap['text'] ?? ''}'),
      sig: '${tap['sig'] ?? ''}',
    );
  }

  Map<String, String> toJson() => {'href': href, 'text': text, 'sig': sig};
  factory StepSpec.fromJson(Map<String, Object?> m) =>
      StepSpec(href: '${m['href'] ?? ''}', text: '${m['text'] ?? ''}', sig: '${m['sig'] ?? ''}');
}

/// How to get music from a site, learned from one example: which links on
/// its search results are songs, then which buttons to press on a song's
/// page until the file comes out.
class SiteRecipe {
  final StepSpec result;
  final List<StepSpec> steps;
  const SiteRecipe(this.result, this.steps);

  Map<String, Object?> toJson() => {
    'result': result.toJson(),
    'steps': [for (final s in steps) s.toJson()],
  };
  factory SiteRecipe.fromJson(Map<String, Object?> m) =>
      SiteRecipe(StepSpec.fromJson((m['result'] as Map? ?? const {}).cast<String, Object?>()), [
        for (final s in (m['steps'] as List? ?? const []))
          StepSpec.fromJson((s as Map).cast<String, Object?>()),
      ]);

  /// From the taps of a teaching run, the first on the results page. Taps
  /// that led nowhere (menus, cookie banners) were dropped already.
  static SiteRecipe? fromTaps(List<Map<String, Object?>> taps) {
    if (taps.isEmpty) return null;
    return SiteRecipe(StepSpec.fromTap(taps.first), [for (final t in taps.skip(1)) StepSpec.fromTap(t)]);
  }
}

String normText(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

/// "https://site.com/track/1234/night-drive?ref=5" → a pattern matching the
/// other songs' links: numbers, long codes and names become wildcards, the
/// fixed words ("track", "download") stay. Empty for "#" / javascript links.
String hrefPattern(String href) {
  final u = Uri.tryParse(href);
  if (u == null || !u.scheme.startsWith('http') || u.host.isEmpty) return '';
  String esc(String s) => RegExp.escape(s);
  final segs = u.pathSegments.where((s) => s.isNotEmpty).toList();
  final path = <String>[];
  for (var i = 0; i < segs.length; i++) {
    final s = segs[i];
    final last = i == segs.length - 1;
    if (RegExp(r'^\d+$').hasMatch(s)) {
      path.add(r'\d+');
    } else if (RegExp(r'\d').hasMatch(s) ||
        s.length >= 16 ||
        s.contains('-') ||
        s.contains('_') ||
        s.contains('%') ||
        s.contains('.') ||
        (last && s.length > 12)) {
      path.add('[^/?#]+');
    } else {
      path.add(esc(s));
    }
  }
  final keys = [for (final k in u.queryParameters.keys) '(?=.*[?&]${esc(k)}=)'];
  return '^${keys.join()}https?://${esc(u.host)}/${path.join('/')}/?(?:[?#].*)?\$';
}

/// The site had none of what was taught (it changed, or blocks this).
class RecipeFailed implements Exception {
  final String message;
  RecipeFailed(this.message);
  @override
  String toString() => message;
}

/// Records taps while teaching (the visible browser). Posts to RoadieTeach.
const teachJs = r'''
(function(){
  if (window.__roadieTeach) return; window.__roadieTeach = 1;
  function sig(e){ var p=[];
    for (var i=0; e && e.nodeType==1 && i<3; i++, e=e.parentElement){
      var c = (typeof e.className=='string') ? e.className.trim().split(/\s+/)
        .filter(function(x){ return x && !/\d{3,}/.test(x) }).slice(0,3).join('.') : '';
      p.push(e.tagName.toLowerCase() + (c ? '.'+c : ''));
    }
    return p.join('<'); }
  document.addEventListener('click', function(ev){
    var e = ev.target.closest('a,button,[onclick],[role=button],input[type=submit],input[type=button]') || ev.target;
    var href = e.href || (e.getAttribute && e.getAttribute('href')) || '';
    try { href = href ? new URL(href, location.href).href : '' } catch(x) {}
    RoadieTeach.postMessage(JSON.stringify({
      href: href,
      text: (e.innerText || e.textContent || e.value || e.title || e.getAttribute('aria-label') || '').replace(/\s+/g,' ').trim().slice(0,80),
      sig: sig(e), page: location.href }));
  }, true);
})()
''';

/// Finds what a [StepSpec] describes on the page. mode "all": every
/// matching link (search results); "best": the one most like it (a button).
/// Answers [{i, href, text}] and keeps the elements for [_clickJs].
@visibleForTesting
String findJs(StepSpec spec, String mode) =>
    '''
(function(spec, mode){
  function norm(s){ return (s||'').replace(/\\s+/g,' ').trim().toLowerCase() }
  function sig(e){ var p=[];
    for (var i=0; e && e.nodeType==1 && i<3; i++, e=e.parentElement){
      var c = (typeof e.className=='string') ? e.className.trim().split(/\\s+/)
        .filter(function(x){ return x && !/\\d{3,}/.test(x) }).slice(0,3).join('.') : '';
      p.push(e.tagName.toLowerCase() + (c ? '.'+c : ''));
    }
    return p.join('<'); }
  var re = null; try { re = spec.href ? new RegExp(spec.href, 'i') : null } catch(x) {}
  var want = spec.sig.split('<');
  var els = document.querySelectorAll('a,button,[onclick],[role=button],input[type=submit],input[type=button]');
  var out = [], seen = {};
  for (var k = 0; k < els.length; k++){
    var e = els[k], href = '';
    try { href = e.getAttribute('href') ? new URL(e.getAttribute('href'), location.href).href : '' } catch(x) {}
    var s = sig(e).split('<'), score = 0;
    if (re && href && re.test(href)) score += 3;
    if (s[0] == want[0]) score += 1;
    if (s.join('<') == spec.sig) score += 2;
    var text = norm(e.innerText || e.textContent || e.value || e.title || e.getAttribute('aria-label'));
    if (mode == 'best' && spec.text && text == spec.text) score += 3;
    else if (mode == 'best' && spec.text && text && text.indexOf(spec.text) >= 0) score += 1;
    var enough = mode == 'all' ? (re ? score >= 3 : score >= 3) : score >= 3;
    if (!enough) continue;
    if (mode == 'all') { if (!href || seen[href] || href == location.href) continue; seen[href] = 1; }
    out.push({ e: e, score: score, href: href, near: s.slice(0,2).join('<') == want.slice(0,2).join('<'),
      text: (e.innerText || e.textContent || e.title || '').replace(/\\s+/g,' ').trim().slice(0,200) });
  }
  // Results: links in the same part of the page as the one tapped (not the menu's).
  if (mode == 'all' && out.some(function(o){ return o.near })) out = out.filter(function(o){ return o.near });
  if (mode == 'best') out.sort(function(a,b){ return b.score - a.score });
  out = out.slice(0, mode == 'all' ? 40 : 1);
  window.__roadieEls = out.map(function(o){ return o.e });
  return JSON.stringify(out.map(function(o, i){ return { i: i, href: o.href, text: o.text } }));
})(${jsonEncode(spec.toJson())}, '$mode')
''';

String _clickJs(int i) =>
    '(function(){ var e = (window.__roadieEls||[])[$i]; if (e) { e.scrollIntoView(); e.click(); } })()';

/// Collects music file links on the page: <a href="….mp3">, <audio> /
/// <source> elements and og:audio tags.
const scanJs = r'''
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

final _audioExt = RegExp(r'\.(mp3|flac|m4a|aac|ogg|oga|opus|wav|aiff?)(\?|#|$)', caseSensitive: false);
bool looksLikeAudioUrl(String u) => _audioExt.hasMatch(Uri.tryParse(u)?.path ?? u);

/// A song title from a result's link text ("Artist - Title", or the name in
/// the address when the text is just "Download").
(String, String) titleOf(String text, String href) {
  var t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (t.length < 2 ||
      RegExp(
        r'^(download|play|listen|more|details|view|open|mp3|flac)\b',
        caseSensitive: false,
      ).hasMatch(t)) {
    final segs = Uri.tryParse(href)?.pathSegments.where((s) => s.isNotEmpty).toList() ?? const [];
    final name = segs.isEmpty ? 'Track' : Uri.decodeComponent(segs.last);
    t = name
        .replaceAll(RegExp(r'\.[a-z0-9]{2,4}$', caseSensitive: false), '')
        .replaceAll(RegExp(r'[-_]+'), ' ')
        .trim();
  }
  final dash = RegExp(r'^(.+?)\s+[-–—]\s+(.+)$').firstMatch(t);
  return dash == null ? ('', t) : (dash.group(1)!.trim(), dash.group(2)!.trim());
}

/// Repeats a taught recipe in the hidden browser (PageRunner.kt), one thing
/// at a time.
class RecipeRunner {
  static const _ch = MethodChannel('roadie/library');
  static Future<void> _queue = Future.value();

  /// Runs [job] after the ones before it (one hidden browser).
  static Future<T> _serial<T>(Future<T> Function() job) {
    final done = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        done.complete(await job());
      } on Object catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  static Future<Map<String, Object?>> _load(String url) async =>
      (await _ch.invokeMapMethod<String, Object?>('pageLoad', {'url': url, 'ms': 40000})) ?? const {};

  static Future<String> _eval(String code) async =>
      await _ch.invokeMethod<String>('pageEval', {'code': code}) ?? '';

  static Future<Map<String, Object?>> _click(int i) async =>
      (await _ch.invokeMapMethod<String, Object?>('pageClick', {'code': _clickJs(i), 'ms': 25000})) ??
      const {};

  static Future<List<Map<String, Object?>>> _find(StepSpec spec, String mode) async {
    final raw = await _eval(findJs(spec, mode));
    if (raw.isEmpty) return const [];
    return [for (final m in jsonDecode(raw) as List) (m as Map).cast<String, Object?>()];
  }

  static Future<List<Map<String, Object?>>> _scan() async {
    final raw = await _eval(scanJs);
    if (raw.isEmpty) return const [];
    return [
      for (final m in ((jsonDecode(raw) as Map)['items'] as List? ?? const []))
        (m as Map).cast<String, Object?>(),
    ];
  }

  /// The site's cookies, for downloading the file outside the browser.
  static Future<String?> cookies(Uri u) async {
    try {
      return await _ch.invokeMethod<String>('cookies', {'url': '$u'});
    } on Object {
      return null;
    }
  }

  static Future<bool> _isMusic(String u) async {
    if (looksLikeAudioUrl(u)) return true;
    try {
      return (await Http.probe(Uri.parse(u), headers: _cookieHeader(await cookies(Uri.parse(u))))).kind ==
          LinkKind.music;
    } on Object {
      return false;
    }
  }

  static Map<String, String>? _cookieHeader(String? c) => c == null || c.isEmpty ? null : {'Cookie': c};

  /// The songs on the site's results for [q]: links like the one tapped
  /// when teaching, plus any music files right on the page.
  static Future<List<RemoteItem>> search(CustomSite site, String q) => _serial(() async {
    final recipe = site.recipe!;
    final r = await _load('${site.searchUri(q)}');
    if (r['kind'] == 'none' && '${r['url']}'.isEmpty) throw RecipeFailed('${site.name} didn\'t open');
    final links = await _find(recipe.result, 'all');
    final files = await _scan();
    final out = <RemoteItem>[];
    RemoteItem item(String href, String text, {required bool file}) {
      final (artist, title) = titleOf(text, href);
      final page = Uri.parse(href);
      return RemoteItem(
        source: site.id,
        id: href,
        title: title,
        artist: artist.isNotEmpty ? artist : site.name,
        single: true,
        data: RemoteTrack(
          title: title,
          artist: artist,
          url: page,
          ext: 'mp3',
          quality: site.name,
          // The file is found when it's needed: preview or download.
          resolveUrl: file ? null : () => resolve(site, href),
        ),
      );
    }

    for (final f in files) {
      out.add(item('${f['u']}', '${f['t'] ?? ''}', file: true));
    }
    for (final l in links) {
      final href = '${l['href']}';
      if (out.any((o) => o.id == href)) continue;
      out.add(item(href, '${l['text'] ?? ''}', file: recipe.steps.isEmpty && looksLikeAudioUrl(href)));
    }
    return out;
  });

  /// Opens a song's page and presses the taught buttons until a music file
  /// comes out; its address.
  static Future<Uri> resolve(CustomSite site, String page) => _serial(() async {
    final recipe = site.recipe!;
    if (recipe.steps.isEmpty && await _isMusic(page)) return Uri.parse(page);
    await _load(page);
    for (final step in recipe.steps) {
      final found = await _find(step, 'best');
      // Not on this page (an optional step, or the page skipped it): try the next.
      if (found.isEmpty) continue;
      final href = '${found.first['href'] ?? ''}';
      if (href.isNotEmpty && !href.startsWith('javascript')) {
        if (await _isMusic(href)) return Uri.parse(href);
      }
      final r = await _click((found.first['i'] as num?)?.toInt() ?? 0);
      final url = '${r['url'] ?? ''}';
      if (r['kind'] == 'download' && url.isNotEmpty) return Uri.parse(url);
      if (r['kind'] == 'nav' && url.isNotEmpty && await _isMusic(url)) return Uri.parse(url);
      if (r['kind'] == 'none') CrashLog.note('${site.name}: a taught step led nowhere ($step)');
    }
    // The buttons are done (or gone): a music file on this page will do.
    final files = await _scan();
    if (files.isNotEmpty) return Uri.parse('${files.first['u']}');
    throw RecipeFailed('Couldn\'t repeat the steps for ${site.name}. Open the site, or teach it again');
  });
}
