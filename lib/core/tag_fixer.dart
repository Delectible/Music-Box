import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'crash_log.dart';
import 'http.dart';
import 'library.dart';
import 'metadata.dart';
import 'models.dart';
import 'native.dart';

enum FixState {
  /// Waiting its turn.
  queued,

  /// Looking it up.
  looking,

  /// Writing tags and cover into the file.
  writing,

  /// Not sure: the user picks a match (or leaves it).
  review,
  fixed,

  /// Already complete, or left as it was by the user.
  unchanged,

  /// Nothing found.
  noMatch,
  failed,
}

/// One song in Fix tags.
class FixJob {
  final Song song;
  FixState state = FixState.queued;
  final bool onlyIncomplete;

  /// What the file says (blanks guessed from its name and folders).
  TagValues? before;
  List<MbMatch> matches = const [];
  MbMatch? chosen;

  /// How sure the best match is, 0..100.
  int confidence = 0;
  String? note;

  FixJob(this.song, {required this.onlyIncomplete});

  bool get active => state == FixState.queued || state == FixState.looking || state == FixState.writing;
  MbMatch? get best => chosen ?? matches.firstOrNull;
}

/// Fixes tags from MusicBrainz: one song (the user picks the match) or many
/// as a queue of jobs (like downloads): clear matches are written, unsure
/// ones wait for the user, the rest say why. A few run at once; MusicBrainz
/// lookups still take turns (it allows about one a second), but covers and
/// file writes overlap. It keeps going with its screen closed.
class TagFixer extends ChangeNotifier {
  final Library library;
  TagFixer(this.library);

  /// Songs worked on at once.
  static const workers = 3;
  static const sureEnough = 85;

  final jobs = <FixJob>[];
  int _running = 0;
  int _stopGen = 0;
  final _changed = <String>[];
  Timer? _rescan;

  bool get running => jobs.any((j) => j.active);
  int get needsYou => jobs.where((j) => j.state == FixState.review).length;
  int count(FixState s) => jobs.where((j) => j.state == s).length;
  int get finished => jobs.where((j) => !j.active).length;

  /// What's in the file, with blanks guessed from its name and folders.
  static Future<TagValues> currentTags(Song s) async {
    var t = TagValues.ofSong(s);
    try {
      t = TagValues.fromMap(await Native.readTags(s.path)).fill(t);
    } on PlatformException {
      // Unreadable tags: the library's view is all there is.
    }
    return t.fill(guessFromPath(s.path));
  }

  static Future<List<MbMatch>> candidates(Song s, {TagValues? query, bool Function()? cancelled}) async {
    final q = query ?? await currentTags(s);
    return MusicBrainz.search(
      title: q.title,
      artist: q.artist,
      album: q.album,
      length: s.duration,
      cancelled: cancelled,
    );
  }

  /// How sure we are of [m] for a song [length] long, 0..100.
  static int confidence(MbMatch m, Duration length, {MbMatch? runnerUp}) {
    var c = m.score.toDouble();
    if (m.length != null && length > Duration.zero) {
      final off = (m.length! - length).inSeconds.abs();
      if (off > 10) c -= 35;
      if (off > 3 && off <= 10) c -= 8;
    } else {
      c -= 5;
    }
    if (m.live && !m.liveWanted) c -= 40;
    if (m.coverUrl.isEmpty) c -= 10;
    // Two different songs both look right: not sure which.
    if (runnerUp != null &&
        runnerUp.score >= m.score - 3 &&
        runnerUp.title.toLowerCase() != m.title.toLowerCase()) {
      c -= 15;
    }
    return c.round().clamp(0, 100);
  }

  /// A match good enough to use without asking.
  static MbMatch? clearWinner(List<MbMatch> list, Duration length) {
    if (list.isEmpty) return null;
    final m = list.first;
    if (m.score < 90) return null;
    if (m.live && !m.liveWanted) return null;
    if (m.length != null && length > Duration.zero && (m.length! - length).inSeconds.abs() > 10) return null;
    return m;
  }

  /// Writes [m] into the song's file. [keepExisting] only fills blanks.
  static Future<void> apply(String path, TagValues existing, MbMatch m, {bool keepExisting = false}) async {
    var tags = keepExisting ? existing.fill(m.tags) : m.tags.fill(existing);
    if (tags.genre.isEmpty) {
      tags = tags.fill(TagValues(genre: await MusicBrainz.releaseGenre(m.releaseId)));
    }
    final cover = await MusicBrainz.cover(m, await coverCacheDir());
    await applyTags(path, tags, cover: cover);
  }

  /// Makes sure Roadie may change files; false if the user said no.
  static Future<bool> ensureWrite() async => await Native.canWrite() || await Native.requestWrite();

  /// Queues [songs] (those not already queued).
  void addAll(List<Song> songs, {bool onlyIncomplete = true}) {
    // A new batch replaces the finished one.
    if (!running && needsYou == 0) jobs.clear();
    final busy = {
      for (final j in jobs)
        if (j.active || j.state == FixState.review) j.song.path,
    };
    for (final s in songs) {
      if (busy.add(s.path)) jobs.add(FixJob(s, onlyIncomplete: onlyIncomplete));
    }
    notifyListeners();
    _pump();
  }

