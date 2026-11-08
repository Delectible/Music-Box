import 'dart:async';

import 'package:audio_service/audio_service.dart' as svc;
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as ja;

import 'models.dart';
import 'player.dart';
import 'source.dart';

/// just_audio for sound (a gapless queue) inside an audio_service handler,
/// which gives the notification, lock screen and media buttons (steering
/// wheel, Bluetooth). Media buttons act on the same player the app shows.
class AudioEngine extends svc.BaseAudioHandler with svc.QueueHandler, svc.SeekHandler implements Engine {
  final LibrarySource source;
  final _p = ja.AudioPlayer();
  List<Song> _songs = [];
  bool _restartOnPrevious = true;
  VoidCallback _toggleShuffle = () {};
  VoidCallback _cycleRepeat = () {};

  AudioEngine(this.source) {
    _p.playbackEventStream.listen((_) => _broadcast(), onError: (Object _) {});
    _p.playingStream.listen((_) => _broadcast());
    _p.currentIndexStream.listen((i) {
      if (i != null && i < _songs.length) _publish(i);
    });
    // A file that can't be played: skip it rather than stop the drive.
    _p.errorStream.listen((_) {
      if (_p.hasNext) _p.seekToNext();
    });
  }

  static Future<AudioEngine> start(LibrarySource source) => svc.AudioService.init(
    builder: () => AudioEngine(source),
    config: const svc.AudioServiceConfig(
      androidNotificationChannelId: 'com.dingo.roadie.playback',
      androidNotificationChannelName: 'Playback',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
      fastForwardInterval: Duration(seconds: 15),
      rewindInterval: Duration(seconds: 15),
    ),
  );

  svc.MediaItem _item(Song s) => svc.MediaItem(
    id: '${s.id}',
    title: s.title,
    artist: s.artist,
    album: s.album,
    genre: s.genre,
    duration: s.duration,
  );

  Future<void> _publish(int i) async {
    final s = _songs[i];
    mediaItem.add(_item(s));
    final art = await source.art(s.albumId, 512);
    if (art != null && _p.currentIndex == i) {
      mediaItem.add(_item(s).copyWith(artUri: Uri.file(art)));
    }
  }

  ja.AudioSource _audio(Song s) =>
      s.uri.startsWith('content:') ? ja.AudioSource.uri(Uri.parse(s.uri)) : ja.AudioSource.file(s.uri);

  void _broadcast() {
    final playing = _p.playing;
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          svc.MediaControl.skipToPrevious,
          playing ? svc.MediaControl.pause : svc.MediaControl.play,
          svc.MediaControl.skipToNext,
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

  // Engine (the app's player).

  @override
  Future<void> load(List<Song> songs, int index, Duration position) async {
    _songs = [...songs];
    queue.add([for (final s in songs) _item(s)]);
    try {
      await _p.setAudioSources(
        [for (final s in songs) _audio(s)],
        initialIndex: index,
        initialPosition: position,
      );
    } on Object catch (e) {
      debugPrint('load failed: $e');
    }
    if (index < songs.length) unawaited(_publish(index));
  }

  @override
  Future<void> play() => _p.play();
  @override
  Future<void> pause() => _p.pause();
  @override
  Future<void> seek(Duration position, {int? index}) => _p.seek(position, index: index);
  @override
  Future<void> next() => _p.hasNext ? _p.seekToNext() : Future.value();

  @override
  Future<void> previous({required bool restart}) {
    if (restart && _p.position > const Duration(seconds: 3)) return _p.seek(Duration.zero);
    return _p.hasPrevious ? _p.seekToPrevious() : _p.seek(Duration.zero);
  }

  @override
  Future<void> setRepeat(Repeat mode) => _p.setLoopMode(switch (mode) {
    Repeat.off => ja.LoopMode.off,
    Repeat.all => ja.LoopMode.all,
    Repeat.one => ja.LoopMode.one,
  });

  @override
  Future<void> insert(int index, Song song) {
    _songs.insert(index, song);
    queue.add([for (final s in _songs) _item(s)]);
    return _p.insertAudioSource(index, _audio(song));
  }

  @override
  Future<void> removeAt(int index) {
    _songs.removeAt(index);
    queue.add([for (final s in _songs) _item(s)]);
    return _p.removeAudioSourceAt(index);
  }

  @override
  Future<void> move(int from, int to) {
    _songs.insert(to, _songs.removeAt(from));
    queue.add([for (final s in _songs) _item(s)]);
    return _p.moveAudioSource(from, to);
  }

  @override
  Stream<int?> get indexStream => _p.currentIndexStream;
  @override
  Stream<bool> get playingStream => _p.playingStream;
  @override
  Stream<Duration> get positionStream => _p.createPositionStream(
    minPeriod: const Duration(milliseconds: 250),
    maxPeriod: const Duration(seconds: 1),
  );
  @override
  Stream<Duration?> get durationStream => _p.durationStream;

  @override
  set onToggleShuffle(VoidCallback f) => _toggleShuffle = f;
  @override
  set onCycleRepeat(VoidCallback f) => _cycleRepeat = f;

  set restartOnPrevious(bool v) => _restartOnPrevious = v;

  // Media session (notification, lock screen, steering wheel, Bluetooth).

  @override
  Future<void> skipToNext() => next();
  @override
  Future<void> skipToPrevious() => previous(restart: _restartOnPrevious);
  @override
  Future<void> skipToQueueItem(int index) => _p.seek(Duration.zero, index: index);
  @override
  Future<void> setShuffleMode(svc.AudioServiceShuffleMode shuffleMode) async => _toggleShuffle();
  @override
  Future<void> setRepeatMode(svc.AudioServiceRepeatMode repeatMode) async => _cycleRepeat();
  @override
  Future<void> stop() async {
    await _p.pause();
    await super.stop();
  }
}
