import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

import '../core/library.dart';
import '../core/player.dart';
import '../core/scope.dart';
import '../core/settings.dart';
import '../core/theme.dart';

/// The playing cover's Hero tag. The mini player's cover only flies to and
/// from the full screen player, never between two screens' mini players
/// (it slid about while the bar itself just moved with the page): the two
/// tags match only when one is the player's.
class NowArtTag {
  /// The screen a mini player is on; null for the full screen player.
  final Object? route;
  const NowArtTag._(this.route);
  static const player = NowArtTag._(null);
  factory NowArtTag.mini(BuildContext context) => NowArtTag._(ModalRoute.of(context) ?? context);

  @override
  bool operator ==(Object other) =>
      other is NowArtTag && (route == null || other.route == null || identical(route, other.route));

  @override
  int get hashCode => 7;
}

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
  // The player's picture has a flight of its own (the record's label):
  // use it both ways, not just on the way in.
  final own = big.flightShuttleBuilder;
  if (own != null && own != nowArtShuttle) return own(flight, animation, direction, from, to);
  return FittedBox(child: big.child);
}

/// The playing cover's path between the mini player and the full screen
/// player. The player page slides up from the bottom; the cover settles onto
/// its place on that moving page (rather than flying a separate arc), so
/// cover and record arrive together. Closing is the same in reverse.
Tween<Rect?> nowArtRectTween(Rect? begin, Rect? end) => _FollowPage(begin: begin, end: end);

class _FollowPage extends Tween<Rect?> {
  _FollowPage({super.begin, super.end});

  /// A smooth "lower of the two" (no corner where the cover gets picked up).
  static double _smin(double a, double b) {
    const k = 30.0;
    final m = min(a, b);
    return m - k * log(exp((m - a) / k) + exp((m - b) / k));
  }

  @override
  Rect? lerp(double t) {
    final b = begin, e = end;
    if (b == null || e == null) return Rect.lerp(b, e, t);
    final views = WidgetsBinding.instance.platformDispatcher.views;
    final view = views.isEmpty ? null : views.first;
    final h = view == null ? 800.0 : view.physicalSize.height / view.devicePixelRatio;
    // The bigger one is in the player. Its place rides the page, which is
    // off the bottom of the screen at the mini player's end.
    final opening = e.width >= b.width;
    final player = opening ? e : b;
    final mini = opening ? b : e;
    final p = opening ? t : 1 - t; // 0 = mini player, 1 = player
    final onPage = player.center.translate(0, h * (1 - p));
    // Sideways it eases over; up and down it waits at the mini player until
    // the rising page reaches it, then rides the page (and the reverse).
    final x = mini.center.dx + (player.center.dx - mini.center.dx) * Curves.easeOutCubic.transform(p);
    final y = _smin(mini.center.dy, onPage.dy);
    final size = Size.lerp(mini.size, player.size, p)!;
    return Rect.fromCenter(center: Offset(x, y), width: size.width, height: size.height);
  }
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
