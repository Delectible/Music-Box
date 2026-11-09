import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'app_info.dart';

class HttpFailure implements Exception {
  final String message;
  final int? status;
  HttpFailure(this.message, [this.status]);
  @override
  String toString() => status == null ? message : '$message (HTTP $status)';
}

/// The link is a web page or some other file, not music.
class NotMusicFile implements Exception {
  final String what;
  NotMusicFile(this.what);
  @override
  String toString() => 'Not a music file ($what)';
}

/// True when [head] (the first bytes) and [type] (Content-Type) look like
/// audio: MP3 (ID3 or frame sync), FLAC, Ogg / Opus, M4A / AAC, WAV, AIFF.
bool looksLikeAudio(List<int> head, String type) {
  final t = type.toLowerCase();
  if (t.startsWith('text/') || t.contains('html') || t.contains('json') || t.contains('xml')) return false;
  if (head.length < 4) return t.startsWith('audio/');
  bool at(int i, String s) =>
      head.length >= i + s.length && String.fromCharCodes(head.sublist(i, i + s.length)) == s;
  if (at(0, 'ID3') || at(0, 'fLaC') || at(0, 'OggS')) return true;
  if (at(4, 'ftyp')) return true; // MP4 / M4A
  if (at(0, 'RIFF') && at(8, 'WAVE')) return true;
  if (at(0, 'FORM') && (at(8, 'AIFF') || at(8, 'AIFC'))) return true;
  if (head[0] == 0xFF && (head[1] & 0xE0) == 0xE0) return true; // MP3 / AAC frame
  // Unknown bytes: trust an audio Content-Type.
  return t.startsWith('audio/');
}

/// What a link points at, from its first bytes.
enum LinkKind { music, page, feed, other }

class LinkInfo {
  final LinkKind kind;
  final String type; // Content-Type
  final String? fileName; // from Content-Disposition
  const LinkInfo(this.kind, this.type, this.fileName);
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
  final s = '$e';
  if (s.contains('RequestLimitExceeded')) {
    return 'YouTube is limiting requests right now. Try again in a few minutes';
  }
  if (s.contains('VideoUnplayable') || s.contains('VideoUnavailable')) {
    return 'This video can\'t be played (private, age-restricted or removed)';
  }
  if (e is NotMusicFile) return 'That link isn\'t a music file (${e.what})';
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

  /// Looks at the start of [uri] without downloading it.
  static Future<LinkInfo> probe(Uri uri) async {
    final res = await _get(uri, headers: {'Range': 'bytes=0-511'});
    final type = res.headers.contentType?.mimeType ?? res.headers.value('content-type') ?? '';
    final cd = res.headers.value('content-disposition') ?? '';
    final name = RegExp(
      r'''filename\*?=(?:UTF-8'')?"?([^";]+)"?''',
      caseSensitive: false,
    ).firstMatch(cd)?.group(1);
    final head = <int>[];
    try {
      await for (final c in res.timeout(const Duration(seconds: 20))) {
        head.addAll(c);
        if (head.length >= 512) break;
      }
    } on Object {
      // Enough to decide with what came.
    }
    final t = type.toLowerCase();
    final start = String.fromCharCodes(head.take(512)).toLowerCase();
    final LinkKind kind;
    if (looksLikeAudio(head.take(64).toList(), type)) {
      kind = LinkKind.music;
    } else if (t.contains('rss') ||
        start.contains('<rss') ||
        (t.contains('xml') && start.contains('<channel'))) {
      kind = LinkKind.feed; // a podcast
    } else if (t.contains('html') || start.contains('<!doctype html') || start.contains('<html')) {
      kind = LinkKind.page;
    } else {
      kind = LinkKind.other;
    }
    return LinkInfo(kind, type, name == null ? null : Uri.decodeComponent(name));
  }

  /// Downloads [total] bytes of [url] into [file] in pieces (Range header,
  /// or YouTube's "range" query parameter), with a time limit on each piece.
  static Future<void> downloadPieces(
    Uri url,
    File file,
    int total, {
    bool rangeInQuery = false,
    void Function(double)? progress,
    bool Function()? cancelled,
  }) async {
    const piece = 9 * 1024 * 1024;
    final sink = file.openWrite();
    var got = 0;
    try {
      while (got < total) {
        if (cancelled?.call() ?? false) throw HttpFailure('Cancelled');
        final to = min(got + piece, total) - 1;
        final u = rangeInQuery
            ? url.replace(queryParameters: {...url.queryParameters, 'range': '$got-$to'})
            : url;
        final res = await _get(u, headers: rangeInQuery ? null : {'Range': 'bytes=$got-$to'});
        var n = 0;
        await for (final c in res.timeout(const Duration(seconds: 30))) {
          if (cancelled?.call() ?? false) throw HttpFailure('Cancelled');
          sink.add(c);
          n += c.length;
          got += c.length;
          progress?.call(got / total);
        }
        if (n == 0) throw HttpFailure('YouTube sent nothing');
      }
    } finally {
      await sink.close();
    }
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
    final type = res.headers.contentType?.mimeType ?? '';
    final sink = part.openWrite(mode: resumed ? FileMode.append : FileMode.write);
    var got = have;
    var checked = resumed; // a resumed file was checked the first time
    final head = <int>[];
    try {
      await for (final c in res.timeout(const Duration(seconds: 45))) {
        if (cancelled?.call() ?? false) throw HttpFailure('Cancelled');
        if (!checked) {
          // Never save a web page or error page as a "song".
          head.addAll(c.take(64 - head.length));
          if (head.length >= 64 || c.isEmpty) {
            if (!looksLikeAudio(head, type)) throw NotMusicFile(type.isEmpty ? 'unknown type' : type);
            checked = true;
          }
        }
        sink.add(c);
        got += c.length;
        progress?.call(total > 0 ? got / total : -1);
      }
      if (!checked && !looksLikeAudio(head, type)) throw NotMusicFile(type.isEmpty ? 'unknown type' : type);
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
