import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'crash_log.dart';
import 'metadata.dart';

/// How Roadie is reaching what's playing: best first.
enum PhoneVia {
  session('Media sessions', 'Full info and controls'),
  browser('Direct link', 'Full info and controls, no permission'),
  broadcast('Track broadcasts', 'Song info only; buttons sent as media keys'),
  keys('Media keys', 'Buttons only');

  final String label;
  final String detail;
  const PhoneVia(this.label, this.detail);

  static PhoneVia byName(String? n) => values.where((v) => v.name == n).firstOrNull ?? keys;
}

/// One app's now playing: usually the head unit's Bluetooth app relaying
/// the phone (whatever app is playing there: music, audiobooks, podcasts).
class PhoneTrack {
  final String? key; // the native session; null when only broadcasts tell us
  final String app;
  final String label;
  final PhoneVia via;
  final String title, artist, album;
  final Duration duration;
  final Duration position;
  final DateTime at; // when [position] was true
  final bool playing;
  final int actions;
  final String? art;

  const PhoneTrack({
    required this.key,
    required this.app,
    required this.label,
    required this.via,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    required this.position,
    required this.at,
    required this.playing,
    required this.actions,
    required this.art,
  });

  static String _s(Object? v) => v is String ? v.trim() : '';
  static Duration _ms(Object? v) => Duration(milliseconds: v is num && v > 0 ? v.toInt() : 0);

  factory PhoneTrack.fromMap(Map<Object?, Object?> m) => PhoneTrack(
    key: m['key'] as String?,
    app: _s(m['app']),
    label: _s(m['label']),
    via: PhoneVia.byName(m['via'] as String?),
    title: _s(m['title']),
    artist: _s(m['artist']),
    album: _s(m['album']),
    duration: _ms(m['duration']),
    position: _ms(m['position']),
    at: DateTime.now(),
    playing: m['playing'] == true,
    actions: (m['actions'] as num?)?.toInt() ?? 0,
    art: m['art'] as String?,
  );

  /// From a track-change broadcast: info only.
  factory PhoneTrack.fromBroadcast(Map<Object?, Object?> m) => PhoneTrack(
    key: null,
    app: '',
    label: 'Bluetooth',
    via: PhoneVia.broadcast,
    title: _s(m['title']),
    artist: _s(m['artist']),
    album: _s(m['album']),
    duration: _ms(m['duration']),
    position: _ms(m['position']),
    at: DateTime.fromMillisecondsSinceEpoch((m['at'] as num?)?.toInt() ?? 0),
    playing: m['playing'] == true,
    actions: 0,
    art: null,
  );

  bool get hasInfo => title.isNotEmpty;

  /// Android's PlaybackState action bits; with none reported, assume all.
  bool get canSeek => via == PhoneVia.session || via == PhoneVia.browser
      ? (actions == 0 || actions & 256 != 0) && duration > Duration.zero
      : false;
  bool get canSkip => actions == 0 || actions & (32 | 16) != 0;

  /// Where it is now (it moves on by itself while playing).
  Duration get now {
    if (!playing) return position;
    final p = position + DateTime.now().difference(at);
    return duration > Duration.zero && p > duration ? duration : p;
  }

  bool get looksBluetooth {
    final t = '$app $label'.toLowerCase();
    return t.contains('bluetooth') || t.contains('a2dp') || RegExp(r'\bbt|\.bt').hasMatch(t);
  }
}

/// A head unit app that can be opened (its own Bluetooth music screen).
typedef PhoneApp = ({String app, String label, bool bluetooth});

/// A media browser service another app offers (a direct link to its player).
typedef PhoneBrowser = ({String app, String service, String label});

/// Roadie's link to the phone over the head unit's Bluetooth: Android
/// doesn't let an ordinary app receive a phone's audio itself, so the head
/// unit's own Bluetooth app keeps playing it, and Roadie shows and controls
/// what it's playing (Phone.kt has the ways in).
class PhoneLink extends ChangeNotifier {
  PhoneLink._();
  static final instance = PhoneLink._();

  static const _ch = MethodChannel('roadie/phone');
  static const _events = EventChannel('roadie/phone/events');

  bool supported = false;
  bool access = false;
  List<PhoneTrack> sessions = const [];
  List<PhoneBrowser> browsers = const [];
  String? browserApp;
  String browserState = 'off';
  PhoneTrack? broadcast;
  String broadcastRaw = '';
  Map<String, Object?> bluetooth = const {};
  List<PhoneApp> apps = const [];

  /// The app picked by hand (else the best one is used).
  String? chosen;

  /// Covers looked up online for tracks that came without one.
  final _covers = <String, String?>{};
  // Lives as long as the app.
  // ignore: cancel_subscriptions
  StreamSubscription<Object?>? _sub;
  bool _autoTried = false;

  Future<T?> _call<T>(String m, [Map<String, Object?>? a]) async {
    try {
      return await _ch.invokeMethod<T>(m, a);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      CrashLog.note('phone $m: ${e.message}');
      return null;
    }
  }

