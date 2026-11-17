import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'app_info.dart';
import 'crash_log.dart';
import 'http.dart';

/// One build on the repo's Releases page (tag `build-<n>`).
class Release {
  final int build;
  final String version; // "0.4.4", from the notes' first line; may be ''
  final String notes, page, apkUrl;
  final int size;
  final String sha256; // from GitHub, when it gives one
  final DateTime? date;

  const Release({
    required this.build,
    required this.version,
    required this.notes,
    required this.page,
    required this.apkUrl,
    required this.size,
    required this.sha256,
    required this.date,
  });

  String get label => version.isEmpty ? 'Build $build' : '$version · build $build';

  /// A release from GitHub's API, or null if it isn't an app build.
  static Release? fromJson(Map<Object?, Object?> j) {
    if (j['draft'] == true || j['prerelease'] == true) return null;
    final build = int.tryParse(RegExp(r'^build-(\d+)$').firstMatch('${j['tag_name']}')?.group(1) ?? '');
    if (build == null) return null;
    final apk = (j['assets'] as List? ?? const []).cast<Map<Object?, Object?>>().where(
      (a) => '${a['name']}'.toLowerCase().endsWith('.apk'),
    );
    if (apk.isEmpty) return null;
    final a = apk.first;
    final notes = '${j['body'] ?? ''}'.trim();
    final first = notes.split('\n').first;
    final digest = '${a['digest'] ?? ''}';
    return Release(
      build: build,
      version: RegExp(r'\((\d+\.\d+\.\d+)\)\s*$').firstMatch(first)?.group(1) ?? '',
      notes: notes,
      page: '${j['html_url'] ?? ''}',
      apkUrl: '${a['browser_download_url']}',
      size: (a['size'] as num?)?.toInt() ?? 0,
      sha256: digest.startsWith('sha256:') ? digest.substring(7).toLowerCase() : '',
      date: DateTime.tryParse('${j['published_at'] ?? ''}'),
    );
  }
}

enum UpdateStage { idle, checking, upToDate, available, downloading, verifying, ready, installing, failed }

/// Updates for the APK from GitHub Releases (not the Play Store version:
/// Play updates that). Checks once at start when online; downloads the APK
/// into the cache (one file at a time, removed once installed), checks it
/// is Roadie, the right build, the same signing key and the published
/// checksum, then hands it to Android's installer.
class Updater extends ChangeNotifier with WidgetsBindingObserver {
  Updater._();
  static final instance = Updater._();

  static const _ch = MethodChannel('roadie/update');
  static const repo = 'Delectible/Music-Box';

  /// A sideloaded APK that may install updates.
  bool supported = false;
  bool canInstall = false;
  bool fromStore = false;
  int current = 0;
  String _dir = '';
  int _free = -1;

  UpdateStage stage = UpdateStage.idle;
  Release? latest;
  List<Release> newer = const []; // newest first
  double progress = 0; // 0..1
  int received = 0;
  double speed = 0; // bytes a second
  String? error;
  String? apkPath;
  bool _cancel = false;
  bool _waitingForPermission = false;
  bool _started = false;

  /// Something for the top bar to show.
  bool get hasUpdate => latest != null && stage != UpdateStage.upToDate && stage != UpdateStage.checking;

  Future<void> _info() async {
    try {
      final m = (await _ch.invokeMapMethod<String, Object?>('info')) ?? const {};
      supported = m['canUpdate'] == true;
      canInstall = m['canInstall'] == true;
      fromStore = m['fromStore'] == true;
      current = (m['versionCode'] as num?)?.toInt() ?? 0;
      _dir = '${m['dir'] ?? ''}';
      _free = (m['freeBytes'] as num?)?.toInt() ?? -1;
    } on MissingPluginException {
      supported = false; // tests, or a build without the updater
    } on PlatformException catch (e) {
      supported = false;
      CrashLog.note('update info failed: $e');
    }
  }

  /// At app start: tidy old downloads, then look for a new build (quietly).
  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _info();
    if (!supported) return;
    WidgetsBinding.instance.addObserver(this);
    await _tidy();
    // Let the library load first; a head unit's network may also take a moment.
    await Future<void>.delayed(const Duration(seconds: 6));
    await check(quiet: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(_resumed());
  }

  /// Back from Android's settings or installer.
  Future<void> _resumed() async {
    await _info();
    if (_waitingForPermission) {
      _waitingForPermission = false;
      if (canInstall && stage == UpdateStage.ready) {
        await install();
        return;
      }
    }
    // The installer was closed without updating.
    if (stage == UpdateStage.installing) {
      stage = UpdateStage.ready;
      notifyListeners();
    }
    notifyListeners();
  }

