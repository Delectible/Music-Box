import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'models.dart';
import 'native.dart';

/// A song's audio quality for the player's badge: "FLAC 24-bit · 96 kHz",
/// "MP3 320 kbps".
class Quality {
  final String codec;
  final bool lossless;
  final int bits;
  final double khz;
  final int kbps;
  final bool vbr;
  const Quality({
    required this.codec,
    required this.lossless,
    required this.bits,
    required this.khz,
    required this.kbps,
    required this.vbr,
  });

  /// Hi-res: lossless above CD (more than 16-bit or above 48 kHz).
  bool get hiRes => lossless && (bits > 16 || khz > 48);

  String get label {
    String k(double v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);
    if (lossless) return '$codec ${bits > 0 ? '$bits-bit · ' : ''}${k(khz)} kHz';
    return '$codec ${vbr ? '~' : ''}$kbps kbps';
  }

  static Quality? from(Map<String, Object?> m, String fileName) {
    final fmt = '${m['format'] ?? m['encoding'] ?? ''}'.toUpperCase();
    final ext = fileName.contains('.') ? fileName.substring(fileName.lastIndexOf('.') + 1).toUpperCase() : '';
    final codec = switch (fmt) {
      _ when fmt.contains('FLAC') => 'FLAC',
      _ when fmt.contains('ALAC') => 'ALAC',
      _ when fmt.contains('AAC') || fmt.contains('MP4') => 'AAC',
      _ when fmt.contains('MPEG') || fmt.contains('MP3') => 'MP3',
      _ when fmt.contains('OPUS') => 'Opus',
      _ when fmt.contains('VORBIS') || fmt.contains('OGG') => 'Ogg',
      _ when fmt.contains('WAV') => 'WAV',
      _ when fmt.contains('AIF') => 'AIFF',
      _ => ext.isEmpty ? fmt : ext,
    };
    if (codec.isEmpty) return null;
    final hz = double.tryParse('${m['sampleRate'] ?? ''}') ?? 0;
    return Quality(
      codec: codec,
      lossless: m['lossless'] == true || const {'FLAC', 'ALAC', 'WAV', 'AIFF'}.contains(codec),
      bits: (m['bitsPerSample'] as num?)?.toInt() ?? 0,
      khz: hz / 1000,
      kbps: int.tryParse('${m['bitRate'] ?? ''}'.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0,
      vbr: m['variableBitRate'] == true,
    );
  }

  static final _cache = <int, Future<Quality?>>{};

  @visibleForTesting
  static void clearCache() => _cache.clear();

  /// Read once per song (from the file's headers).
  static Future<Quality?> of(Song s) => _cache.putIfAbsent(s.id, () async {
    try {
      return from(await Native.readTags(s.path), s.fileName);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  });
}
