import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'crash_log.dart';
import 'player.dart';

/// Streams a song from a source before downloading it. One at a time; the
/// library player pauses while a preview plays.
class Preview extends ChangeNotifier {
  final Player library;
  Preview(this.library);

  AudioPlayer? _p;
  final _subs = <StreamSubscription<Object?>>[];
  Uri? current;
  bool playing = false;
  bool loading = false;
  Duration position = Duration.zero;
  Duration? duration;

  /// The last preview that couldn't play.
  Uri? failed;

  AudioPlayer get _player {
    final existing = _p;
    if (existing != null) return existing;
    final p = AudioPlayer();
    _subs.addAll([
      p.playerStateStream.listen((s) {
        playing = s.playing && s.processingState != ProcessingState.completed;
        loading =
            s.processingState == ProcessingState.loading || s.processingState == ProcessingState.buffering;
        if (s.processingState == ProcessingState.completed) current = null;
        notifyListeners();
      }, onError: (Object _) {}),
      p.positionStream.listen((d) {
        position = d;
        notifyListeners();
      }),
      p.durationStream.listen((d) {
        duration = d;
        notifyListeners();
      }),
    ]);
    return _p = p;
  }

  bool isPlaying(Uri url) => current == url && (playing || loading);

  /// Plays [url], or stops it if it's the one playing.
  Future<void> toggle(Uri url) async {
    if (current == url) return stop();
    current = url;
    failed = null;
    position = Duration.zero;
    duration = null;
    loading = true;
    notifyListeners();
    if (library.playing) await library.pause();
    try {
      final p = _player;
      await p.setUrl(url.toString());
      if (current == url) await p.play();
    } on Object catch (e, st) {
      if (current != url) return;
      failed = url;
      current = null;
      loading = false;
      CrashLog.record(e, st, where: 'preview $url');
      notifyListeners();
    }
  }

  Future<void> seek(Duration d) async => _p?.seek(d);

  Future<void> stop() async {
    current = null;
    playing = loading = false;
    notifyListeners();
    await _p?.stop();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    unawaited(_p?.dispose());
    super.dispose();
  }
}