  /// Removes downloads that aren't the build waiting to be installed.
  Future<void> _tidy({int? keep}) async {
    if (_dir.isEmpty) return;
    try {
      final dir = Directory(_dir);
      if (!dir.existsSync()) return;
      for (final f in dir.listSync()) {
        final n = int.tryParse(RegExp(r'Roadie-(\d+)\.apk').firstMatch(f.path)?.group(1) ?? '');
        final wanted = n != null && n > current && (keep == null || n == keep);
        if (!wanted) await f.delete(recursive: true);
      }
    } on Object catch (e) {
      CrashLog.note('update tidy failed: $e');
    }
  }

  File _file(Release r) => File('$_dir/Roadie-${r.build}.apk');

  Future<void> check({bool quiet = false}) async {
    if (!supported) await _info();
    if (!supported) return;
    if (stage == UpdateStage.downloading ||
        stage == UpdateStage.verifying ||
        stage == UpdateStage.installing) {
      return;
    }
    stage = UpdateStage.checking;
    error = null;
    notifyListeners();
    try {
      final list = await Http.json(Uri.parse('https://api.github.com/repos/$repo/releases?per_page=20'));
      final releases = [
        for (final j in (list as List? ?? const []).cast<Map<Object?, Object?>>()) ?Release.fromJson(j),
      ]..sort((a, b) => b.build.compareTo(a.build));
      newer = releases.where((r) => r.build > current).toList();
      latest = newer.firstOrNull;
      final l = latest;
      if (l == null) {
        stage = UpdateStage.upToDate;
        await _tidy();
      } else {
        await _tidy(keep: l.build);
        // Already downloaded and checked earlier.
        final f = _file(l);
        if (f.existsSync() && f.lengthSync() == l.size) {
          apkPath = f.path;
          stage = UpdateStage.ready;
        } else {
          stage = UpdateStage.available;
        }
      }
    } on Object catch (e) {
      // No network at start is normal in a car: stay quiet.
      stage = latest == null ? UpdateStage.idle : UpdateStage.available;
      if (!quiet) {
        stage = UpdateStage.failed;
        error = 'Couldn\'t check for updates. ${friendlyError(e)}';
      }
    }
    notifyListeners();
  }

  void cancel() => _cancel = true;

