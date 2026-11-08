// The stream controllers live as long as the app (the handler is never torn down).
// ignore_for_file: close_sinks

import 'dart:async';
import 'dart:math';
import 'dart:ui' show Color;

import 'package:audio_service/audio_service.dart' as svc;
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as ja;

import 'models.dart';
import 'player.dart';
import 'source.dart';

/// How one song should sound: level (dB, from volume levelling), speed and
/// silence skipping (podcasts).
class SongSound {
  final double gainDb;
  final double speed;
  final bool skipSilence;
  const SongSound({this.gainDb = 0, this.speed = 1, this.skipSilence = false});
}

/// One just_audio player with its loudness booster (for positive gain).
class _Deck {
  final boost = ja.AndroidLoudnessEnhancer();
  late final ja.AudioPlayer p = ja.AudioPlayer(audioPipeline: ja.AudioPipeline(androidAudioEffects: [boost]));
  double fade = 1; // crossfade share, 0..1
  double level = 1; // volume levelling (cuts), 0..1

  Future<void> applyVolume() => p.setVolume((fade * level).clamp(0, 1));
}

/// Two just_audio players inside an audio_service handler. One plays; the
/// other waits on the same queue so the next song can fade in over the end
/// of this one (crossfade). With crossfade off it's a single gapless player.
/// The handler gives the notification, lock screen and media buttons
/// (steering wheel, Bluetooth).
class AudioEngine extends svc.BaseAudioHandler with svc.QueueHandler, svc.SeekHandler implements Engine {
  final LibrarySource source;
  final _decks = [_Deck(), _Deck()];
  int _on = 0;
  _Deck get _a => _decks[_on];
  _Deck get _b => _decks[1 - _on];
  ja.AudioPlayer get _p => _a.p;

  List<Song> _songs = [];
  bool _restartOnPrevious = true;
  VoidCallback _toggleShuffle = () {};
  VoidCallback _cycleRepeat = () {};

  /// Crossfade length (zero: off) and whether albums play straight through.
  Duration crossfade = Duration.zero;
  bool albumGapless = true;

  /// Level, speed and silence skipping for a song (set by main.dart).
  SongSound Function(Song) soundOf = (_) => const SongSound();

  /// Called for the media notification's favourite button.
  void Function(Song)? onFavourite;
  bool Function(Song) isFavourite = (_) => false;

  final _index = StreamController<int?>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration?>.broadcast();
  final _subs = <StreamSubscription<Object?>>[];
  bool _fading = false;
  Timer? _fadeTimer;

  AudioEngine(this.source) {
    _follow();
  }

