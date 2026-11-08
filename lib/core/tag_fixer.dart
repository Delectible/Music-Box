import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'crash_log.dart';
import 'library.dart';
import 'metadata.dart';
import 'models.dart';
import 'native.dart';

/// Fixes tags from MusicBrainz: one song (the user picks the match) or many
/// (the best match is used when it's a clear one).
class TagFixer extends ChangeNotifier {
  final Library library;
  TagFixer(this.library);

  bool running = false;
  bool _cancel = false;
  int done = 0, total = 0, fixed = 0, skipped = 0, failed = 0;
  String current = '';

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

  static Future<List<MbMatch>> candidates(Song s, {TagValues? query}) async {
    final q = query ?? await currentTags(s);
    return MusicBrainz.search(title: q.title, artist: q.artist, album: q.album, length: s.duration);
  }

  /// A match good enough to use without asking.
  static MbMatch? clearWinner(List<MbMatch> list, Duration length) {
    if (list.isEmpty) return null;
    final m = list.first;
    if (m.score < 90) return null;
    if (m.length != null && length > Duration.zero && (m.length! - length).inSeconds.abs() > 10) return null;
    return m;
  }

  /// Writes [m] into the song's file. [keepExisting] only fills blanks.
  static Future<void> apply(String path, TagValues existing, MbMatch m, {bool keepExisting = false}) async {
    var tags = keepExisting ? existing.fill(m.tags) : m.tags.fill(existing);
    if (tags.genre.isEmpty) {
      tags = tags.fill(TagValues(genre: await MusicBrainz.releaseGenre(m.releaseId)));
    }
    final cover = await MusicBrainz.cover(m.releaseId, await coverCacheDir());
    await applyTags(path, tags, cover: cover);
  }

  /// Makes sure Roadie may change files; false if the user said no.
  static Future<bool> ensureWrite() async => await Native.canWrite() || await Native.requestWrite();

  Future<void> fixAll(List<Song> songs, {bool onlyIncomplete = true}) async {
    if (running) return;
    running = true;
    _cancel = false;
    done = fixed = skipped = failed = 0;
    total = songs.length;
    notifyListeners();
    final changed = <String>[];
    for (final s in songs) {
      if (_cancel) break;
      current = '${s.artist} – ${s.title}';
      notifyListeners();
      try {
        final now = await currentTags(s);
        TagValues? inFile;
        try {
          inFile = TagValues.fromMap(await Native.readTags(s.path));
        } on PlatformException {
          inFile = null;
        }
        final complete = inFile != null && !inFile.incomplete && (await _hasCover(s.path));
        if (onlyIncomplete && complete) {
          skipped++;
        } else {
          final m = clearWinner(await candidates(s, query: now), s.duration);
          if (m == null) {
            skipped++;
          } else {
            await apply(s.path, inFile ?? now, m, keepExisting: true);
            changed.add(s.path);
            fixed++;
          }
        }
      } on Object catch (e, st) {
        failed++;
        CrashLog.record(e, st, where: 'fix tags: ${s.path}');
      }
      done++;
      notifyListeners();
    }
    current = '';
    running = false;
    notifyListeners();
    if (changed.isNotEmpty) await rescan(library, changed);
  }

  static Future<bool> _hasCover(String path) async {
    try {
      return (await Native.readTags(path))['hasCover'] == true;
    } on PlatformException {
      return false;
    }
  }

  void cancel() => _cancel = true;
}

/// Has Android re-read [paths], then reloads the library.
Future<void> rescan(Library library, List<String> paths) async {
  await library.source.scan(paths);
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  await library.load(quiet: true);
}
