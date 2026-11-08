import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/native.dart';
import '../core/scope.dart';
import '../core/theme.dart';
import '../core/visualizer.dart';
import '../widgets/art.dart';
import '../widgets/controls.dart';
import '../widgets/visualizer_painter.dart';

void openVisualizer(BuildContext context) => Navigator.of(context).push(
  PageRouteBuilder<void>(
    opaque: true,
    transitionDuration: const Duration(milliseconds: 350),
    pageBuilder: (_, _, _) => const VisualizerScreen(),
    transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
  ),
);

/// Full screen visualisers. Swipe sideways (or use the arrows) to change
/// style; tap to show the controls.
class VisualizerScreen extends StatefulWidget {
  /// Tests: don't touch the device's audio.
  final bool simulated;
  const VisualizerScreen({super.key, this.simulated = false});

  @override
  State<VisualizerScreen> createState() => _VisualizerScreenState();
}

class _VisualizerScreenState extends State<VisualizerScreen> with SingleTickerProviderStateMixin {
  final _scene = VizScene();
  final _frame = ValueNotifier<int>(0);
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  bool _controls = true;
  Timer? _hide;
  bool _needsPermission = false;
  int? _session;
  int _barsBefore = 1;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    _barsBefore = AppScope.of(context).settings.bars.index;
    unawaited(Native.immersive(2));
    unawaited(WakelockPlus.enable().catchError((Object _) {}));
    _showControls();
    if (!widget.simulated) unawaited(_connect());
  }

  Future<void> _connect() async {
    var ok = await Native.canRecord();
    if (!ok) ok = await Native.requestRecord();
    if (!mounted) return;
    setState(() => _needsPermission = !ok);
    if (ok) {
      _session = AppScope.of(context).player.engine.audioSession;
      _scene.feed.start(_session);
    }
  }

  void _onTick(Duration now) {
    final dt = _last == Duration.zero ? 1 / 60 : (now - _last).inMicroseconds / 1e6;
    _last = now;
    final player = AppScope.of(context).player;
    _scene.feed.playing = player.playing;
    // The player can make a new audio session (e.g. a new queue).
    final s = player.engine.audioSession;
    if (!widget.simulated && !_needsPermission && s != null && s != _session) {
      _session = s;
      _scene.feed.start(s);
    }
    _scene.tick(min(dt, 0.1));
    _frame.value++;
  }

  void _showControls() {
    setState(() => _controls = true);
    _hide?.cancel();
    _hide = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _controls = false);
    });
  }

  void _step(int by) {
    final s = AppScope.of(context).settings;
    final all = VizStyle.values;
    final next = all[(all.indexOf(VizStyle.byName(s.visualizer)) + by) % all.length];
    s.visualizer = next.name;
    _showControls();
  }

  @override
  void dispose() {
    _hide?.cancel();
    _ticker.dispose();
    _scene.feed.stop();
    _frame.dispose();
    unawaited(Native.immersive(_barsBefore));
    unawaited(WakelockPlus.disable().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([scope.settings, scope.player]),
      builder: (context, _) {
        final style = VizStyle.byName(scope.settings.visualizer);
        final song = scope.player.current;
        final accent = Theme.of(context).colorScheme.primary;
        return Scaffold(
          backgroundColor: Colors.black,
          body: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _controls ? setState(() => _controls = false) : _showControls(),
            child: SkipSwipe(
              enabled: true,
              onNext: () => _step(1),
              onPrevious: () => _step(-1),
              child: LayoutBuilder(
                builder: (context, box) {
                  final short = min(box.maxWidth, box.maxHeight);
                  final cover = short * 0.46;
                  // Changing style cross-fades the old picture into the new one.
                  final picture = Stack(
                    key: ValueKey(style),
                    fit: StackFit.expand,
                    children: [
                      RepaintBoundary(
                        child: ImageFiltered(
                          // Ambience is drawn coarse; blur makes it soft clouds.
                          enabled: style == VizStyle.ambience,
                          imageFilter: ImageFilter.blur(sigmaX: 14, sigmaY: 14, tileMode: TileMode.clamp),
                          child: CustomPaint(
                            painter: VizPainter(
                              style: style,
                              scene: _scene,
                              accent: accent,
                              coverSize: cover,
                              repaint: _frame,
                            ),
                          ),
                        ),
                      ),
                      if (style.usesCover && song != null)
                        Center(
                          child: Transform.translate(
                            offset: Offset(0, -short * 0.05),
                            child: ValueListenableBuilder<int>(
                              valueListenable: _frame,
                              builder: (context, _, child) => Transform.scale(
                                scale: 1 + _scene.feed.beat * 0.035 + _scene.feed.level * 0.03,
                                child: child,
                              ),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  boxShadow: [
                                    BoxShadow(color: accent.withValues(alpha: 0.6), blurRadius: 60),
                                  ],
                                ),
                                child: Art(albumId: song.albumId, size: cover, radius: cover * 0.04),
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(
                        color: Colors.black,
                        child: AnimatedSwitcher(
                          duration: motion(AppScope.of(context).settings, 600),
                          switchInCurve: Curves.easeInOut,
                          switchOutCurve: Curves.easeInOut,
                          layoutBuilder: (current, previous) =>
                              Stack(fit: StackFit.expand, children: [...previous, ?current]),
                          child: picture,
                        ),
                      ),
                      AnimatedOpacity(
                        opacity: _controls ? 1 : 0,
                        duration: const Duration(milliseconds: 250),
                        child: IgnorePointer(ignoring: !_controls, child: _overlay(context, style)),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _overlay(BuildContext context, VizStyle style) {
    final scope = AppScope.of(context);
    final song = scope.player.current;
    const white = Colors.white;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xB0000000), Color(0x00000000), Color(0x00000000), Color(0xB0000000)],
          stops: [0, .25, .7, 1],
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            children: [
              Row(
                children: [
                  BigIconButton(
                    icon: Icons.close_rounded,
                    size: 60,
                    color: white,
                    tooltip: 'Close',
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          song?.title ?? 'Nothing playing',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: white, fontSize: 22, fontWeight: FontWeight.w600),
                        ),
                        if (song != null)
                          Text(
                            song.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white70, fontSize: 17),
                          ),
                      ],
                    ),
                  ),
                  if (_needsPermission)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilledButton.tonalIcon(
                        onPressed: _connect,
                        icon: const Icon(Icons.mic_rounded),
                        label: const Text('Follow the music'),
                      ),
                    ),
                  BigIconButton(
                    icon: Icons.chevron_left_rounded,
                    size: 60,
                    color: white,
                    tooltip: 'Previous style',
                    onTap: () => _step(-1),
                  ),
                  InkWell(
                    borderRadius: BorderRadius.circular(30),
                    onTap: () => _pickStyle(context),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
                      child: Text(style.label, style: const TextStyle(color: white, fontSize: 19)),
                    ),
                  ),
                  BigIconButton(
                    icon: Icons.chevron_right_rounded,
                    size: 60,
                    color: white,
                    tooltip: 'Next style',
                    onTap: () => _step(1),
                  ),
                ],
              ),
              const Spacer(),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  BigIconButton(
                    icon: Icons.skip_previous_rounded,
                    size: 72,
                    color: white,
                    tooltip: 'Previous',
                    onTap: () => scope.player.previous(),
                  ),
                  const SizedBox(width: 16),
                  const PlayPauseButton(size: 80, background: Colors.white24, foreground: white),
                  const SizedBox(width: 16),
                  BigIconButton(
                    icon: Icons.skip_next_rounded,
                    size: 72,
                    color: white,
                    tooltip: 'Next',
                    onTap: () => scope.player.next(),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickStyle(BuildContext context) async {
    final s = AppScope.of(context).settings;
    _hide?.cancel();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final v in VizStyle.values)
                ChoiceChip(
                  label: Padding(padding: const EdgeInsets.all(6), child: Text(v.label)),
                  selected: v.name == s.visualizer,
                  onSelected: (_) {
                    s.visualizer = v.name;
                    Navigator.of(context).pop();
                  },
                ),
            ],
          ),
        ),
      ),
    );
    _showControls();
  }
}
