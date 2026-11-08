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

/// A short, plain description of a network error.
String friendlyError(Object e) {
  if (e is HttpFailure) return e.toString();
  if (e is SocketException) {
    return e.message.contains('host lookup') || e.osError?.errorCode == 7
        ? 'No internet connection'
        : 'Connection problem';
  }
  if (e is HttpException) return 'The connection dropped';
  if (e is TimeoutException) return 'Timed out';
  if (e is HandshakeException || e is TlsException) return 'Secure connection failed';
  if (e is FileSystemException) return 'Couldn\'t save the file (${e.osError?.message ?? e.message})';
  return '$e';
}

/// Worth trying again: the network, not the request, was the problem.
bool isNetworkError(Object e) =>
    e is SocketException ||
    e is HttpException ||
    e is TimeoutException ||
    e is TlsException ||
    (e is HttpFailure && e.status != null && (e.status! >= 500 || e.status == 429));

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
  /// -1 when the size isn't known. A .part left by a dropped connection is
  /// continued where it stopped (when the server allows), not restarted.
  static Future<void> download(
    Uri uri,
    File file, {
    void Function(double)? progress,
    bool Function()? cancelled,
  }) async {
    final part = File('${file.path}.part');
    await part.parent.create(recursive: true);
    var have = await part.exists() ? await part.length() : 0;
    HttpClientResponse res;
    try {
      res = await _get(uri, headers: have > 0 ? {'Range': 'bytes=$have-'} : null);
    } on HttpFailure catch (e) {
      if (e.status != 416) rethrow;
      // The leftover piece doesn't fit this file any more: start over.
      await part.delete();
      have = 0;
      res = await _get(uri);
    }
    final resumed = have > 0 && res.statusCode == 206;
    if (!resumed) have = 0;
    final total = res.contentLength > 0 ? res.contentLength + have : -1;
    final sink = part.openWrite(mode: resumed ? FileMode.append : FileMode.write);
    var got = have;
    try {
      await for (final c in res.timeout(const Duration(seconds: 45))) {
        if (cancelled?.call() ?? false) throw HttpFailure('Cancelled');
        sink.add(c);
        got += c.length;
        progress?.call(total > 0 ? got / total : -1);
      }
      await sink.close();
      if (await file.exists()) await file.delete();
      await part.rename(file.path);
    } catch (e) {
      await sink.close();
      // Keep what we have after a dropped connection, to continue from.
      if (!isNetworkError(e) && await part.exists()) await part.delete();
      rethrow;
    }
  }
}