  Future<void> download() async {
    final r = latest;
    if (r == null || stage == UpdateStage.downloading) return;
    await _info();
    if (_free >= 0 && _free < r.size + 30 * 1024 * 1024) {
      _fail('Not enough free space: the update needs ${_mb(r.size + 30 * 1024 * 1024)} free.');
      return;
    }
    _cancel = false;
    stage = UpdateStage.downloading;
    error = null;
    progress = 0;
    speed = 0;
    notifyListeners();
    final file = _file(r);
    final part = File('${file.path}.part');
    final client = HttpClient()
      ..userAgent = '${AppInfo.name}/${AppInfo.version}'
      ..connectionTimeout = const Duration(seconds: 30);
    try {
      await _tidy(keep: r.build);
      await part.parent.create(recursive: true);
      // A dropped connection is picked up where it stopped, a few times.
      const waits = [2, 5, 10, 20];
      for (var attempt = 0; ; attempt++) {
        try {
          await _fetch(client, r, part);
          break;
        } on Object catch (e) {
          if (_cancel || !isNetworkError(e) || attempt >= waits.length) rethrow;
          error = 'Connection dropped, trying again…';
          notifyListeners();
          await Future<void>.delayed(Duration(seconds: waits[attempt]));
          error = null;
        }
      }
      final got = await part.length();
      if (r.size > 0 && got != r.size) {
        await part.delete();
        throw HttpFailure('The download was incomplete (${_mb(got)} of ${_mb(r.size)})');
      }
      if (file.existsSync()) await file.delete();
      await part.rename(file.path);
      stage = UpdateStage.verifying;
      notifyListeners();
      await _verify(r, file);
      apkPath = file.path;
      stage = UpdateStage.ready;
      notifyListeners();
      await install();
    } on Object catch (e) {
      if (_cancel) {
        stage = UpdateStage.available;
        error = null;
        if (part.existsSync()) await part.delete();
        notifyListeners();
      } else {
        // Keep a part-download after a network problem, to continue from.
        if (!isNetworkError(e) && part.existsSync()) await part.delete();
        _fail(e is _Bad ? e.message : 'Download failed. ${friendlyError(e)}');
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _fetch(HttpClient client, Release r, File part) async {
    var have = part.existsSync() ? await part.length() : 0;
    if (r.size > 0 && have >= r.size) have = 0;
    final req = await client.getUrl(Uri.parse(r.apkUrl)).timeout(const Duration(seconds: 45));
    if (have > 0) req.headers.set('Range', 'bytes=$have-');
    final res = await req.close().timeout(const Duration(seconds: 60));
    if (res.statusCode >= 400) {
      await res.drain<void>();
      throw HttpFailure('Download refused by ${Uri.parse(r.apkUrl).host}', res.statusCode);
    }
    final resumed = have > 0 && res.statusCode == 206;
    if (!resumed) have = 0;
    final total = r.size > 0 ? r.size : (res.contentLength > 0 ? res.contentLength + have : -1);
    final sink = part.openWrite(mode: resumed ? FileMode.append : FileMode.write);
    received = have;
    var mark = DateTime.now();
    var markBytes = received;
    var shown = DateTime.now();
    try {
      await for (final c in res.timeout(const Duration(seconds: 60))) {
        if (_cancel) throw _Bad('Cancelled');
        sink.add(c);
        received += c.length;
        final now = DateTime.now();
        final dt = now.difference(mark).inMilliseconds;
        if (dt >= 500) {
          final s = (received - markBytes) * 1000 / dt;
          speed = speed == 0 ? s : speed * 0.6 + s * 0.4;
          mark = now;
          markBytes = received;
        }
        if (now.difference(shown).inMilliseconds >= 100) {
          shown = now;
          progress = total > 0 ? (received / total).clamp(0.0, 1.0) : 0;
          notifyListeners();
        }
      }
    } finally {
      await sink.close();
    }
    progress = 1;
    notifyListeners();
  }

  Future<void> _verify(Release r, File f) async {
    Map<String, Object?> m;
    try {
      m = (await _ch.invokeMapMethod<String, Object?>('check', {'path': f.path})) ?? const {};
    } on PlatformException catch (e) {
      await f.delete();
      throw _Bad('Couldn\'t check the download: ${e.message}');
    }
    Future<Never> bad(String why) async {
      if (f.existsSync()) await f.delete();
      throw _Bad(why);
    }

    if (m['valid'] != true) await bad('The download isn\'t a working app file. Try again.');
    if (m['package'] != 'com.dingo.roadie') await bad('The download isn\'t Roadie.');
    if (r.sha256.isNotEmpty && m['sha256'] != r.sha256) {
      await bad('The download was damaged on the way (checksum differs). Try again.');
    }
    final code = (m['versionCode'] as num?)?.toInt() ?? 0;
    if (code <= current) await bad('The download is the same or an older build than this one.');
    if (m['sameSigner'] == false) {
      await bad(
        'This build is signed with a different key from the installed app, so Android would refuse it. '
        'Uninstall Roadie and install the new APK from the release page instead (your settings will reset).',
      );
    }
  }

  Future<void> install() async {
    final path = apkPath;
    if (path == null || !File(path).existsSync()) {
      stage = latest == null ? UpdateStage.idle : UpdateStage.available;
      apkPath = null;
      notifyListeners();
      return;
    }
    await _info();
    if (!canInstall) {
      // Android asks once: "Allow from this source".
      _waitingForPermission = true;
      stage = UpdateStage.ready;
      error = 'Allow Roadie to install updates, then come back.';
      notifyListeners();
      try {
        await _ch.invokeMethod<bool>('allowInstalls');
      } on PlatformException catch (e) {
        _waitingForPermission = false;
        _fail('Couldn\'t open the setting: ${e.message}');
      }
      return;
    }
    error = null;
    stage = UpdateStage.installing;
    notifyListeners();
    try {
      await _ch.invokeMethod<bool>('install', {'path': path});
    } on PlatformException catch (e) {
      stage = UpdateStage.ready;
      error = e.message ?? 'The installer didn\'t open.';
      notifyListeners();
    }
  }

  /// The release page in the browser (the fallback for anything odd).
  Future<void> openPage() async {
    final url = latest?.page.isNotEmpty == true ? latest!.page : 'https://github.com/$repo/releases';
    try {
      await _ch.invokeMethod<bool>('openUrl', {'url': url});
    } on Object {
      // Nothing more to try.
    }
  }

  void _fail(String why) {
    stage = UpdateStage.failed;
    error = why;
    notifyListeners();
  }

  static String _mb(int b) => '${(b / 1048576).toStringAsFixed(1)} MB';

  @visibleForTesting
  void debugSet({
    required UpdateStage stage,
    Release? latest,
    List<Release> newer = const [],
    double progress = 0,
  }) {
    this.stage = stage;
    this.latest = latest;
    this.newer = newer;
    this.progress = progress;
    notifyListeners();
  }
}

class _Bad implements Exception {
  final String message;
  _Bad(this.message);
  @override
  String toString() => message;
}
