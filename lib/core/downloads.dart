import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'crash_log.dart';
import 'http.dart';
import 'library.dart';
import 'matcher.dart';
import 'metadata.dart';
import 'native.dart';
import 'playlists.dart';
import 'settings.dart';
import 'sources.dart';
import 'tag_fixer.dart';
import 'ytdlp.dart';

/// review: only a close match was found; waiting for Allow / Disallow.
enum JobState { queued, downloading, tagging, done, failed, skipped, review }

/// Songs downloaded together that become a playlist once all are done.
class _Batch {
  final String playlist;
  final List<DownloadJob> jobs;
  _Batch(this.playlist, this.jobs);
}

class DownloadJob {
  final RemoteTrack track;
  late final String id = 'dl${identityHashCode(this)}';
  JobState state = JobState.queued;
  double progress = 0; // 0..1, -1 unknown size
  String? error;

  /// Shown while it waits to try again after a dropped connection.
  String? note;

  /// The SoundCloud upload it was found as (songs from Spotify / YouTube).
  Uri? foundAt;

  /// The close match waiting for a decision ([JobState.review]).
  Found? close;

  /// A close match the person allowed: downloaded as is, no search.
  Uri? forced;

  /// Download speed (bytes a second), while it's downloading.
  double speed = 0;
  String? path;
  bool cancelled = false;
  DownloadJob(this.track);

  bool get active => state == JobState.queued || state == JobState.downloading || state == JobState.tagging;
}

/// How a run of downloads went (everything queued until the queue emptied).
/// Live: a close match allowed or disallowed later moves group.
class DownloadReport {
  final List<DownloadJob> jobs;
  final DateTime at;
  DownloadReport(this.jobs) : at = DateTime.now();
  List<DownloadJob> _in(JobState s) => [
    for (final j in jobs)
      if (j.state == s) j,
  ];
  List<DownloadJob> get saved => _in(JobState.done);
  List<DownloadJob> get already => _in(JobState.skipped);
  List<DownloadJob> get failed => _in(JobState.failed);
  List<DownloadJob> get close => _in(JobState.review);
  int get total => jobs.length;
}

/// The download queue: several at a time (Settings), saved as Artist/Album/NN Title.ext in
/// the chosen folder, tagged (source info, then MusicBrainz for what's
/// missing), cover embedded, then added to the library.
class Downloads extends ChangeNotifier {
  final Settings settings;
  final Library library;
  final Playlists playlists;
  Downloads(this.settings, this.library, this.playlists);

  final _batches = <_Batch>[];

  final jobs = <DownloadJob>[];
  int _running = 0;
  final _newFiles = <String>[];
  Timer? _rescan;

  int get activeCount => jobs.where((j) => j.active).length;

  /// Jobs since the queue was last empty; reported once they're all finished.
  final _round = <DownloadJob>[];

  /// The last finished run, until it's dismissed.
  DownloadReport? report;

  void dismissReport() {
    report = null;
    notifyListeners();
  }

  void _maybeReport() {
    if (_round.isEmpty || _round.any((j) => j.active)) return;
    report = DownloadReport([..._round]);
    _round.clear();
  }

  List<DownloadJob> get toReview => [
    for (final j in jobs)
      if (j.state == JobState.review) j,
  ];

  /// Keep the close match: download it as found.
  void allowClose(DownloadJob j) {
    if (j.state != JobState.review || j.close == null) return;
    j
      ..forced = j.close!.page
      ..state = JobState.queued
      ..error = null
      ..progress = 0;
    if (!_round.contains(j)) _round.add(j);
    notifyListeners();
    _pump();
  }

  void disallowClose(DownloadJob j) {
    if (j.state != JobState.review) return;
    j
      ..state = JobState.failed
      ..error = 'Close match not kept';
    notifyListeners();
    _makePlaylists();
  }

  void allowAllClose() => toReview.forEach(allowClose);
  void disallowAllClose() => toReview.forEach(disallowClose);

  // A slow connection: offer fewer downloads at once (once per app run).
  bool slowHint = false;
  bool _slowOffered = false;
  DateTime? _slowSince;
  int _netRetries = 0;

  void dismissSlowHint() {
    slowHint = false;
    _slowOffered = true;
    notifyListeners();
  }

  /// Several at once but little coming in, or the connection keeps dropping.
  void _checkSpeed() {
    if (_slowOffered || slowHint || settings.downloadThreads <= 2) return;
    final busy = jobs.where((j) => j.state == JobState.downloading && j.speed > 0).toList();
    final total = busy.fold<double>(0, (a, j) => a + j.speed);
    // Under ~150 KB/s between them: a song of a few MB takes minutes each.
    if (busy.length >= 2 && total < 150 * 1024) {
      _slowSince ??= DateTime.now();
      if (DateTime.now().difference(_slowSince!) < const Duration(seconds: 25)) return;
    } else if (_netRetries < 3) {
      _slowSince = null;
      return;
    }
    slowHint = true;
    _slowOffered = true;
  }