  Future<void> start() async {
    if (_sub != null) return;
    final snap = await _call<Map<Object?, Object?>>('snapshot');
    if (snap == null) return; // tests, or not Android
    supported = true;
    _apply(snap);
    _sub = _events.receiveBroadcastStream().listen((e) {
      if (e is Map) _apply(e);
    }, onError: (Object e) => CrashLog.note('phone events: $e'));
    apps = ((await _call<List<Object?>>('apps')) ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map((m) => (app: m['app'] as String, label: m['label'] as String, bluetooth: m['score'] == 2))
        .toList();
    notifyListeners();
  }

  /// Looks again (back from Android's settings).
  Future<void> refresh() async {
    final snap = await _call<Map<Object?, Object?>>('snapshot');
    if (snap != null) _apply(snap);
  }

  /// Bluetooth's own report needs a permission on newer Android: asked
  /// only once the phone screen is opened.
  Future<void> askBluetooth() => _call<bool>('askBluetooth');

  @visibleForTesting
  void debugSet({List<PhoneTrack> sessions = const [], bool access = true, bool supported = true}) {
    this.supported = supported;
    this.access = access;
    this.sessions = sessions;
    notifyListeners();
  }

  void _apply(Map<Object?, Object?> m) {
    access = m['access'] == true;
    sessions = ((m['sessions'] as List?) ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map(PhoneTrack.fromMap)
        .toList();
    browsers = ((m['browsers'] as List?) ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map((b) => (app: b['app'] as String, service: b['service'] as String, label: b['label'] as String))
        .toList();
    final br = (m['browser'] as Map?) ?? const {};
    browserApp = br['app'] as String?;
    browserState = (br['state'] as String?) ?? 'off';
    final b = m['broadcast'];
    if (b is Map) {
      broadcast = PhoneTrack.fromBroadcast(b);
      broadcastRaw = '${b['action']}: ${b['extras'] ?? ''}';
    }
    bluetooth = ((m['bluetooth'] as Map?) ?? const {}).cast<String, Object?>();
    _autoLink();
    final t = current;
    if (t != null && t.art == null && t.hasInfo) unawaited(_findCover(t));
    notifyListeners();
  }

  /// Without notification access, link straight to the Bluetooth app's
  /// player if it offers one (once; it can be changed by hand).
  void _autoLink() {
    if (_autoTried || access || browserApp != null) return;
    final bt = browsers.where((b) {
      final t = '${b.app} ${b.service} ${b.label}'.toLowerCase();
      return t.contains('bluetooth') || t.contains('a2dp') || RegExp(r'\bbt|\.bt').hasMatch(t);
    }).firstOrNull;
    if (bt == null) return;
    _autoTried = true;
    unawaited(link(bt));
  }

  /// What to show: the app picked by hand, else whatever's playing
  /// (Bluetooth first), else the last broadcast.
  PhoneTrack? get current {
    final live = sessions.where((s) => s.hasInfo || s.playing).toList();
    if (chosen != null) {
      final c = live.where((s) => s.key == chosen).firstOrNull;
      if (c != null) return c;
    }
    int rank(PhoneTrack s) => (s.playing ? 4 : 0) + (s.looksBluetooth ? 2 : 0) + (s.hasInfo ? 1 : 0);
    live.sort((a, b) => rank(b) - rank(a));
    if (live.isNotEmpty) return live.first;
    final b = broadcast;
    if (b != null && b.hasInfo) return b;
    return null;
  }

  /// The picture to show for [t]: its own, else one found online.
  String? artFor(PhoneTrack t) => t.art ?? _covers[_coverKey(t)];

  static String _coverKey(PhoneTrack t) => '${t.artist}|${t.album.isEmpty ? t.title : t.album}';

  Future<void> _findCover(PhoneTrack t) async {
    final k = _coverKey(t);
    if (_covers.containsKey(k) || t.artist.isEmpty) return;
    _covers[k] = null;
    final found = await CoverSearch.find(artist: t.artist, album: t.album, title: t.title);
    if (found == null) return;
    final dir = await coverCacheDir();
    final name = k.hashCode.toUnsigned(32).toRadixString(16);
    final path = await saveCover(found.url, File('$dir/phone_$name.jpg'));
    if (path == null) return;
    _covers[k] = path;
    notifyListeners();
  }

  /// Which way the buttons go for [t].
  PhoneVia controlVia(PhoneTrack? t) => t?.key != null ? t!.via : PhoneVia.keys;

  Future<void> _do(String action, {int? ms}) async {
    final t = current;
    if (t?.key != null) {
      await _call<bool>('control', {'app': t!.key, 'action': action, 'ms': ms});
    } else if (action != 'seek') {
      await _call<bool>('key', {'action': action});
    }
  }

  Future<void> toggle() => _do('toggle');
  Future<void> play() => _do('play');
  Future<void> pause() => _do('pause');
  Future<void> next() => _do('next');
  Future<void> previous() => _do('previous');
  Future<void> seek(Duration d) => _do('seek', ms: d.inMilliseconds);

  /// A media key straight to whatever's playing (method 4, for testing).
  Future<void> key(String action) => _call<bool>('key', {'action': action});

  Future<bool> openAccess() async => await _call<bool>('openAccess') ?? false;
  Future<void> link(PhoneBrowser? b) => _call<bool>('browse', {'app': b?.app, 'service': b?.service});
  Future<bool> launch(String app) async => await _call<bool>('launch', {'app': app}) ?? false;

  void choose(String? key) {
    chosen = key;
    notifyListeners();
  }

  /// Bluetooth's own report, in words.
  List<String> get bluetoothLines {
    final b = bluetooth;
    if (b['adapter'] == false) return const ['No Bluetooth on this device'];
    String devices(Object? d) => d is List && d.isNotEmpty ? d.join(', ') : 'none connected';
    return [
      'Audio from a phone: ${b['sinkProfile'] ?? 'unknown'}'
          '${b['sinkProfile'] == 'available' ? ' (${devices(b['sinkDevices'])})' : ''}',
      'Remote control of a phone: ${b['remoteProfile'] ?? 'unknown'}'
          '${b['remoteProfile'] == 'available' ? ' (${devices(b['remoteDevices'])})' : ''}',
    ];
  }
}
