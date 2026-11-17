import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/native.dart';
import '../core/player.dart';
import '../core/scope.dart';
import '../core/settings.dart';
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

  // The song's title shown for a moment when it changes.
  bool _title = false;
  Timer? _titleTimer;
  int? _songId;

  // Changing style by itself on a timer.
  Timer? _cycle;
  String _cycleKey = '';
  final _rnd = Random();
  late final Player _player;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    final scope = AppScope.of(context);
    _player = scope.player;
    _barsBefore = scope.settings.bars.index;
    _songId = scope.player.current?.id;
    unawaited(VizShaders.load());
    unawaited(Native.immersive(2));
    unawaited(WakelockPlus.enable().catchError((Object _) {}));
    _showControls();
    if (scope.settings.vizSongTitle) _showTitle();
    _player.addListener(_songChanged);
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

  /// A new song: its title for a moment (with the controls, to skip it),
  /// and a new style if it changes every song.
  void _songChanged() {
    final scope = AppScope.of(context);
    final id = scope.player.current?.id;
    if (id == _songId) return;
    _songId = id;
    if (id == null) return;
    final s = scope.settings;
    if (s.vizCycle == VizCycle.song) _randomStyle();
    if (s.vizSongTitle) {
      _showTitle();
      if (s.vizControls == VizControls.auto) _showControls();
    }
  }

  void _showTitle() {
    setState(() => _title = true);
    _titleTimer?.cancel();
    _titleTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _title = false);
    });
  }

  void _randomStyle() {
    final s = AppScope.of(context).settings;
    final now = VizStyle.byName(s.visualizer);
    final others = VizStyle.values.where((v) => v != now).toList();
    s.visualizer = others[_rnd.nextInt(others.length)].name;
  }

  /// Keeps the style timer in step with the settings.
  void _syncCycle() {
    final s = AppScope.of(context).settings;
    final key = s.vizCycle == VizCycle.timer ? 'timer${s.vizCycleMinutes}' : '';
    if (key == _cycleKey) return;
    _cycleKey = key;
    _cycle?.cancel();
    _cycle = key.isEmpty ? null : Timer.periodic(Duration(minutes: s.vizCycleMinutes), (_) => _randomStyle());
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
    _player.removeListener(_songChanged);
    _hide?.cancel();
    _titleTimer?.cancel();
    _cycle?.cancel();
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
        _syncCycle();
        final s = scope.settings;
        final style = VizStyle.byName(s.visualizer);
        final song = scope.player.current;
        final accent = Theme.of(context).colorScheme.primary;
        final mode = s.vizControls;
        final clock = vizClockLook(style, accent);
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
                  final cover = short * 0.42;
                  // Changing style cross-fades the old picture into the new one.
                  final picture = Stack(
                    key: ValueKey(style),
                    fit: StackFit.expand,
                    children: [
                      RepaintBoundary(
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
                      if (style.usesCover && song != null)
                        Center(
                          child: Transform.translate(
                            offset: Offset(0, -short * 0.05),
                            child: ValueListenableBuilder<int>(
                              valueListenable: _frame,
                              builder: (context, _, child) => Transform.scale(
                                scale: 1 + _scene.feed.beat * 0.04 + _scene.feed.bass * 0.03,
                                child: child,
                              ),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(cover * 0.04),
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
                  final topBarShown = _controls;
                  final bottomBar = mode == VizControls.on;
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(
                        color: Colors.black,
                        child: AnimatedSwitcher(
                          duration: motion(s, 600),
                          switchInCurve: Curves.easeInOut,
                          switchOutCurve: Curves.easeInOut,
                          layoutBuilder: (current, previous) =>
                              Stack(fit: StackFit.expand, children: [...previous, ?current]),
                          child: picture,
                        ),
                      ),
                      if (s.vizClock)
                        SafeArea(
                          child: AnimatedPadding(
                            duration: motion(s, 250),
                            curve: Curves.easeOutCubic,
                            // Out of the way of the bars shown over it.
                            padding: EdgeInsets.fromLTRB(
                              28,
                              clock.at.y < 0 && topBarShown ? 92 : 20,
                              28,
                              clock.at.y > 0 && (bottomBar || (topBarShown && mode == VizControls.auto))
                                  ? 120
                                  : 20,
                            ),
                            child: Align(
                              alignment: clock.at,
                              child: AnimatedSwitcher(
                                duration: motion(s, 400),
                                child: _VizClock(key: ValueKey(style), style: clock.style),
                              ),
                            ),
                          ),
                        ),
                      // The song's title, for a moment when it changes.
                      if (song != null)
                        SafeArea(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(32, 0, 32, bottomBar ? 120 : 40),
                            child: Align(
                              alignment: Alignment.bottomLeft,
                              child: AnimatedSwitcher(
                                duration: motion(s, 450),
                                transitionBuilder: (child, a) => FadeTransition(
                                  opacity: a,
                                  child: SlideTransition(
                                    position: Tween(
                                      begin: const Offset(0, 0.25),
                                      end: Offset.zero,
                                    ).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
                                    child: child,
                                  ),
                                ),
                                child: _title && !(topBarShown && mode == VizControls.auto)
                                    ? _TitleCard(
                                        key: ValueKey(song.id),
                                        title: song.title,
                                        artist: song.artist,
                                      )
                                    : const SizedBox.shrink(),
                              ),
                            ),
                          ),
                        ),
                      if (bottomBar) const Align(alignment: Alignment.bottomCenter, child: _ControlBar()),
                      AnimatedOpacity(
                        opacity: topBarShown ? 1 : 0,
                        duration: motion(s, 250),
                        child: IgnorePointer(ignoring: !topBarShown, child: _overlay(context, style, mode)),
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

  Widget _overlay(BuildContext context, VizStyle style, VizControls mode) {
    final scope = AppScope.of(context);
    final song = scope.player.current;
    const white = Colors.white;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xB0000000),
            const Color(0x00000000),
            const Color(0x00000000),
            Color(mode == VizControls.auto ? 0xB0000000 : 0x00000000),
          ],
          stops: const [0, .25, .7, 1],
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
                  BigIconButton(
                    icon: Icons.tune_rounded,
                    size: 60,
                    color: white,
                    tooltip: 'Visualiser options',
                    onTap: () => _options(context),
                  ),
                ],
              ),
              const Spacer(),
              if (mode == VizControls.auto)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    BigIconButton(
                      icon: Icons.skip_previous_rounded,
                      size: 72,
                      color: white,
                      tooltip: 'Previous',
                      onTap: () {
                        scope.player.previous();
                        _showControls();
                      },
                    ),
                    const SizedBox(width: 16),
                    const PlayPauseButton(size: 80, background: Colors.white24, foreground: white),
                    const SizedBox(width: 16),
                    BigIconButton(
                      icon: Icons.skip_next_rounded,
                      size: 72,
                      color: white,
                      tooltip: 'Next',
                      onTap: () {
                        scope.player.next();
                        _showControls();
                      },
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _options(BuildContext context) async {
    _hide?.cancel();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 680),
      builder: (context) => const SafeArea(child: SingleChildScrollView(child: VizOptions())),
    );
    if (mounted) _showControls();
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

/// The time, in the style's own look.
class _VizClock extends StatefulWidget {
  final TextStyle style;
  const _VizClock({super.key, required this.style});

  @override
  State<_VizClock> createState() => _VizClockState();
}

class _VizClockState extends State<_VizClock> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 10), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = TimeOfDay.now();
    final use24 = MediaQuery.alwaysUse24HourFormatOf(context);
    final h = use24 ? t.hour : (t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod);
    return Text('$h:${t.minute.toString().padLeft(2, '0')}', style: widget.style);
  }
}

/// The song's title and artist, big, for a moment.
class _TitleCard extends StatelessWidget {
  final String title, artist;
  const _TitleCard({super.key, required this.title, required this.artist});

  @override
  Widget build(BuildContext context) {
    const shadow = [Shadow(color: Color(0xCC000000), blurRadius: 16)];
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 40,
              fontWeight: FontWeight.w600,
              height: 1.1,
              shadows: shadow,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 24, shadows: shadow),
          ),
        ],
      ),
    );
  }
}