  /// Every failed job again (from the report).
  void retryFailed() {
    for (final j in [...jobs.where((j) => j.state == JobState.failed && j.error != 'Close match not kept')]) {
      retry(j);
    }
  }

  int _shown = -1;

  /// Keeps Android from cutting the network while Roadie is in the
  /// background: a "Downloading" notification while anything is active.
  @override
  void notifyListeners() {
    _maybeReport();
    super.notifyListeners();
    final n = activeCount;
    if (n == _shown) return;
    _shown = n;
    final done = jobs.where((j) => j.state == JobState.done).length;
    unawaited(Native.downloading(n, done));
  }

  /// The folder downloads go to.
  Future<String> folder() async {
    final f = settings.downloadFolder.trim();
    return f.isNotEmpty ? f : '${await Native.musicDir()}/Roadie';
  }

  /// Queues [tracks]; with [playlist], they're saved as that playlist (in
  /// this order) once they've all finished.
  void add(List<RemoteTrack> tracks, {String? playlist}) {
    final added = tracks.map(DownloadJob.new).toList();
    jobs.addAll(added);
    _round.addAll(added);
    if (playlist != null && playlist.trim().isNotEmpty) _batches.add(_Batch(playlist.trim(), added));
    notifyListeners();
    _pump();
  }

  void cancel(DownloadJob j) {
    j.cancelled = true;
    if (j.track.viaYtdlp) unawaited(Ytdlp.cancel(j.id));
    if (j.state == JobState.queued) {
      j.state = JobState.failed;
      j.error = 'Cancelled';
    }
    notifyListeners();
  }

  void retry(DownloadJob j) {
    if (j.state != JobState.failed) return;
    j
      ..state = JobState.queued
      ..cancelled = false
      ..error = null
      ..progress = 0;
    if (!_round.contains(j)) _round.add(j);
    notifyListeners();
    _pump();
  }

  void clearFinished() {
    jobs.removeWhere((j) => !j.active);
    notifyListeners();
  }

  void _pump() {
    while (_running < settings.downloadThreads) {
      final next = jobs.where((j) => j.state == JobState.queued).firstOrNull;
      if (next == null) return;
      _running++;
      next.state = JobState.downloading;
      unawaited(
        _run(next).whenComplete(() {
          _running--;
          _pump();
        }),
      );
    }
  }

  static String safe(String s) {
    final t = s.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').replaceAll(RegExp(r'\s+'), ' ').trim();
    final cut = t.length > 100 ? t.substring(0, 100).trim() : t;
    return cut.replaceAll(RegExp(r'^\.+'), '');
  }

  /// Where [t] goes inside [root].
  static String pathFor(String root, RemoteTrack t) {
    final artist = safe(
      t.albumArtist.isNotEmpty ? t.albumArtist : (t.artist.isNotEmpty ? t.artist : 'Unknown artist'),
    );
    final album = safe(t.album.isNotEmpty ? t.album : 'Singles');
    final n = t.track > 0 ? '${t.track.toString().padLeft(2, '0')} ' : '';
    final title = safe(t.title.isNotEmpty ? t.title : 'Track');
    return '$root/$artist/$album/$n$title.${t.ext}';
  }

  static const _audioExts = ['mp3', 'm4a', 'flac', 'wav', 'opus', 'ogg', 'aiff', 'aif', 'aac'];

