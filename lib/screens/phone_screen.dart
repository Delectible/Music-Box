import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/format.dart';
import '../core/native.dart';
import '../core/phone.dart';
import '../core/scope.dart';
import '../core/theme.dart';
import '../widgets/art.dart';
import '../widgets/controls.dart';

void openPhone(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PhoneScreen()));

/// The top bar's phone button: lit while the phone is playing.
class PhoneButton extends StatelessWidget {
  const PhoneButton({super.key});

  @override
  Widget build(BuildContext context) {
    final link = PhoneLink.instance;
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: link,
      builder: (context, _) {
        if (!link.supported) return const SizedBox.shrink();
        final t = link.current;
        final on = t != null && t.playing;
        return IconButton(
          iconSize: 28,
          padding: const EdgeInsets.all(12),
          tooltip: 'Phone (Bluetooth)',
          color: on ? cs.primary : null,
          icon: Icon(on ? Icons.bluetooth_audio_rounded : Icons.bluetooth_rounded),
          onPressed: () => openPhone(context),
        );
      },
    );
  }
}

/// The phone's now playing, through the head unit's Bluetooth: cover,
/// titles, progress and controls, like Roadie's own player. With nothing
/// found yet, every way of connecting, to try one by one.
class PhoneScreen extends StatefulWidget {
  const PhoneScreen({super.key});

  @override
  State<PhoneScreen> createState() => _PhoneScreenState();
}

class _PhoneScreenState extends State<PhoneScreen> with WidgetsBindingObserver {
  final _link = PhoneLink.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_link.start().then((_) => _link.askBluetooth()));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Back from Android's settings (notification access): look again.
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) unawaited(_link.refresh());
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _link,
      builder: (context, _) {
        final t = _link.current;
        return Scaffold(
          backgroundColor: Theme.of(context).colorScheme.surface,
          body: Stack(
            fit: StackFit.expand,
            children: [
              if (t != null) _Backdrop(path: _link.artFor(t)),
              SafeArea(
                child: Column(
                  children: [
                    _Bar(track: t),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: motion(AppScope.of(context).settings, 300),
                        child: t == null
                            ? const _Setup(key: ValueKey('setup'))
                            : _Player(key: const ValueKey('player'), track: t),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Bar extends StatelessWidget {
  final PhoneTrack? track;
  const _Bar({required this.track});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = track;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 8, 0),
      child: Row(
        children: [
          IconButton(
            iconSize: 32,
            padding: const EdgeInsets.all(12),
            tooltip: 'Back',
            icon: const Icon(Icons.keyboard_arrow_down_rounded),
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 4),
          Icon(Icons.bluetooth_audio_rounded, color: cs.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              t == null ? 'Phone' : (t.label.isEmpty ? 'Phone' : t.label),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ),
          if (t != null)
            IconButton(
              iconSize: 28,
              padding: const EdgeInsets.all(12),
              tooltip: 'Connection',
              icon: const Icon(Icons.settings_input_antenna_rounded),
              onPressed: () => _showSetup(context),
            ),
        ],
      ),
    );
  }
}

void _showSetup(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  constraints: const BoxConstraints(maxWidth: 820),
  builder: (_) => const FractionallySizedBox(heightFactor: 0.9, child: _Setup(inSheet: true)),
);

/// The cover, small and blurred, filling the screen behind everything.
class _Backdrop extends StatelessWidget {
  final String? path;
  const _Backdrop({required this.path});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final p = path;
    return AnimatedSwitcher(
      duration: motion(AppScope.of(context).settings, 450),
      layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
      child: p == null
          ? ColoredBox(key: const ValueKey('none'), color: cs.surface)
          : Stack(
              key: ValueKey(p),
              fit: StackFit.expand,
              children: [
                // Decoded tiny and scaled up: a cheap blur for head units.
                ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24, tileMode: TileMode.clamp),
                  child: Image.file(
                    File(p),
                    fit: BoxFit.cover,
                    cacheWidth: 64,
                    filterQuality: FilterQuality.low,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) => const SizedBox(),
                  ),
                ),
                ColoredBox(color: cs.surface.withValues(alpha: 0.62)),
              ],
            ),
    );
  }
}

