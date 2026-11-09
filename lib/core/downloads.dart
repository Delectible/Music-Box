import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'crash_log.dart';
import 'http.dart';
import 'library.dart';
import 'metadata.dart';
import 'native.dart';
import 'playlists.dart';
import 'settings.dart';
import 'sources.dart';
import 'tag_fixer.dart';

enum JobState { queued, downloading, tagging, done, failed, skipped }

/// Songs downloaded together that become a playlist once all are done.
class _Batch {
  final String playlist;
  final List<DownloadJob> jobs;
  _Batch(this.playlist, this.jobs);
}

class DownloadJob {
  final RemoteTrack track;
  JobState state = JobState.queued;
  double progress = 0; // 0..1, -1 unknown size
  String? error;

  /// Shown while it waits to try again after a dropped connection.
  String? note;
  String? path;
  bool cancelled = false;
  DownloadJob(this.track);

  bool get active => state == JobState.queued || state == JobState.downloading || state == JobState.tagging;
}

/// The download queue: two at a time, saved as Artist/Album/NN Title.ext in
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

  int _shown = -1;

  /// Keeps Android from cutting the network while Roadie is in the
  /// background: a "Downloading" notification while anything is active.
  @override
  void notifyListeners() {
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
    if (playlist != null && playlist.trim().isNotEmpty) _batches.add(_Batch(playlist.trim(), added));
    notifyListeners();
    _pump();
  }

  void cancel(DownloadJob j) {
    j.cancelled = true;
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
    notifyListeners();
    _pump();
  }

  void clearFinished() {
    jobs.removeWhere((j) => !j.active);
    notifyListeners();
  }

  void _pump() {
    while (_running < 2) {
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

  Future<void> _run(DownloadJob j) async {
    final t = j.track;
    try {
      final file = File(pathFor(await folder(), t));
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
          if (j.cancelled || !isNetworkError(e) || attempt >= waits.length) rethrow;
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
      j.state = JobState.tagging;
      notifyListeners();
      await _tag(file.path, t);
      j.state = JobState.done;
      _newFiles.add(file.path);
      _rescan?.cancel();
      _rescan = Timer(const Duration(seconds: 2), _addToLibrary);
    } on Object catch (e, st) {
      j.state = JobState.failed;
      j.note = null;
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
      if (!j.cancelled) CrashLog.record(e, st, where: 'download ${t.url}');
    }
    notifyListeners();
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
      // The file's own tags win over what the site says.
      tags = TagValues.fromMap(await Native.readTags(path)).fill(tags);
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
      if (b.jobs.any((j) => j.active)) continue;
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
