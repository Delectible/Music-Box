import 'package:flutter/services.dart';

/// Device features from MainActivity.kt (channel `roadie/library`). Every
/// call is safe to make in tests and on failure: it returns a fallback.
class Native {
  static const _ch = MethodChannel('roadie/library');

  static Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _ch.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    }
  }

  static Future<String?> filesDir() => _call<String>('filesDir');

  /// Android's picker for an image, copied to [dest]; null when cancelled.
  static Future<String?> pickImage(String dest) => _call<String>('pickImage', {'dest': dest});

  /// Android version, memory (MB), CPU types, WebView version; empty in tests.
  static Future<Map<String, Object?>> device() async =>
      (await _call<Map<Object?, Object?>>('device'))?.cast<String, Object?>() ?? const {};

  /// The device's Music folder (/storage/emulated/0/Music on most phones).
  static Future<String> musicDir() async => await _call<String>('musicDir') ?? '/storage/emulated/0/Music';

  /// Internal storage, then any SD card or USB stick.
  static Future<List<String>> roots() async =>
      (await _call<List<Object?>>('roots'))?.cast<String>() ?? const ['/storage/emulated/0'];

  static Future<List<String>> listDirs(String path) async {
    try {
      return (await _call<List<Object?>>('listDirs', {'path': path}))?.cast<String>() ?? const [];
    } on PlatformException {
      return const [];
    }
  }

  /// Saving files anywhere in storage (All files access on Android 11+).
  static Future<bool> canWrite() async => await _call<bool>('canWrite') ?? false;
  static Future<bool> requestWrite() async => await _call<bool>('requestWrite') ?? false;

  /// The visualiser reads the playing sound (Android files it under the microphone).
  static Future<bool> canRecord() async => await _call<bool>('canRecord') ?? false;
  static Future<bool> requestRecord() async => await _call<bool>('requestRecord') ?? false;

  /// Throws [PlatformException] when the file can't be read.
  static Future<Map<String, Object?>> readTags(String path) async {
    final m = await _ch.invokeMapMethod<String, Object?>('readTags', {'path': path});
    return m ?? const {};
  }

  /// Throws [PlatformException] when the file can't be written.
  static Future<void> writeTags(String path, Map<String, String> values, {String? cover}) =>
      _ch.invokeMethod('writeTags', {'path': path, 'values': values, 'cover': cover});

  /// File, storage, media index row and tags for the song info screen.
  static Future<Map<String, Object?>> fileInfo(String path, int id) async {
    try {
      return await _ch.invokeMapMethod<String, Object?>('fileInfo', {'path': path, 'id': id}) ?? const {};
    } on MissingPluginException {
      return const {};
    }
  }

  /// Shows / updates / removes the downloads notification (a foreground
  /// service, so downloads keep going with the screen off or in another app).
  static Future<void> downloading(int active, int done) async {
    try {
      await _call<void>('downloading', {'active': active, 'done': done});
    } on PlatformException {
      // No notification: downloads still run while Roadie is open.
    }
  }

  /// 0: bars shown, 1: navigation buttons hidden, 2: all bars hidden.
  static Future<void> immersive(int mode) async {
    try {
      await _call<void>('immersive', {'mode': mode});
    } on PlatformException {
      // Not fatal: the bars just stay.
    }
  }

  static Future<String> nativeCrashes({bool clear = false}) async =>
      await _call<String>('nativeCrashes', {'clear': clear}) ?? '';
}