class _Player extends StatefulWidget {
  final PhoneTrack track;
  const _Player({super.key, required this.track});

  @override
  State<_Player> createState() => _PlayerState();
}

class _PlayerState extends State<_Player> {
  Timer? _tick;
  double? _dragging; // 0..1 while the finger is on the bar

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted && widget.track.playing && _dragging == null) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _toggle() {
    final t = widget.track;
    final scope = AppScope.of(context);
    // Both at once would talk over each other.
    if (!t.playing && scope.player.playing) unawaited(scope.player.pause());
    unawaited(PhoneLink.instance.toggle());
    unawaited(HapticFeedback.selectionClick());
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.track;
    final link = PhoneLink.instance;
    final s = AppScope.of(context).settings;
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth > box.maxHeight * 1.1;
        final b = s.buttonSize;
        final coverSize = wide
            ? (box.maxHeight - 32).clamp(120.0, box.maxWidth * 0.44)
            : (box.maxWidth - 64).clamp(120.0, box.maxHeight * 0.48);
        final cover = AnimatedSwitcher(
          duration: motion(s, 350),
          transitionBuilder: (child, a) => FadeTransition(
            opacity: a,
            child: ScaleTransition(scale: Tween(begin: 0.94, end: 1.0).animate(a), child: child),
          ),
          child: GestureDetector(
            key: ValueKey('${t.title}|${link.artFor(t)}'),
            onTap: _toggle,
            onHorizontalDragEnd: (d) {
              final v = d.primaryVelocity ?? 0;
              if (v < -400) unawaited(link.next());
              if (v > 400) unawaited(link.previous());
            },
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(coverSize * 0.06),
                boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 30, offset: Offset(0, 10))],
              ),
              child: Art(
                albumId: '${t.artist}|${t.album}'.hashCode,
                size: coverSize,
                file: link.artFor(t),
                radius: coverSize * 0.06,
              ),
            ),
          ),
        );
        final dur = t.duration;
        final pos = t.now;
        final frac = _dragging ?? (dur.inMilliseconds == 0 ? 0.0 : pos.inMilliseconds / dur.inMilliseconds);
        final titles = AnimatedSwitcher(
          duration: motion(s, 300),
          layoutBuilder: (current, previous) => Stack(
            alignment: wide ? Alignment.centerLeft : Alignment.center,
            children: [...previous, ?current],
          ),
          child: Column(
            key: ValueKey(t.title + t.artist),
            crossAxisAlignment: wide ? CrossAxisAlignment.start : CrossAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                t.title.isEmpty ? 'Nothing playing' : t.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: wide ? TextAlign.start : TextAlign.center,
                style: TextStyle(fontSize: wide ? 34 : 28, fontWeight: FontWeight.w600, height: 1.1),
              ),
              const SizedBox(height: 8),
              if (t.artist.isNotEmpty)
                Text(
                  t.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: wide ? 21 : 18, color: cs.primary, fontWeight: FontWeight.w500),
                ),
              if (t.album.isNotEmpty)
                Text(
                  t.album,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: wide ? 17 : 15, color: cs.onSurfaceVariant),
                ),
            ],
          ),
        );
        final seek = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 6,
                thumbShape: RoundSliderThumbShape(enabledThumbRadius: t.canSeek ? 9 : 0),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 22),
                disabledActiveTrackColor: cs.primary,
                disabledInactiveTrackColor: cs.onSurface.withValues(alpha: 0.15),
              ),
              child: Slider(
                value: frac.clamp(0.0, 1.0),
                onChanged: t.canSeek ? (v) => setState(() => _dragging = v) : null,
                onChangeEnd: t.canSeek
                    ? (v) {
                        unawaited(link.seek(dur * v));
                        setState(() => _dragging = null);
                      }
                    : null,
              ),
            ),
            if (dur > Duration.zero)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  children: [
                    Text(clock(_dragging == null ? pos : dur * _dragging!), style: _figures(cs)),
                    const Spacer(),
                    Text(clock(dur), style: _figures(cs)),
                  ],
                ),
              ),
          ],
        );
        final transport = Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            BigIconButton(
              icon: Icons.skip_previous_rounded,
              size: b,
              tooltip: 'Previous',
              onTap: link.previous,
            ),
            SizedBox(width: b * 0.3),
            Material(
              color: cs.primary,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _toggle,
                child: SizedBox.square(
                  dimension: b * 1.35,
                  child: AnimatedSwitcher(
                    duration: motion(s, 200),
                    transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                    child: Icon(
                      t.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      key: ValueKey(t.playing),
                      size: b * 0.75,
                      color: cs.onPrimary,
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(width: b * 0.3),
            BigIconButton(icon: Icons.skip_next_rounded, size: b, tooltip: 'Next', onTap: link.next),
          ],
        );
        final via = Text(
          link.controlVia(t) == PhoneVia.keys && t.via != PhoneVia.broadcast
              ? t.via.label
              : '${t.via.label}${t.via == PhoneVia.broadcast ? ' · buttons as media keys' : ''}',
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
        );
        if (wide) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(32, 0, 32, 16),
            child: Row(
              children: [
                cover,
                const SizedBox(width: 40),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Align(alignment: Alignment.centerLeft, child: titles),
                      seek,
                      transport,
                      Center(child: via),
                    ],
                  ),
                ),
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Flexible(child: FittedBox(child: cover)),
              titles,
              seek,
              transport,
              via,
            ],
          ),
        );
      },
    );
  }

  static TextStyle _figures(ColorScheme cs) =>
      TextStyle(fontSize: 15, color: cs.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()]);
}

