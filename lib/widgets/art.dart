import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

import '../core/library.dart';
import '../core/player.dart';
import '../core/scope.dart';
import '../core/settings.dart';
import '../core/theme.dart';

/// Hero flights of the playing cover: the big (player) cover, scaled, the
/// whole way. Building the cover at every in-between size would fetch a new
/// image size each frame and flash the stand-in.
Widget nowArtShuttle(
  BuildContext flight,
  Animation<double> animation,
  HeroFlightDirection direction,
  BuildContext from,
  BuildContext to,
) {
  final big = (direction == HeroFlightDirection.push ? to.widget : from.widget) as Hero;
  return FittedBox(child: big.child);
}

/// Decodes the playing song's cover ahead of time, at the sizes the player
/// uses, so opening the player shows it on the first frame.
Future<void> warmCover(BuildContext context, int albumId) async {
  final source = AppScope.of(context).library.source;
  for (final size in const [400, 800]) {
    final path = await source.art(albumId, size);
    if (path == null || !context.mounted) continue;
    await precacheImage(ResizeImage(FileImage(File(path)), width: size), context, onError: (_, _) {});
  }
}

/// A colour of its own for each album without a cover.
Color albumHue(int albumId) {
  final h = (albumId * 137.508) % 360;
  return HSLColor.fromAHSL(1, h, 0.55, 0.52).toColor();
}

/// An album cover, or a drawn stand-in when there isn't one.
class Art extends StatelessWidget {
  final int albumId;
  final double size;
  final ArtShape? shape;
  final double? radius;

  /// A picture file shown instead of the album's (a playlist cover).
  final String? file;

  const Art({super.key, required this.albumId, required this.size, this.shape, this.radius, this.file});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final r = radius != null
        ? BorderRadius.circular(radius!)
        : artRadius(shape ?? scope.settings.artShape, size);
    final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
    final bucket = px <= 160 ? 160 : (px <= 400 ? 400 : 800);
    final own = file;
    if (own != null) {
      return ClipRRect(
        borderRadius: r,
        child: Image.file(
          File(own),
          width: size,
          height: size,
          fit: BoxFit.cover,
          cacheWidth: bucket,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => _Placeholder(albumId: albumId, size: size),
        ),
      );
    }
    return ClipRRect(
      borderRadius: r,
      child: SizedBox.square(
        dimension: size,
        child: albumId < 0
            ? _Placeholder(albumId: albumId, size: size)
            : FutureBuilder<String?>(
                future: scope.library.source.art(albumId, bucket),
                // A cover fetched before shows straight away (no stand-in flash).
                initialData: scope.library.source.artNow(albumId, bucket),
                builder: (context, snap) {
                  final path = snap.data ?? scope.library.source.artNow(albumId, bucket);
                  return AnimatedSwitcher(
                    duration: motion(scope.settings, 250),
                    child: path == null
                        ? _Placeholder(key: const ValueKey(0), albumId: albumId, size: size)
                        : Image.file(
                            File(path),
                            key: ValueKey(path),
                            width: size,
                            height: size,
                            fit: BoxFit.cover,
                            cacheWidth: bucket,
                            gaplessPlayback: true,
                            errorBuilder: (_, _, _) => _Placeholder(albumId: albumId, size: size),
                          ),
                  );
                },
              ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  final int albumId;
  final double size;
  const _Placeholder({super.key, required this.albumId, required this.size});

  @override
  Widget build(BuildContext context) {
    final c = albumId < 0 ? Theme.of(context).colorScheme.primary : albumHue(albumId);
    return CustomPaint(size: Size.square(size), painter: _GroovePainter(c, albumId));
  }
}

/// Soft gradient with the edge of a record peeking in.
class _GroovePainter extends CustomPainter {
  final Color color;
  final int seed;
  _GroovePainter(this.color, this.seed);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final hsl = HSLColor.fromColor(color);
    final a = hsl.withLightness((hsl.lightness * 0.55).clamp(0, 1)).toColor();
    final b = hsl.withHue((hsl.hue + 40) % 360).withLightness(0.62).toColor();
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [b, a],
        ).createShader(rect),
    );
    final r = Random(seed);
    final centre = Offset(
      size.width * (0.7 + r.nextDouble() * 0.15),
      size.height * (0.72 + r.nextDouble() * 0.1),
    );
    final radius = size.width * 0.62;
    canvas.drawCircle(centre, radius, Paint()..color = Colors.black.withValues(alpha: 0.28));
    final groove = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = max(0.6, size.width / 220)
      ..color = Colors.white.withValues(alpha: 0.07);
    for (var g = radius * 0.4; g < radius; g += size.width / 36) {
      canvas.drawCircle(centre, g, groove);
    }
    canvas.drawCircle(centre, radius * 0.3, Paint()..color = b.withValues(alpha: 0.9));
    canvas.drawCircle(centre, radius * 0.04, Paint()..color = a);
  }

  @override
  bool shouldRepaint(_GroovePainter old) => old.color != color || old.seed != seed;
}

/// The accent colour: fixed in Settings, or taken from the playing cover.
class Accent extends ChangeNotifier {
  final Settings settings;
  final Player player;
  final Library library;

  Accent(this.settings, this.player, this.library) {
    settings.addListener(_update);
    player.addListener(_update);
    _update();
  }

  Color color = accents.first;
  int _albumId = -2;
  Color? _fixed;

  Future<void> _update() async {
    final fixed = settings.accent;
    final id = player.current?.albumId ?? -1;
    if (fixed == _fixed && id == _albumId && (fixed != null || _albumId != -2)) return;
    _fixed = fixed;
    _albumId = id;
    if (fixed != null) return _setColor(fixed);
    if (id < 0) return _setColor(accents.first);
    final path = await library.source.art(id, 160);
    if (_albumId != id) return;
    if (path == null) return _setColor(_vivid(albumHue(id)));
    try {
      final scheme = await ColorScheme.fromImageProvider(provider: FileImage(File(path)));
      if (_albumId == id) _setColor(_vivid(scheme.primary));
    } on Object {
      _setColor(_vivid(albumHue(id)));
    }
  }

  /// Bright enough to read on a dark screen.
  static Color _vivid(Color c) {
    final h = HSLColor.fromColor(c);
    return h.withSaturation(max(h.saturation, 0.55)).withLightness(h.lightness.clamp(0.55, 0.7)).toColor();
  }

  void _setColor(Color c) {
    if (c == color) return;
    color = c;
    notifyListeners();
  }

  @override
  void dispose() {
    settings.removeListener(_update);
    player.removeListener(_update);
    super.dispose();
  }
}