  Future<void> _run(DownloadJob j) async {
    final t = j.track;
    try {
      var file = File(pathFor(await folder(), t));
      // yt-dlp picks the file type: any type already there counts.
      if (t.viaYtdlp) {
        final base = file.path.substring(0, file.path.lastIndexOf('.'));
        file = _audioExts.map((e) => File('$base.$e')).where((f) => f.existsSync()).firstOrNull ?? file;
      }
      j.path = file.path;
      if (await file.exists()) {
        j.state = JobState.skipped;
        j.error = 'Already downloaded';
        notifyListeners();
        if (_newFiles.isEmpty && !(_rescan?.isActive ?? false)) _makePlaylists();
        return;
      }
      var last = DateTime.now();
      // A dropped connection (phone changing networks, a tunnel) is tried
      // again, continuing the part already saved.
      const waits = [3, 8, 20, 45, 90];
      for (var attempt = 0; ; attempt++) {
        try {
          if (t.viaYtdlp) {
            file = await _ytdlpFetch(j, file, (p, speed) {
              j.progress = p;
              if (speed != null) j.speed = speed;
              _checkSpeed();
              j.note = null;
              final now = DateTime.now();
              if (now.difference(last).inMilliseconds > 250) {
                last = now;
                notifyListeners();
              }
            });
            j.path = file.path;
            break;
          }
          final yt = t.youtubeId;
          final fetch = yt != null
              ? (({required void Function(double) progress}) => YouTube.download(
                  yt,
                  file,
                  cancelled: () => j.cancelled,
                  progress: progress,
                  status: (m) {
                    j.note = m.isEmpty ? null : m;
                    notifyListeners();
                  },
                ))
              : (({required void Function(double) progress}) =>
                    Http.download(t.url, file, cancelled: () => j.cancelled, progress: progress));
          await fetch(
            progress: (p) {
              j.progress = p;
              j.note = null;
              final now = DateTime.now();
              if (now.difference(last).inMilliseconds > 250) {
                last = now;
                notifyListeners();
              }
            },
          );
          break;
        } on Object catch (e) {
          final net = isNetworkError(e) || (e is YtdlpFailure && e.network);
          if (j.cancelled || !net || attempt >= waits.length) rethrow;
          _netRetries++;
          _checkSpeed();
          for (var s = waits[attempt]; s > 0 && !j.cancelled; s--) {
            j.note = '${friendlyError(e)} · trying again in $s s';
            notifyListeners();
            await Future<void>.delayed(const Duration(seconds: 1));
          }
          j.note = 'Reconnecting…';
          notifyListeners();
        }
      }
      j.note = null;
      j.speed = 0;
      j.state = JobState.tagging;
      notifyListeners();
      await _tag(file.path, t);
      j.state = JobState.done;
      _newFiles.add(file.path);
      _rescan?.cancel();
      _rescan = Timer(const Duration(seconds: 2), _addToLibrary);
    } on CloseMatch catch (e) {
      // Not downloaded: waits for Allow / Disallow.
      j
        ..state = JobState.review
        ..close = e.found
        ..note = null
        ..speed = 0
        ..error = 'Close match found';
    } on Object catch (e, st) {
      j.state = JobState.failed;
      j.note = null;
      j.speed = 0;
      if (e is NotMusicFile) {
        // Nothing worth keeping.
        final p = j.path;
        if (p != null) {
          for (final f in [File(p), File('$p.part')]) {
            if (f.existsSync()) f.deleteSync();
          }
        }
      }
      // A batch whose last song failed still becomes a playlist of the rest.
      if (_newFiles.isEmpty && !(_rescan?.isActive ?? false)) scheduleMicrotask(_makePlaylists);
      j.error = j.cancelled ? 'Cancelled' : friendlyError(e);
      if (!j.cancelled && e is! NoMatch) {
        CrashLog.record(e is YtdlpFailure ? '${e.message}\n${e.detail}' : e, st, where: 'download ${t.url}');
      }
    }
    notifyListeners();
  }

  /// yt-dlp download (SoundCloud): the artist's file or the best full stream,
  /// named like the rest; returns the file it saved.
  Future<File> _ytdlpFetch(DownloadJob j, File planned, void Function(double, double?) progress) async {
    await Directory(planned.parent.path).create(recursive: true);
    if (!j.track.findOnSoundCloud) {
      try {
        return await _ytdlpGet(j, j.track.url, planned, progress);
      } on YtdlpFailure catch (e) {
        // A Go+ preview or DRM upload: look for another upload of the song.
        if (!e.unavailable || j.cancelled) rethrow;
        j.note = 'Can\'t save this upload: looking for another one…';
        notifyListeners();
        try {
          return await _fromMatches(j, await SongMatcher.pages(j.track, not: j.track.url), planned, progress);
        } on NoMatch {
          throw e; // nothing else: the clear reason why
        }
      }
    }
    final forced = j.forced;
    if (forced != null) {
      j.foundAt = forced;
      return _ytdlpGet(j, forced, planned, progress);
    }
    // Songs from Spotify / YouTube: the best SoundCloud matches, in turn,
    // until one gives the whole song (not a Go+ preview).
    j.note = 'Finding it on SoundCloud…';
    notifyListeners();
    return _fromMatches(j, await SongMatcher.pages(j.track), planned, progress);
  }

  /// The matches in turn until one gives the whole song.
  Future<File> _fromMatches(
    DownloadJob j,
    List<Found> found,
    File planned,
    void Function(double, double?) progress,
  ) async {
    Object? last;
    for (final f in found) {
      if (j.cancelled) break;
      try {
        j.foundAt = f.page;
        return await _ytdlpGet(j, f.page, planned, progress);
      } on YtdlpFailure catch (e) {
        if (e.message == 'Cancelled' || e.network) rethrow;
        last = e;
      } on NotMusicFile catch (e) {
        last = e;
      }
    }
    if (last is YtdlpFailure && last.message.contains('preview')) {
      throw NoMatch('On SoundCloud only as a 30-second preview (Go+)');
    }
    throw last ?? NoMatch('Not found on SoundCloud');
  }

