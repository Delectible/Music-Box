import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'sorting.dart';

enum Repeat { off, all, one }

/// What actually makes sound. [AudioEngine] (audio.dart) on the device,
/// [SilentEngine] in tests.
abstract class Engine {
  Future<void> load(List<Song> queue, int index, Duration position);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position, {int? index});
  Future<void> next();
  Future<void> previous({required bool restart});
  Future<void> setRepeat(Repeat mode);
  Future<void> insert(int index, Song song);
  Future<void> removeAt(int index);
  Future<void> move(int from, int to);

  Stream<int?> get indexStream;
  Stream<bool> get playingStream;
  Stream<Duration> get positionStream;
  Stream<Duration?> get durationStream;

  /// Media buttons (steering wheel, Bluetooth, notification) ask for these;
  /// the player decides what they mean.
  set onToggleShuffle(VoidCallback f) {}
  set onCycleRepeat(VoidCallback f) {}

  /// Android's audio session id of the player (for the visualiser), or null.
  int? get audioSession => null;
}

/// The queue and what's playing. The queue is the play order: shuffling
/// reorders it (the original order is kept to put it back).
class Player extends ChangeNotifier implements PlayHistory {
  final Engine engine;
  final SharedPreferences _prefs;
  bool Function() previousRestarts = () => true;

  Player(this.engine, this._prefs) {
    _subs = [
      engine.indexStream.listen((i) {
        if (i == null || i == index || i >= queue.length) return;
        index = i;
        _counted = false;
        _onSongChanged();
      }),
      engine.playingStream.listen((p) {
        if (p == playing) return;
        playing = p;
        notifyListeners();
        if (!p) _saveState();
      }),
      engine.positionStream.listen(_onPosition),
      engine.durationStream.listen((d) {
        duration = d ?? current?.duration ?? Duration.zero;
        notifyListeners();
      }),
    ];
    engine.onToggleShuffle = () => setShuffle(!shuffle);
    engine.onCycleRepeat = cycleRepeat;
    _loadHistory();
  }

  late final List<StreamSubscription<Object?>> _subs;

  List<Song> queue = [];
  List<Song> _original = [];
  int index = 0;
  bool playing = false;
  Duration duration = Duration.zero;
  bool shuffle = false;
  Repeat repeat = Repeat.off;

  /// Position updates come often; widgets that need them listen here
  /// instead of rebuilding with the whole player.
  final position = ValueNotifier(Duration.zero);

  Song? get current => index < queue.length ? queue[index] : null;
  bool get hasNext => repeat != Repeat.off || index < queue.length - 1;
  Song? get upNext => index + 1 < queue.length
      ? queue[index + 1]
      : (repeat == Repeat.all && queue.isNotEmpty ? queue.first : null);

  /// Plays [songs] starting at [start]. With [shuffled] the order is mixed
  /// (the chosen song, if any, goes first).
  Future<void> playAll(List<Song> songs, {int start = 0, bool shuffled = false}) async {
    if (songs.isEmpty) return;
    _original = [...songs];
    shuffle = shuffled;
    if (shuffled) {
      final first = start >= 0 && start < songs.length && start != 0 ? songs[start] : null;
      final rest = [...songs]..shuffle(Random());
      if (first != null) {
        rest.remove(first);
        rest.insert(0, first);
      }
      queue = rest;
      index = 0;
    } else {
      queue = [...songs];
      index = start.clamp(0, songs.length - 1);
    }
    _counted = false;
    duration = current!.duration;
    position.value = Duration.zero;
    notifyListeners();
    await engine.load(queue, index, Duration.zero);
    await engine.play();
    _saveQueue();
  }

  Future<void> toggle() => playing ? engine.pause() : engine.play();
  Future<void> play() => engine.play();
  Future<void> pause() => engine.pause();
  Future<void> next() => engine.next();
  Future<void> previous() => engine.previous(restart: previousRestarts());

  Future<void> seek(Duration d) async {
    position.value = d;
    await engine.seek(d);
  }

  Future<void> seekBy(Duration d) {
    final t = position.value + d;
    return seek(t < Duration.zero ? Duration.zero : (t > duration ? duration : t));
  }

  Future<void> jumpTo(int i) async {
    if (i < 0 || i >= queue.length) return;
    await engine.seek(Duration.zero, index: i);
    if (!playing) await engine.play();
  }

  Future<void> setShuffle(bool on) async {
    if (on == shuffle || queue.isEmpty) {
      shuffle = on;
      notifyListeners();
      return;
    }
    final song = current!;
    final pos = position.value;
    shuffle = on;
    if (on) {
      _original = [...queue];
      final rest = [...queue]
        ..removeAt(index)
        ..shuffle(Random());
      queue = [song, ...rest];
      index = 0;
    } else {
      queue = _original.isEmpty ? queue : [..._original];
      index = max(0, queue.indexWhere((s) => s.id == song.id));
    }
    notifyListeners();
    final wasPlaying = playing;
    await engine.load(queue, index, pos);
    if (wasPlaying) await engine.play();
    _saveQueue();
  }

  Future<void> cycleRepeat() async {
    repeat = Repeat.values[(repeat.index + 1) % Repeat.values.length];
    notifyListeners();
    await engine.setRepeat(repeat);
    unawaited(_prefs.setInt('repeat', repeat.index));
  }

  /// Adds after the current song.
  Future<void> playNext(List<Song> songs) => _insertAt(index + 1, songs);

  Future<void> addToQueue(List<Song> songs) => _insertAt(queue.length, songs);

