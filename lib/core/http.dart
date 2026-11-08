import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'app_info.dart';

class HttpFailure implements Exception {
  final String message;
  final int? status;
  HttpFailure(this.message, [this.status]);
  @override
  String toString() => status == null ? message : '$message (HTTP $status)';
}

/// Plain dart:io HTTP: JSON, bytes and file downloads with progress.
class Http {
  static final _client = HttpClient()
    ..userAgent = '${AppInfo.name}/${AppInfo.version} ( https://github.com/Delectible/Music-Box )'
    ..connectionTimeout = const Duration(seconds: 20);

  static Future<HttpClientResponse> _get(Uri uri, {Map<String, String>? headers}) async {
    final req = await _client.getUrl(uri).timeout(const Duration(seconds: 25));
    headers?.forEach(req.headers.set);
    final res = await req.close().timeout(const Duration(seconds: 40));
    if (res.statusCode >= 400) {
      await res.drain<void>();
      throw HttpFailure('Request to ${uri.host} failed', res.statusCode);
    }
    return res;
  }

  static Future<Object?> json(Uri uri) async {
    final res = await _get(uri, headers: {'Accept': 'application/json'});
    final text = await res.transform(utf8.decoder).join();
    return jsonDecode(text);
  }

  static Future<List<int>> bytes(Uri uri) async {
    final res = await _get(uri);
    final out = BytesBuilder(copy: false);
    await for (final c in res) {
      out.add(c);
    }
    return out.takeBytes();
  }

  /// Streams [uri] into [file] (via a .part file); [progress] gets 0..1, or
  /// -1 when the size isn't known.
  static Future<void> download(
    Uri uri,
    File file, {
    void Function(double)? progress,
    bool Function()? cancelled,
  }) async {
    final res = await _get(uri);
    final total = res.contentLength;
    final part = File('${file.path}.part');
    await part.parent.create(recursive: true);
    final sink = part.openWrite();
    var got = 0;
    try {
      await for (final c in res.timeout(const Duration(seconds: 60))) {
        if (cancelled?.call() ?? false) throw HttpFailure('Cancelled');
        sink.add(c);
        got += c.length;
        progress?.call(total > 0 ? got / total : -1);
      }
      await sink.close();
      if (await file.exists()) await file.delete();
      await part.rename(file.path);
    } catch (_) {
      await sink.close();
      if (await part.exists()) await part.delete();
      rethrow;
    }
  }
}