/// The slim bar along the bottom (controls: Always): what's playing,
/// previous, play / pause, next.
class _ControlBar extends StatelessWidget {
  const _ControlBar();

  @override
  Widget build(BuildContext context) {
    final p = AppScope.of(context).player;
    final song = p.current;
    const white = Colors.white;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0xC0000000)],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 12, 10),
          child: Row(
            children: [
              if (song != null) ...[
                Art(albumId: song.albumId, size: 52, radius: 8),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: white, fontSize: 18, fontWeight: FontWeight.w600),
                      ),
                      Text(
                        song.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white70, fontSize: 15),
                      ),
                    ],
                  ),
                ),
              ] else
                const Spacer(),
              BigIconButton(
                icon: Icons.skip_previous_rounded,
                size: 60,
                color: white,
                tooltip: 'Previous',
                onTap: p.previous,
              ),
              const PlayPauseButton(size: 64, background: Colors.white24, foreground: white),
              BigIconButton(
                icon: Icons.skip_next_rounded,
                size: 60,
                color: white,
                tooltip: 'Next',
                onTap: p.next,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Visualiser options (here and in Settings): clock, controls, song title,
/// changing style by itself.
class VizOptions extends StatelessWidget {
  const VizOptions({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).settings;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.schedule_rounded),
            title: const Text('Clock'),
            subtitle: const Text('Each style puts it where it fits'),
            value: s.vizClock,
            onChanged: (v) => s.vizClock = v,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.title_rounded),
            title: const Text('Show the song when it changes'),
            subtitle: const Text('Title and artist for a few seconds, with the controls to skip it'),
            value: s.vizSongTitle,
            onChanged: (v) => s.vizSongTitle = v,
          ),
          ListTile(
            leading: const Icon(Icons.smart_button_rounded),
            title: const Text('Play controls'),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SegmentedButton<VizControls>(
                showSelectedIcon: false,
                segments: [for (final v in VizControls.values) ButtonSegment(value: v, label: Text(v.label))],
                selected: {s.vizControls},
                onSelectionChanged: (v) => s.vizControls = v.first,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.shuffle_rounded),
            title: const Text('Change style by itself'),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SegmentedButton<VizCycle>(
                showSelectedIcon: false,
                segments: [for (final v in VizCycle.values) ButtonSegment(value: v, label: Text(v.label))],
                selected: {s.vizCycle},
                onSelectionChanged: (v) => s.vizCycle = v.first,
              ),
            ),
          ),
          if (s.vizCycle == VizCycle.timer)
            ListTile(
              leading: const SizedBox(width: 24),
              title: Text('Every ${s.vizCycleMinutes} ${s.vizCycleMinutes == 1 ? 'minute' : 'minutes'}'),
              subtitle: Slider(
                min: 1,
                max: 15,
                divisions: 14,
                value: s.vizCycleMinutes.toDouble().clamp(1, 15),
                onChanged: (v) => s.vizCycleMinutes = v.round(),
              ),
            ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}