/// Every way of reaching the phone, best first, each with what it found.
class _Setup extends StatelessWidget {
  final bool inSheet;
  const _Setup({super.key, this.inSheet = false});

  static const adb =
      'adb shell cmd notification allow_listener com.dingo.roadie/com.dingo.roadie.MediaListener';

  @override
  Widget build(BuildContext context) {
    final link = PhoneLink.instance;
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: link,
      builder: (context, _) {
        final cur = link.current;
        final using = cur?.via;
        Widget step(int n, PhoneVia? via, String title, String detail, List<Widget> body, {bool ok = false}) {
          final active = via != null && via == using;
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            color: active ? cs.primaryContainer : cs.surfaceContainerHigh,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 15,
                        backgroundColor: ok || active ? cs.primary : cs.surfaceContainerHighest,
                        child: ok || active
                            ? Icon(Icons.check_rounded, size: 18, color: cs.onPrimary)
                            : Text('$n', style: const TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                      ),
                      if (active)
                        Chip(
                          label: const Text('In use'),
                          visualDensity: VisualDensity.compact,
                          backgroundColor: cs.primary,
                          labelStyle: TextStyle(color: cs.onPrimary),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.only(left: 42),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(detail, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14)),
                        const SizedBox(height: 8),
                        ...body,
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        Widget pick(String title, String sub, bool selected, VoidCallback onTap) => ListTile(
          contentPadding: EdgeInsets.zero,
          minTileHeight: 56,
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: sub.isEmpty ? null : Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: Icon(
            selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
            color: selected ? cs.primary : null,
          ),
          onTap: onTap,
        );

        String trackLine(PhoneTrack s) => [
          if (s.playing) 'Playing',
          if (s.title.isNotEmpty) s.title,
          if (s.artist.isNotEmpty) s.artist,
        ].join(' · ');

        final sessions = link.sessions.where((s) => s.via == PhoneVia.session).toList();
        final browsed = link.sessions.where((s) => s.via == PhoneVia.browser).firstOrNull;
        final note = TextStyle(color: cs.onSurfaceVariant, fontSize: 14);

        return ListView(
          padding: EdgeInsets.fromLTRB(20, inSheet ? 0 : 8, 20, 24),
          children: [
            if (!inSheet) ...[
              Text(
                'Play music on your phone through the car\'s Bluetooth, and Roadie shows it here with '
                'its controls. Try these from the top; the first that works is used.',
                style: TextStyle(fontSize: 16, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
            ] else
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text('Connection', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
              ),
            step(
              1,
              PhoneVia.session,
              'Media sessions',
              'Best: song, artist, album, cover, position and every button, from any app '
                  '(the Bluetooth app, or others on this screen). Android calls the permission '
                  '"notification access"; Roadie only reads what\'s playing.',
              [
                if (!link.access) ...[
                  FilledButton.icon(
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 56)),
                    onPressed: () async {
                      final ok = await link.openAccess();
                      if (!ok && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('This head unit hides that setting: see below.')),
                        );
                      }
                    },
                    icon: const Icon(Icons.lock_open_rounded),
                    label: const Text('Allow access'),
                  ),
                  const SizedBox(height: 8),
                  Text('If the setting is missing, from a computer run:', style: note),
                  const SizedBox(height: 4),
                  const SelectableText(adb, style: TextStyle(fontFamily: 'monospace', fontSize: 13)),
                ] else if (sessions.isEmpty)
                  Text('Allowed. Nothing playing yet: start something on the phone.', style: note)
                else
                  for (final s in sessions)
                    pick(s.label, trackLine(s), cur?.key == s.key, () => link.choose(s.key)),
              ],
              ok: link.access,
            ),
            step(
              2,
              PhoneVia.browser,
              'Direct link',
              'Connects straight to an app\'s player: full info and buttons, no permission. '
                  'Pick the Bluetooth music app if it\'s listed.',
              [
                if (link.browsers.isEmpty)
                  Text('No app here offers one.', style: note)
                else ...[
                  for (final b in link.browsers)
                    pick(
                      b.label,
                      link.browserApp == b.app
                          ? '${link.browserState}${browsed != null ? ' · ${trackLine(browsed)}' : ''}'
                          : b.app,
                      link.browserApp == b.app,
                      () => link.link(link.browserApp == b.app ? null : b),
                    ),
                ],
              ],
              ok: browsed != null,
            ),
            step(
              3,
              PhoneVia.broadcast,
              'Track broadcasts',
              'Some Bluetooth apps announce each new song. '
                  'Info only; the buttons go as media keys.',
              [
                Text(
                  link.broadcastRaw.isEmpty ? 'None heard yet.' : 'Last heard: ${link.broadcastRaw}',
                  style: note,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
            step(
              4,
              null,
              'Media keys',
              'Sends play / pause / skip to whatever is playing, like a steering '
                  'wheel button. Buttons only; try them now:',
              [
                Row(
                  children: [
                    BigIconButton(
                      icon: Icons.skip_previous_rounded,
                      size: 56,
                      onTap: () => link.key('previous'),
                    ),
                    BigIconButton(icon: Icons.play_arrow_rounded, size: 56, onTap: () => link.key('toggle')),
                    BigIconButton(icon: Icons.skip_next_rounded, size: 56, onTap: () => link.key('next')),
                  ],
                ),
              ],
            ),
            step(
              5,
              null,
              'The head unit\'s own app',
              'Open it to connect or start playback (then come back).',
              [
                if (link.apps.isEmpty)
                  Text('None found.', style: note)
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final a in link.apps.take(8))
                        ActionChip(
                          avatar: Icon(
                            a.bluetooth ? Icons.bluetooth_rounded : Icons.music_note_rounded,
                            size: 18,
                          ),
                          label: Text(a.label),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                          onPressed: () => link.launch(a.app),
                        ),
                    ],
                  ),
              ],
            ),
            step(
              6,
              null,
              'Scan the head unit',
              'Looks for private ways this head unit\'s Bluetooth app talks (its own signals, services '
                  'and settings) and listens while the phone plays, to find another way in.',
              [
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 56)),
                  onPressed: () => Navigator.of(
                    context,
                  ).push(MaterialPageRoute<void>(builder: (_) => const HeadUnitScanScreen())),
                  icon: const Icon(Icons.manage_search_rounded),
                  label: const Text('Scan'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Bluetooth says',
              style: TextStyle(fontWeight: FontWeight.w600, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            for (final l in link.bluetoothLines) Text(l, style: note),
            const SizedBox(height: 12),
            Text(
              'Android doesn\'t let apps receive a phone\'s Bluetooth audio themselves, so the sound keeps '
              'coming through the head unit\'s Bluetooth app; Roadie shows and controls it.',
              style: note,
            ),
          ],
        );
      },
    );
  }
}