  Future<File> _ytdlpGet(
    DownloadJob j,
    Uri page,
    File planned,
    void Function(double, double?) progress,
  ) async {
    final base = planned.path.substring(0, planned.path.lastIndexOf('.'));
    j.note = 'Starting…';
    notifyListeners();
    final r = await Ytdlp.download(
      page.toString(),
      [
        // Streams come in pieces: fetch 4 at once.
        '--concurrent-fragments',
        '4',
        '-f',
        SoundCloud(original: settings.losslessFor('soundcloud')).format,
        '-o',
        '$base.%(ext)s',
        '--no-playlist',
        '--no-mtime',
        '--no-simulate',
        '--print',
        'after_move:filepath',
      ],
      id: j.id,
      progress: progress,
    );
    if (j.cancelled) throw HttpFailure('Cancelled');
    final path = r.out.split('\n').map((l) => l.trim()).lastWhere((l) => l.startsWith('/'), orElse: () => '');
    final file = File(path.isEmpty ? '$base.mp3' : path);
    if (!file.existsSync()) throw YtdlpFailure('The download didn\'t produce a file', r.err);
    final head = await file.openRead(0, 64).fold<List<int>>([], (a, b) => a..addAll(b));
    if (!looksLikeAudio(head, '')) {
      file.deleteSync();
      throw NotMusicFile('not audio');
    }
    return file;
  }

  Future<void> _tag(String path, RemoteTrack t) async {
    var tags = TagValues(
      title: t.title,
      artist: t.artist,
      album: t.album,
      albumArtist: t.albumArtist,
      genre: t.genre,
      year: t.year,
      track: t.track > 0 ? '${t.track}' : '',
    ).fill(guessFromPath(path));
    String? cover;
    try {
      final own = TagValues.fromMap(await Native.readTags(path));
      // The file's own tags win over what the site says, except for songs
      // found on SoundCloud: the Spotify / YouTube details are the right ones.
      tags = t.findOnSoundCloud ? tags.fill(own) : own.fill(tags);
    } on Object {
      // Not readable yet: write ours.
    }
    if (settings.lookUpDownloads && t.lookUp && tags.incomplete) {
      try {
        final m = TagFixer.clearWinner(
          await MusicBrainz.search(
            title: tags.title,
            artist: tags.artist,
            album: tags.album,
            length: t.length,
          ),
          t.length ?? Duration.zero,
        );
        if (m != null) {
          tags = tags.fill(m.tags);
          if (tags.genre.isEmpty) {
            tags = tags.fill(TagValues(genre: await MusicBrainz.releaseGenre(m.releaseId)));
          }
          cover = await MusicBrainz.cover(m.releaseId, await coverCacheDir());
        }
      } on Object catch (e) {
        CrashLog.note('MusicBrainz lookup for download failed: $e');
      }
    }
    if (cover == null && t.cover != null) {
      try {
        final dir = await coverCacheDir();
        final f = File('$dir/dl_${t.cover.hashCode}.jpg');
        if (!f.existsSync()) {
          await f.parent.create(recursive: true);
          await f.writeAsBytes(await Http.bytes(Uri.parse(t.cover!)));
        }
        cover = f.path;
      } on Object {
        cover = null;
      }
    }
    try {
      await applyTags(path, tags, cover: cover);
    } on Object catch (e, st) {
      // The song is still saved; it just keeps the tags it came with.
      CrashLog.record(e, st, where: 'tagging $path');
    }
  }

  Future<void> _addToLibrary() async {
    if (_newFiles.isEmpty) return;
    final files = [..._newFiles];
    _newFiles.clear();
    await rescan(library, files);
    _makePlaylists();
  }

  /// Batches whose songs have all finished become playlists, in their order.
  void _makePlaylists() {
    for (final b in [..._batches]) {
      // Close matches still to decide on keep the playlist waiting.
      if (b.jobs.any((j) => j.active || j.state == JobState.review)) continue;
      final byPath = {for (final s in library.unfiltered) s.path: s};
      final songs = [
        for (final j in b.jobs)
          if (j.path != null && (j.state == JobState.done || j.state == JobState.skipped)) ?byPath[j.path],
      ];
      // Not in the library yet (scan still going): try again after the next rescan.
      final expected = b.jobs.where((j) => j.state == JobState.done || j.state == JobState.skipped).length;
      if (songs.length < expected && (_rescan?.isActive ?? false)) continue;
      _batches.remove(b);
      if (songs.isEmpty) continue;
      final existing = playlists.all.where((p) => p.name == b.playlist).firstOrNull;
      playlists.add(existing ?? playlists.create(b.playlist), songs);
    }
  }
}
