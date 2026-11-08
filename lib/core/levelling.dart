import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

enum LevelMode {
  off('Off'),
  track('Each song'),
  album('Albums as a whole');

  final String label;
  const LevelMode(this.label);
}

/// Volume levelling: each song's gain (dB) to bring it to the same loudness
/// (-18 LUFS, the ReplayGain level). From the file's ReplayGain tags, or
/// measured once on the device and remembered.
class Levelling extends ChangeNotifier {
  static const _ch = MethodChannel('roadie/library');
  static const target = -18.0;
  final SharedPreferences _p;
  Levelling(this._p) {
    try {
      final m = jsonDecode(_p.getString('gains') ?? '{}') as Map<String, Object?>;
      for (final e in m.entries) {
        final v = (e.value! as List).cast<num?>();
        _known[e.key] = (v[0]?.toDouble(), v.length > 1 ? v[1]?.toDouble() : null);
      }
    } on Object {
      // Measure again.
    }
  }

  /// path@modified → (track gain, album gain); null parts unknown.
  final _known = <String, (double?, double?)>{};
  final _queue = <Song>[];
  bool _busy = false;
  Timer? _save;

  static String _key(Song s) => '${s.path}@${s.modified.millisecondsSinceEpoch}';

  /// The gain for [s] in [mode] (0 when unknown or off), plus [preamp].
  double gainOf(Song s, LevelMode mode, double preamp) {
    if (mode == LevelMode.off) return 0;
    final k = _known[_key(s)];
    if (k == null) return 0;
    final g = mode == LevelMode.album ? (k.$2 ?? k.$1) : k.$1;
    return g == null ? 0 : (g + preamp).clamp(-15.0, 12.0);
  }

  bool known(Song s) => _known.containsKey(_key(s));

  /// Reads / measures [songs] (the playing one first), one at a time.
  void prepare(List<Song> songs) {
    for (final s in songs.reversed) {
      if (known(s) || s.podcast) continue;
      _queue
        ..remove(s)
        ..insert(0, s);
    }
    unawaited(_run());
  }

  Future<void> _run() async {
    if (_busy) return;
    _busy = true;
    while (_queue.isNotEmpty) {
      final s = _queue.removeAt(0);
      if (known(s)) continue;
      try {
        final m = await _ch.invokeMapMethod<String, Object?>('loudness', {'path': s.path, 'measure': true});
        final track = (m?['trackGain'] as num?)?.toDouble();
        final album = (m?['albumGain'] as num?)?.toDouble();
        final lufs = (m?['lufs'] as num?)?.toDouble();
        _known[_key(s)] = (track ?? (lufs == null ? null : target - lufs), album);
        _save?.cancel();
        _save = Timer(const Duration(seconds: 2), _store);
        notifyListeners();
      } on MissingPluginException {
        _queue.clear(); // tests: no device
      } on Object {
        _known[_key(s)] = (null, null); // can't be read: don't keep trying
      }
    }
    _busy = false;
  }

  void _store() => _p.setString(
    'gains',
    jsonEncode({
      for (final e in _known.entries) e.key: [e.value.$1, e.value.$2],
    }),
  );
}