  Future<void> _insertAt(int at, List<Song> songs) async {
    if (queue.isEmpty) return playAll(songs);
    for (var i = 0; i < songs.length; i++) {
      queue.insert(at + i, songs[i]);
      _original.add(songs[i]);
      await engine.insert(at + i, songs[i]);
    }
    notifyListeners();
    _saveQueue();
  }

  Future<void> removeAt(int i) async {
    if (i == index || i < 0 || i >= queue.length) return;
    final s = queue.removeAt(i);
    _original.remove(s);
    if (i < index) index--;
    notifyListeners();
    await engine.removeAt(i);
    _saveQueue();
  }

  Future<void> move(int from, int to) async {
    if (from == to) return;
    final s = queue.removeAt(from);
    queue.insert(to, s);
    if (from == index) {
      index = to;
    } else if (from < index && to >= index) {
      index--;
    } else if (from > index && to <= index) {
      index++;
    }
    notifyListeners();
    await engine.move(from, to);
    _saveQueue();
  }

  // Position, play counts and saving.

  bool _counted = false;
  DateTime _lastSave = DateTime.fromMillisecondsSinceEpoch(0);

  void _onPosition(Duration p) {
    position.value = p;
    final song = current;
    if (song == null) return;
    // A play counts once half the song (or four minutes) has been heard.
    final need = duration.inMilliseconds > 0
        ? Duration(milliseconds: min(duration.inMilliseconds ~/ 2, 240000))
        : const Duration(seconds: 30);
    if (!_counted && p >= need) {
      _counted = true;
      _plays[song.id] = (_plays[song.id] ?? 0) + 1;
      _last[song.id] = DateTime.now().millisecondsSinceEpoch;
      _saveHistory();
    }
    if (playing && DateTime.now().difference(_lastSave).inSeconds >= 10) _saveState();
  }

  void _onSongChanged() {
    duration = current?.duration ?? Duration.zero;
    position.value = Duration.zero;
    notifyListeners();
    _saveState();
  }

  final _plays = <int, int>{};
  final _last = <int, int>{};

  @override
  int plays(int songId) => _plays[songId] ?? 0;

  @override
  DateTime? lastPlayed(int songId) {
    final t = _last[songId];
    return t == null ? null : DateTime.fromMillisecondsSinceEpoch(t);
  }

  void _loadHistory() {
    try {
      final m = jsonDecode(_prefs.getString('history') ?? '{}') as Map<String, Object?>;
      for (final e in m.entries) {
        final v = (e.value as List<Object?>).cast<num>();
        _plays[int.parse(e.key)] = v[0].toInt();
        _last[int.parse(e.key)] = v[1].toInt();
      }
    } on Object {
      // A bad save just starts the counts again.
    }
    repeat = Repeat.values[(_prefs.getInt('repeat') ?? 0).clamp(0, 2)];
  }

  void _saveHistory() => _prefs.setString(
    'history',
    jsonEncode({
      for (final e in _plays.entries) '${e.key}': [e.value, _last[e.key] ?? 0],
    }),
  );

  void _saveQueue() {
    _prefs.setString('queue', [for (final s in queue) s.id].join(','));
    _prefs.setString('original', [for (final s in _original) s.id].join(','));
    _prefs.setBool('shuffle', shuffle);
    _saveState();
  }

  void _saveState() {
    _lastSave = DateTime.now();
    _prefs.setInt('index', index);
    _prefs.setInt('position', position.value.inMilliseconds);
  }

  /// Puts back the last queue once the library has loaded.
  Future<void> restore(Map<int, Song> byId, {required bool autoplay}) async {
    if (queue.isNotEmpty) return;
    List<Song> ids(String key) => [
      for (final p in (_prefs.getString(key) ?? '').split(',')) ?byId[int.tryParse(p)],
    ];
    final q = ids('queue');
    if (q.isEmpty) return;
    queue = q;
    _original = ids('original');
    shuffle = _prefs.getBool('shuffle') ?? false;
    index = (_prefs.getInt('index') ?? 0).clamp(0, q.length - 1);
    final pos = Duration(milliseconds: _prefs.getInt('position') ?? 0);
    position.value = pos;
    duration = current!.duration;
    notifyListeners();
    await engine.load(queue, index, pos);
    await engine.setRepeat(repeat);
    if (autoplay) await engine.play();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    position.dispose();
    super.dispose();
  }
}

/// Plays nothing; keeps time so the UI behaves. Tests and screenshots.
class SilentEngine extends Engine {
  final _index = StreamController<int?>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration?>.broadcast();
  int _i = 0;
  int _n = 0;

  @override
  Future<void> load(List<Song> queue, int index, Duration position) async {
    _n = queue.length;
    _i = index;
    _position.add(position);
  }

  @override
  Future<void> play() async => _playing.add(true);
  @override
  Future<void> pause() async => _playing.add(false);
  @override
  Future<void> seek(Duration position, {int? index}) async {
    if (index != null) _index.add(_i = index);
    _position.add(position);
  }

  @override
  Future<void> next() async {
    if (_i + 1 < _n) _index.add(++_i);
  }

  @override
  Future<void> previous({required bool restart}) async {
    if (_i > 0) _index.add(--_i);
  }

  @override
  Future<void> setRepeat(Repeat mode) async {}
  @override
  Future<void> insert(int index, Song song) async => _n++;
  @override
  Future<void> removeAt(int index) async => _n--;
  @override
  Future<void> move(int from, int to) async {}

  void close() {
    _index.close();
    _playing.close();
    _position.close();
    _duration.close();
  }

  /// Pretends the song has played this far.
  void advance(Duration to) => _position.add(to);

  @override
  Stream<int?> get indexStream => _index.stream;
  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  Stream<Duration> get positionStream => _position.stream;
  @override
  Stream<Duration?> get durationStream => _duration.stream;
}