/// Looks through the head unit for private ways its Bluetooth app talks
/// (HeadUnitScan.kt), and listens for its broadcasts while the phone plays.
class HeadUnitScanScreen extends StatefulWidget {
  const HeadUnitScanScreen({super.key});

  @override
  State<HeadUnitScanScreen> createState() => _HeadUnitScanScreenState();
}

class _HeadUnitScanScreenState extends State<HeadUnitScanScreen> {
  static const _ch = MethodChannel('roadie/phone');
  String? _report;
  bool _scanning = false;
  bool _listening = false;
  List<String> _heard = const [];
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    unawaited(_scan());
  }

  @override
  void dispose() {
    _poll?.cancel();
    if (_listening) {
      unawaited(_ch.invokeMethod<bool>('listen', {'on': false}).catchError((Object _) => false));
    }
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() => _scanning = true);
    String text;
    try {
      text = await _ch.invokeMethod<String>('scan') ?? 'Nothing to scan here.';
    } on Object catch (e) {
      text = 'Scan failed: $e';
    }
    if (mounted) setState(() => (_report = text, _scanning = false));
  }

  Future<void> _listen(bool on) async {
    try {
      await _ch.invokeMethod<bool>('listen', {'on': on});
    } on Object {
      return;
    }
    _poll?.cancel();
    if (on) {
      _poll = Timer.periodic(const Duration(seconds: 1), (_) async {
        final h = (await _ch.invokeMethod<List<Object?>>('heard'))?.cast<String>() ?? const [];
        if (mounted && h.length != _heard.length) setState(() => _heard = h);
      });
    }
    setState(() => _listening = on);
  }

  String get _all => [
    'Roadie head unit scan',
    if (_heard.isNotEmpty) ...['', '== Heard ==', ..._heard],
    _report ?? '',
  ].join('\n');

  Future<void> _save() async {
    final roots = await Native.roots();
    final f = File('${roots.first}/Roadie-bluetooth-scan.txt');
    var msg = 'Saved to ${f.path}';
    try {
      await f.writeAsString(_all);
    } on Object catch (e) {
      msg = 'Couldn\'t save: $e';
    }
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const mono = TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.3);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan the head unit'),
        toolbarHeight: 64,
        actions: [
          IconButton(
            iconSize: 28,
            padding: const EdgeInsets.all(12),
            tooltip: 'Copy',
            icon: const Icon(Icons.copy_rounded),
            onPressed: _report == null
                ? null
                : () {
                    unawaited(Clipboard.setData(ClipboardData(text: _all)));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
                  },
          ),
          IconButton(
            iconSize: 28,
            padding: const EdgeInsets.all(12),
            tooltip: 'Save as a file',
            icon: const Icon(Icons.save_alt_rounded),
            onPressed: _report == null ? null : _save,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          Text(
            'Looks for private ways the head unit\'s Bluetooth app talks to the rest of the system. '
            'Turn on Listen, then play, pause and skip on the phone; anything heard shows below. '
            'Then save it (or take photos) and send it over.',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 15),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size(0, 56)),
                onPressed: () => _listen(!_listening),
                icon: Icon(_listening ? Icons.stop_rounded : Icons.hearing_rounded),
                label: Text(_listening ? 'Stop listening' : 'Listen'),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 56)),
                onPressed: _scanning ? null : _scan,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(_scanning ? 'Scanning…' : 'Scan again'),
              ),
            ],
          ),
          if (_listening || _heard.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              'Heard (${_heard.length})',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText(
                _heard.isEmpty ? 'Nothing yet…' : _heard.reversed.join('\n'),
                style: mono,
              ),
            ),
          ],
          const SizedBox(height: 16),
          if (_report == null)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          else
            SelectableText(_report!, style: mono),
        ],
      ),
    );
  }
}