  /// Forwards the playing deck's streams (and switches when the decks swap).
  void _follow() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs
      ..clear()
      ..addAll([
        _p.playbackEventStream.listen((_) => _broadcast(), onError: (Object _) {}),
        _p.playingStream.listen((v) {
          _playing.add(v);
          _broadcast();
        }),
        _p.currentIndexStream.listen((i) {
          if (i == null || i >= _songs.length) return;
          _index.add(i);
          _publish(i);
          unawaited(_applySound(_a, i));
        }),
        _p
            .createPositionStream(
              minPeriod: const Duration(milliseconds: 250),
              maxPeriod: const Duration(seconds: 1),
            )
            .listen((pos) {
              _position.add(pos);
              _maybeCrossfade(pos);
            }),
        _p.durationStream.listen(_duration.add),
        // A file that can't be played: skip it rather than stop the drive.
        _p.errorStream.listen((_) {
          if (_p.hasNext) _p.seekToNext();
        }),
      ]);
  }

  static Future<AudioEngine> start(LibrarySource source) => svc.AudioService.init(
    builder: () => AudioEngine(source),
    config: const svc.AudioServiceConfig(
      androidNotificationChannelId: 'com.dingo.roadie.playback',
      androidNotificationChannelName: 'Playback',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
      androidNotificationIcon: 'drawable/ic_stat_roadie',
      notificationColor: Color(0xFFFF6A5C),
      fastForwardInterval: Duration(seconds: 15),
      rewindInterval: Duration(seconds: 15),
    ),
  );

  // Sound per song.

  Future<void> _applySound(_Deck d, int i) async {
    if (i >= _songs.length) return;
    final s = soundOf(_songs[i]);
    // Cuts by volume (exact); boosts with Android's loudness enhancer.
    d.level = s.gainDb < 0 ? pow(10, s.gainDb / 20).toDouble() : 1;
    try {
      await d.boost.setEnabled(s.gainDb > 0.1);
      if (s.gainDb > 0.1) await d.boost.setTargetGain(min(s.gainDb, 12));
    } on Object {
      // Not every device has the effect.
    }
    await d.applyVolume();
    if (d.p.speed != s.speed) await d.p.setSpeed(s.speed);
    try {
      await d.p.setSkipSilenceEnabled(s.skipSilence);
    } on Object {
      // Older Android: no silence skipping.
    }
  }

  /// Re-reads [soundOf] for the playing song (settings changed, gain measured).
  Future<void> refreshSound() async {
    final i = _p.currentIndex;
    if (i != null) await _applySound(_a, i);
  }

  // Crossfade.

  void _maybeCrossfade(Duration pos) {
    if (crossfade == Duration.zero || _fading || !_p.playing) return;
    final total = _p.duration;
    final i = _p.currentIndex;
    final next = _p.nextIndex;
    if (total == null || i == null || next == null || _p.loopMode == ja.LoopMode.one) return;
    if (total < crossfade * 3) return; // very short tracks just play
    if (total - pos > crossfade) return;
    if (albumGapless && _sameAlbumRun(i, next)) return;
    unawaited(_crossfadeTo(next));
  }

  /// Consecutive tracks of one album (live albums, mixes): no fade.
  bool _sameAlbumRun(int i, int next) {
    if (i >= _songs.length || next >= _songs.length) return false;
    final a = _songs[i], b = _songs[next];
    return a.albumId == b.albumId && b.disc == a.disc && b.track == a.track + 1;
  }

  Future<void> _crossfadeTo(int next) async {
    _fading = true;
    final from = _a, to = _b;
    try {
      await to.p.seek(Duration.zero, index: next);
      to.fade = 0;
      await _applySound(to, next);
      unawaited(to.p.play());
      const steps = 30;
      final stepTime = crossfade ~/ steps;
      var n = 0;
      final done = Completer<void>();
      _fadeTimer = Timer.periodic(stepTime, (t) {
        n++;
        final x = n / steps;
        // Equal power: the overall level stays even through the fade.
        from.fade = cos(x * pi / 2);
        to.fade = sin(x * pi / 2);
        from.applyVolume();
        to.applyVolume();
        if (n >= steps) {
          t.cancel();
          if (!done.isCompleted) done.complete();
        }
      });
      // Swap at the start so the app and notification show the new song.
      _on = 1 - _on;
      _follow();
      _index.add(next);
      unawaited(_publish(next));
      await done.future;
      await from.p.pause();
      from.fade = 1;
      await from.applyVolume();
    } on Object catch (e) {
      debugPrint('crossfade failed: $e');
    } finally {
      _fading = false;
      _fadeTimer = null;
    }
  }

  /// Ends a fade at once (user skipped, paused or picked a song).
  Future<void> _settle() async {
    if (!_fading) return;
    _fadeTimer?.cancel();
    _fadeTimer = null;
    _fading = false;
    await _b.p.pause();
    _b.fade = 1;
    await _b.applyVolume();
    _a.fade = 1;
    await _a.applyVolume();
  }

  svc.MediaItem _item(Song s) => svc.MediaItem(
    id: '${s.id}',
    title: s.title,
    artist: s.artist,
    album: s.album,
    genre: s.genre,
    duration: s.duration,
  );

  Future<void> _publish(int i) async {
    if (i >= _songs.length) return;
    final s = _songs[i];
    mediaItem.add(_item(s));
    final art = await source.art(s.albumId, 512);
    if (art != null && _p.currentIndex == i) {
      mediaItem.add(_item(s).copyWith(artUri: Uri.file(art)));
    }
    _broadcast();
  }

  ja.AudioSource _audio(Song s) =>
      s.uri.startsWith('content:') ? ja.AudioSource.uri(Uri.parse(s.uri)) : ja.AudioSource.file(s.uri);

  void _broadcast() {
    final playing = _p.playing;
    final i = _p.currentIndex;
    final song = i != null && i < _songs.length ? _songs[i] : null;
    final fav = song != null && isFavourite(song);
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          svc.MediaControl.skipToPrevious,
          playing ? svc.MediaControl.pause : svc.MediaControl.play,
          svc.MediaControl.skipToNext,
          if (onFavourite != null)
            svc.MediaControl.custom(
              androidIcon: fav ? 'drawable/ic_fav_on' : 'drawable/ic_fav',
              label: fav ? 'Remove from Favourites' : 'Add to Favourites',
              name: 'favourite',
            ),
        ],
        systemActions: const {
          svc.MediaAction.seek,
          svc.MediaAction.seekForward,
          svc.MediaAction.seekBackward,
          svc.MediaAction.setShuffleMode,
          svc.MediaAction.setRepeatMode,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: switch (_p.processingState) {
          ja.ProcessingState.idle => svc.AudioProcessingState.idle,
          ja.ProcessingState.loading => svc.AudioProcessingState.loading,
          ja.ProcessingState.buffering => svc.AudioProcessingState.buffering,
          ja.ProcessingState.ready => svc.AudioProcessingState.ready,
          ja.ProcessingState.completed => svc.AudioProcessingState.completed,
        },
        playing: playing,
        updatePosition: _p.position,
        bufferedPosition: _p.bufferedPosition,
        speed: _p.speed,
        queueIndex: _p.currentIndex,
      ),
    );
  }

  /// Redraws the notification (e.g. the favourite heart changed).
  void refreshNotification() => _broadcast();

  // Engine (the app's player).

  @override
  Future<void> load(List<Song> songs, int index, Duration position) async {
    await _settle();
    _songs = [...songs];
    queue.add([for (final s in songs) _item(s)]);
    for (final d in _decks) {
      try {
        await d.p.setAudioSources(
          [for (final s in songs) _audio(s)],
          initialIndex: index,
          initialPosition: d == _a ? position : Duration.zero,
        );
      } on Object catch (e) {
        debugPrint('load failed: $e');
      }
    }
    if (index < songs.length) {
      unawaited(_publish(index));
      await _applySound(_a, index);
    }
  }

  @override
  Future<void> play() => _p.play();
  @override
  Future<void> pause() async {
    await _settle();
    await _p.pause();
  }

  @override
  Future<void> seek(Duration position, {int? index}) async {
    await _settle();
    await _p.seek(position, index: index);
  }

  @override
  Future<void> next() async {
    await _settle();
    if (_p.hasNext) await _p.seekToNext();
  }

  @override
  Future<void> previous({required bool restart}) async {
    await _settle();
    if (restart && _p.position > const Duration(seconds: 3)) return _p.seek(Duration.zero);
    return _p.hasPrevious ? _p.seekToPrevious() : _p.seek(Duration.zero);
  }

  @override
  Future<void> setRepeat(Repeat mode) async {
    final m = switch (mode) {
      Repeat.off => ja.LoopMode.off,
      Repeat.all => ja.LoopMode.all,
      Repeat.one => ja.LoopMode.one,
    };
    for (final d in _decks) {
      await d.p.setLoopMode(m);
    }
  }

  @override
  Future<void> insert(int index, Song song) async {
    _songs.insert(index, song);
    queue.add([for (final s in _songs) _item(s)]);
    for (final d in _decks) {
      await d.p.insertAudioSource(index, _audio(song));
    }
  }

  @override
  Future<void> removeAt(int index) async {
    _songs.removeAt(index);
    queue.add([for (final s in _songs) _item(s)]);
    for (final d in _decks) {
      await d.p.removeAudioSourceAt(index);
    }
  }

  @override
  Future<void> move(int from, int to) async {
    _songs.insert(to, _songs.removeAt(from));
    queue.add([for (final s in _songs) _item(s)]);
    for (final d in _decks) {
      await d.p.moveAudioSource(from, to);
    }
  }

  @override
  Stream<int?> get indexStream => _index.stream;
  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  Stream<Duration> get positionStream => _position.stream;
  @override
  Stream<Duration?> get durationStream => _duration.stream;

  @override
  set onToggleShuffle(VoidCallback f) => _toggleShuffle = f;
  @override
  set onCycleRepeat(VoidCallback f) => _cycleRepeat = f;

  set restartOnPrevious(bool v) => _restartOnPrevious = v;

  @override
  int? get audioSession => _p.androidAudioSessionId;

  // Media session (notification, lock screen, steering wheel, Bluetooth).

  @override
  Future<void> skipToNext() => next();
  @override
  Future<void> skipToPrevious() => previous(restart: _restartOnPrevious);
  @override
  Future<void> skipToQueueItem(int index) => seek(Duration.zero, index: index);
  @override
  Future<void> setShuffleMode(svc.AudioServiceShuffleMode shuffleMode) async => _toggleShuffle();
  @override
  Future<void> setRepeatMode(svc.AudioServiceRepeatMode repeatMode) async => _cycleRepeat();

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    if (name != 'favourite') return;
    final i = _p.currentIndex;
    if (i != null && i < _songs.length) onFavourite?.call(_songs[i]);
    _broadcast();
  }

  @override
  Future<void> stop() async {
    await pause();
    await super.stop();
  }
}
