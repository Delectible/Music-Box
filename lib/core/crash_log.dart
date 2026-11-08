import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'app_info.dart';
import 'native.dart';

/// Problem reports: every uncaught error (Dart and native) and anything a
/// feature reports with [CrashLog.record], kept in a file on the device and
/// shown in Settings > Problem reports to copy and send.
class CrashLog {
  static File? _file;
  static final _early = <String>[];
  static const _maxBytes = 256 * 1024;

  static Future<void> init() async {
    final dir = await Native.filesDir();
    if (dir == null) return;
    _file = File('$dir/problems.log');
    for (final e in _early) {
      _append(e);
    }
    _early.clear();
  }

  /// Catches errors from Flutter, the platform and async code.
  static void install() {
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      record(details.exception, details.stack, where: details.context?.toDescription() ?? 'flutter');
      previous?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      record(error, stack, where: 'platform');
      return true;
    };
  }

  static void record(Object error, StackTrace? stack, {String where = 'app'}) {
    final text = StringBuffer()
      ..writeln('=== ${DateTime.now().toIso8601String()} · $where · ${AppInfo.name} ${AppInfo.version}')
      ..writeln(error)
      ..writeln(stack?.toString().split('\n').take(25).join('\n') ?? '');
    debugPrint(text.toString());
    if (_file == null) {
      _early.add(text.toString());
    } else {
      _append(text.toString());
    }
  }

  /// A note that isn't an error (e.g. "download failed: 404") for context.
  static void note(String message) => record(message, null, where: 'note');

  static void _append(String s) {
    final f = _file!;
    try {
      if (f.existsSync() && f.lengthSync() > _maxBytes) {
        final keep = f.readAsStringSync();
        f.writeAsStringSync(keep.substring(keep.length - _maxBytes ~/ 2));
      }
      f.writeAsStringSync(s, mode: FileMode.append, flush: true);
    } on Object {
      // Nowhere to report a broken log.
    }
  }

  /// Everything recorded, newest last (native crashes included).
  static Future<String> read() async {
    final native = await Native.nativeCrashes();
    String dart = '';
    try {
      final f = _file;
      if (f != null && f.existsSync()) dart = f.readAsStringSync();
    } on Object {
      dart = '';
    }
    return [if (native.isNotEmpty) '--- Native ---\n$native', if (dart.isNotEmpty) dart].join('\n');
  }

  static Future<void> clear() async {
    await Native.nativeCrashes(clear: true);
    try {
      _file?.writeAsStringSync('');
    } on Object {
      // ignore
    }
  }

  /// Runs [body] with every async error reported.
  static void guard(Future<void> Function() body) =>
      runZonedGuarded(body, (e, s) => record(e, s, where: 'async'));
}