  void _pump() {
    while (_running < workers) {
      final next = jobs.where((j) => j.state == FixState.queued).firstOrNull;
      if (next == null) break;
      _running++;
      next.state = FixState.looking;
      unawaited(
        _run(next, _stopGen).whenComplete(() {
          _running--;
          notifyListeners();
          _pump();
          if (_running == 0) _flush();
        }),
      );
    }
  }

  Future<void> _run(FixJob j, int gen) async {
    bool stopped() => gen != _stopGen;
    notifyListeners();
    try {
      Map<String, Object?>? raw;
      try {
        raw = await Native.readTags(j.song.path);
      } on PlatformException {
        raw = null;
      }
      final inFile = raw == null ? null : TagValues.fromMap(raw);
      final ofSong = TagValues.ofSong(j.song);
      j.before = (inFile ?? ofSong).fill(ofSong).fill(guessFromPath(j.song.path));
      if (j.onlyIncomplete && inFile != null && !inFile.incomplete && raw!['hasCover'] == true) {
        j.state = FixState.unchanged;
        j.note = 'Already has its tags and cover';
        return;
      }
      final list = await candidates(j.song, query: j.before, cancelled: stopped);
      if (stopped()) throw LookupCancelled();
      j.matches = list;
      if (list.isEmpty) {
        j.state = FixState.noMatch;
        j.note = 'Not found on MusicBrainz';
        return;
      }
      final m = list.first;
      final other = list.skip(1).where((x) => x.recordingId != m.recordingId).firstOrNull;
      j.confidence = confidence(m, j.song.duration, runnerUp: other);
      if (clearWinner(list, j.song.duration) == null || j.confidence < sureEnough) {
        j.state = FixState.review;
        return;
      }
      await _write(j, m);
    } on LookupCancelled {
      j.state = FixState.unchanged;
      j.note = 'Stopped';
    } on Object catch (e, st) {
      j.state = FixState.failed;
      j.note = e is HttpFailure ? friendlyError(e) : '$e';
      CrashLog.record(e, st, where: 'fix tags: ${j.song.path}');
    }
  }

  Future<void> _write(FixJob j, MbMatch m, {bool keepExisting = true}) async {
    j.chosen = m;
    j.state = FixState.writing;
    notifyListeners();
    try {
      await apply(j.song.path, j.before ?? TagValues.ofSong(j.song), m, keepExisting: keepExisting);
      j.state = FixState.fixed;
      j.note = null;
      _changed.add(j.song.path);
      // Show progress in the library now and then, not after every song.
      if (_changed.length >= 25) _flush();
    } on Object catch (e, st) {
      j.state = FixState.failed;
      j.note = 'Couldn\'t write the file: $e';
      CrashLog.record(e, st, where: 'fix tags write: ${j.song.path}');
    }
    notifyListeners();
  }

  /// The user picked [m] for an unsure song: it wins over what the file says.
  Future<void> choose(FixJob j, MbMatch m) async {
    if (j.active) return;
    j.before ??= await currentTags(j.song);
    j.confidence = 100;
    await _write(j, m, keepExisting: false);
    if (_running == 0) _flush();
  }

  void leave(FixJob j) {
    j.state = FixState.unchanged;
    j.note = 'Left as it was';
    notifyListeners();
  }

  void leaveAllUnsure() {
    for (final j in jobs.where((j) => j.state == FixState.review)) {
      j.state = FixState.unchanged;
      j.note = 'Left as it was';
    }
    notifyListeners();
  }

  /// Stops at once: the waiting ones are dropped, lookups in progress end
  /// (a file being written is finished first).
  void cancel() {
    _stopGen++;
    jobs.removeWhere((j) => j.state == FixState.queued);
    notifyListeners();
  }

  void retry(FixJob j) {
    j
      ..state = FixState.queued
      ..note = null
      ..matches = const []
      ..chosen = null;
    notifyListeners();
    _pump();
  }

  void retryFailed() {
    for (final j in jobs.where((j) => j.state == FixState.failed || j.state == FixState.noMatch).toList()) {
      retry(j);
    }
  }

  void clearDone() {
    jobs.removeWhere(
      (j) => j.state == FixState.fixed || j.state == FixState.unchanged || j.state == FixState.noMatch,
    );
    notifyListeners();
  }

  /// Has Android re-read the changed files (shortly, in one go).
  void _flush() {
    if (_changed.isEmpty) return;
    _rescan?.cancel();
    _rescan = Timer(const Duration(seconds: 2), () {
      final paths = [..._changed];
      _changed.clear();
      unawaited(rescan(library, paths));
    });
  }

  @override
  void dispose() {
    _rescan?.cancel();
    _stopGen++;
    super.dispose();
  }
}

/// Has Android re-read [paths], then reloads the library.
Future<void> rescan(Library library, List<String> paths) async {
  await library.source.scan(paths);
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  await library.load(quiet: true);
}
