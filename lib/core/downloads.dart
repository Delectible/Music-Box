import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'crash_log.dart';
import 'http.dart';
import 'library.dart';
import 'metadata.dart';
import 'native.dart';
import 'settings.dart';
import 'sources.dart';
import 'tag_fixer.dart';

enum JobState { queued, downloading, tagging, done, failed, skipped }

class DownloadJob {
  final RemoteTrack track;
  JobState state = JobState.queued;
  double progress = 0; // 0..1, -1 unknown size
  String? error;
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
  Downloads(this.settings, this.library);

  final jobs = <DownloadJob>[];
  int _running = 0;
  final _newFiles = <String>[];
  Timer? _rescan;

  int get activeCount => jobs.where((j) => j.active).length;

  /// The folder downloads go to.
  Future<String> folder() async {
    final f = settings.downloadFolder.trim();
    return f.isNotEmpty ? f : '${await Native.musicDir()}/Roadie';
  }

  void add(List<RemoteTrack> tracks) {
    jobs.addAll(tracks.map(DownloadJob.new));
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
        return;
      }
      var last = DateTime.now();
      await Http.download(
        t.url,
        file,
        cancelled: () => j.cancelled,
        progress: (p) {
          j.progress = p;
          final now = DateTime.now();
          if (now.difference(last).inMilliseconds > 250) {
            last = now;
            notifyListeners();
          }
        },
      );
      j.state = JobState.tagging;
      notifyListeners();
      await _tag(file.path, t);
      j.state = JobState.done;
      _newFiles.add(file.path);
      _rescan?.cancel();
      _rescan = Timer(const Duration(seconds: 2), _addToLibrary);
    } on Object catch (e, st) {
      j.state = JobState.failed;
      j.error = j.cancelled ? 'Cancelled' : '$e';
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
    if (settings.lookUpDownloads && tags.incomplete) {
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
  }
}
