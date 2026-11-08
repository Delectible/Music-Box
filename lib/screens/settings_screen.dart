import 'package:flutter/material.dart';

import '../core/app_info.dart';
import '../core/scope.dart';
import '../core/levelling.dart';
import '../core/settings.dart';
import 'duplicates_screen.dart';
import 'fix_tags_sheet.dart';
import 'folders_screen.dart';
import 'get_music_screen.dart';
import 'home_screen.dart';
import 'problems_screen.dart';

void openSettings(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final s = scope.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: s,
        builder: (context, _) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: ListView(
              padding: const EdgeInsets.only(bottom: 40),
              children: [
                const _Section('Look'),
                _Choice<ThemeChoice>(
                  icon: Icons.dark_mode_rounded,
                  title: 'Theme',
                  value: s.theme,
                  values: ThemeChoice.values,
                  label: (v) => v.label,
                  onChanged: (v) => s.theme = v,
                ),
                if (s.theme == ThemeChoice.dayNight) ...[
                  _Slider(
                    icon: Icons.wb_sunny_rounded,
                    title: 'Day starts at',
                    value: s.dayStarts.toDouble(),
                    min: 4,
                    max: 11,
                    divisions: 7,
                    label: '${s.dayStarts}:00',
                    onChanged: (v) => s.dayStarts = v.round(),
                  ),
                  _Slider(
                    icon: Icons.nightlight_round,
                    title: 'Night starts at',
                    value: s.nightStarts.toDouble(),
                    min: 16,
                    max: 23,
                    divisions: 7,
                    label: '${s.nightStarts}:00',
                    onChanged: (v) => s.nightStarts = v.round(),
                  ),
                  _Switch(
                    icon: Icons.contrast_rounded,
                    title: 'All black at night',
                    subtitle: 'Darkest for night driving',
                    value: s.nightBlack,
                    onChanged: (v) => s.nightBlack = v,
                  ),
                ],
                ListTile(
                  leading: const Icon(Icons.palette_rounded),
                  title: const Text('Accent colour'),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        _Swatch(
                          selected: s.accent == null,
                          onTap: () => s.accent = null,
                          child: const Icon(Icons.auto_awesome_rounded, size: 22),
                        ),
                        for (final c in accents)
                          _Swatch(
                            color: c,
                            selected: s.accent?.toARGB32() == c.toARGB32(),
                            onTap: () => s.accent = c,
                          ),
                      ],
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(72, 0, 16, 8),
                  child: Text('✦ takes the colour from the playing cover', style: TextStyle(fontSize: 13)),
                ),
                _Slider(
                  icon: Icons.format_size_rounded,
                  title: 'Text size',
                  value: s.textScale,
                  min: 0.9,
                  max: 1.6,
                  divisions: 7,
                  label: '${(s.textScale * 100).round()}%',
                  onChanged: (v) => s.textScale = v,
                ),
                _Choice<ArtShape>(
                  icon: Icons.crop_square_rounded,
                  title: 'Cover shape',
                  value: s.artShape,
                  values: ArtShape.values,
                  label: (v) => v.label,
                  onChanged: (v) => s.artShape = v,
                ),
                _Choice<NavStyle>(
                  icon: Icons.view_sidebar_rounded,
                  title: 'Navigation',
                  value: s.nav,
                  values: NavStyle.values,
                  label: (v) => v.label,
                  onChanged: (v) => s.nav = v,
                ),
                _Choice<BarsMode>(
                  icon: Icons.fullscreen_rounded,
                  title: 'Full screen',
                  value: s.bars,
                  values: BarsMode.values,
                  label: (v) => v.label,
                  onChanged: (v) => s.bars = v,
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(72, 0, 16, 8),
                  child: Text(
                    'Swipe in from the edge to bring hidden bars back for a moment',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
                _Switch(
                  icon: Icons.animation_rounded,
                  title: 'Animations',
                  value: s.animations,
                  onChanged: (v) => s.animations = v,
                ),
                _Switch(
                  icon: Icons.favorite_rounded,
                  title: 'Favourites shelf',
                  subtitle: 'Above Songs, one tap to play',
                  value: s.favouritesShelf,
                  onChanged: (v) => s.favouritesShelf = v,
                ),
                const _Section('Player'),
                _Choice<PlayerStyle>(
                  icon: Icons.dashboard_customize_rounded,
                  title: 'Full screen player',
                  value: s.playerStyle,
                  values: PlayerStyle.values,
                  label: (v) => v.label,
                  onChanged: (v) => s.playerStyle = v,
                ),
                _Slider(
                  icon: Icons.touch_app_rounded,
                  title: 'Button size',
                  value: s.buttonSize,
                  min: 64,
                  max: 120,
                  divisions: 7,
                  label: '${s.buttonSize.round()}',
                  onChanged: (v) => s.buttonSize = v,
                ),
                _Switch(
                  icon: Icons.open_in_full_rounded,
                  title: 'Open the player when a song starts',
                  value: s.openPlayerOnPlay,
                  onChanged: (v) => s.openPlayerOnPlay = v,
                ),
                _Switch(
                  icon: Icons.swipe_rounded,
                  title: 'Swipe sideways to skip',
                  value: s.swipeToSkip,
                  onChanged: (v) => s.swipeToSkip = v,
                ),
                _Switch(
                  icon: Icons.light_mode_rounded,
                  title: 'Keep the screen on in the player',
                  value: s.keepScreenOn,
                  onChanged: (v) => s.keepScreenOn = v,
                ),
                _Switch(
                  icon: Icons.schedule_rounded,
                  title: 'Show the clock',
                  subtitle: 'In the player on wide (car) screens',
                  value: s.showClock,
                  onChanged: (v) => s.showClock = v,
                ),
                _Switch(
                  icon: Icons.blur_on_rounded,
                  title: 'Blurred cover behind the player',
                  value: s.blurBackground,
                  onChanged: (v) => s.blurBackground = v,
                ),
                _Switch(
                  icon: Icons.replay_rounded,
                  title: 'Previous restarts the song first',
                  subtitle: 'After the first 3 seconds',
                  value: s.previousRestarts,
                  onChanged: (v) => s.previousRestarts = v,
                ),
                _Switch(
                  icon: Icons.play_circle_outline_rounded,
                  title: 'Resume playing when the app opens',
                  subtitle: 'The last song, from where it stopped. Handy when the car starts',
                  value: s.resumeOnStart,
                  onChanged: (v) => s.resumeOnStart = v,
                ),
                _Switch(
                  icon: Icons.open_in_full_rounded,
                  title: 'Open the full screen player when the app opens',
                  value: s.openPlayerOnStart,
                  onChanged: (v) => s.openPlayerOnStart = v,
                ),
                _Switch(
                  icon: Icons.lyrics_rounded,
                  title: 'Lyrics',
                  subtitle: 'Synced lyrics from LRCLIB (or a .lrc file next to the song)',
                  value: s.lyrics,
                  onChanged: (v) => s.lyrics = v,
                ),
                const _Section('Sound'),
                _Choice<LevelMode>(
                  icon: Icons.equalizer_rounded,
                  title: 'Volume levelling',
                  value: s.levelMode,
                  values: LevelMode.values,
                  label: (v) => v.label,
                  onChanged: (v) => s.levelMode = v,
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(72, 0, 16, 8),
                  child: Text(
                    'Every song at the same loudness. Uses ReplayGain tags, or measures the song once.',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
                if (s.levelMode != LevelMode.off)
                  _Slider(
                    icon: Icons.volume_up_rounded,
                    title: 'Extra volume',
                    value: s.preamp,
                    min: -6,
                    max: 6,
                    divisions: 12,
                    label: '${s.preamp > 0 ? '+' : ''}${s.preamp.round()} dB',
                    onChanged: (v) => s.preamp = v,
                  ),
                _Slider(
                  icon: Icons.compare_arrows_rounded,
                  title: 'Crossfade',
                  value: s.crossfade.toDouble(),
                  min: 0,
                  max: 12,
                  divisions: 12,
                  label: s.crossfade == 0 ? 'Off' : '${s.crossfade} s',
                  onChanged: (v) => s.crossfade = v.round(),
                ),
                if (s.crossfade > 0)
                  _Switch(
                    icon: Icons.album_rounded,
                    title: 'Play albums straight through',
                    subtitle: 'No fade between tracks that follow on (live albums, mixes)',
                    value: s.albumGapless,
                    onChanged: (v) => s.albumGapless = v,
                  ),
                const _Section('Podcasts'),
                _Choice<double>(
                  icon: Icons.speed_rounded,
                  title: 'Speed',
                  value: s.podcastSpeed,
                  values: const [0.75, 1.0, 1.25, 1.5, 1.75, 2.0],
                  label: (v) => '${v == v.roundToDouble() ? v.toStringAsFixed(0) : v}×',
                  onChanged: (v) => s.podcastSpeed = v,
                ),
                _Switch(
                  icon: Icons.fast_forward_rounded,
                  title: 'Skip silences',
                  value: s.skipSilence,
                  onChanged: (v) => s.skipSilence = v,
                ),
                const _Section('Library'),
                ListTile(
                  leading: const Icon(Icons.tab_rounded),
                  title: const Text('Tabs'),
                  subtitle: Text(s.tabs.map((t) => t.label).join(', ')),
                  onTap: () => Navigator.of(
                    context,
                  ).push(MaterialPageRoute<void>(builder: (_) => const _TabsScreen())),
                ),
                ListTile(
                  leading: const Icon(Icons.folder_copy_rounded),
                  title: const Text('Music folders'),
                  subtitle: Text(
                    [
                      if (s.includeFolders.isEmpty)
                        'Everywhere'
                      else
                        'Only ${s.includeFolders.length} folders',
                      if (s.excludeFolders.isNotEmpty) '${s.excludeFolders.length} skipped',
                    ].join(' · '),
                  ),
                  onTap: () => Navigator.of(
                    context,
                  ).push(MaterialPageRoute<void>(builder: (_) => const MusicFoldersScreen())),
                ),
                ListTile(
                  leading: const Icon(Icons.content_copy_rounded),
                  title: const Text('Find duplicates'),
                  subtitle: const Text('The same song more than once: keep the best copy'),
                  onTap: () => openDuplicates(context),
                ),
                ListTile(
                  leading: const Icon(Icons.auto_fix_high_rounded),
                  title: const Text('Fix tags in the library'),
                  subtitle: const Text(
                    'Fills in missing titles, albums, years, genres and covers from MusicBrainz',
                  ),
                  onTap: () => fixTagsFor(context, scope.library.songs),
                ),
                _Slider(
                  icon: Icons.timer_off_rounded,
                  title: 'Hide songs shorter than',
                  value: s.minSeconds.toDouble(),
                  min: 0,
                  max: 120,
                  divisions: 8,
                  label: s.minSeconds == 0 ? 'show all' : '${s.minSeconds} s',
                  onChanged: (v) => s.minSeconds = v.round(),
                ),
                ListTile(
                  leading: const Icon(Icons.refresh_rounded),
                  title: const Text('Rescan the library'),
                  onTap: () => scope.library.load(ask: true),
                ),
                const _Section('Get music'),
                const DownloadOptions(),
                const _Section('About'),
                const ListTile(
                  leading: Icon(Icons.info_outline_rounded),
                  title: Text('${AppInfo.name} ${AppInfo.version}'),
                  subtitle: Text(AppInfo.latest),
                ),
                ListTile(
                  leading: const Icon(Icons.bug_report_rounded),
                  title: const Text('Problem reports'),
                  subtitle: const Text('Errors and crashes, to copy and send'),
                  onTap: () => Navigator.of(
                    context,
                  ).push(MaterialPageRoute<void>(builder: (_) => const ProblemsScreen())),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Reorder and hide tabs.
class _TabsScreen extends StatelessWidget {
  const _TabsScreen();

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Tabs')),
      body: ListenableBuilder(
        listenable: s,
        builder: (context, _) {
          final order = s.tabOrder;
          final shown = s.tabs.toSet();
          return ReorderableListView(
            buildDefaultDragHandles: false,
            header: const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Text('Drag to reorder. Switch off the ones you don\'t use.'),
            ),
            onReorderItem: (from, to) {
              final o = [...order];
              o.insert(to, o.removeAt(from));
              s.tabs = o.where(shown.contains).toList();
            },
            children: [
              for (var i = 0; i < order.length; i++)
                ListTile(
                  key: ValueKey(order[i]),
                  minTileHeight: 64,
                  leading: ReorderableDragStartListener(
                    index: i,
                    child: const Icon(Icons.drag_handle_rounded),
                  ),
                  title: Row(
                    children: [Icon(tabIcon(order[i])), const SizedBox(width: 16), Text(order[i].label)],
                  ),
                  trailing: Switch(
                    value: shown.contains(order[i]),
                    onChanged: (on) {
                      final next = on ? {...shown, order[i]} : ({...shown}..remove(order[i]));
                      if (next.isEmpty) return;
                      s.tabs = order.where(next.contains).toList();
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  const _Section(this.title);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 24, 20, 4),
    child: Text(
      title,
      style: TextStyle(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w600,
        fontSize: 15,
      ),
    ),
  );
}

class _Switch extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _Switch({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => SwitchListTile(
    secondary: Icon(icon),
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle!),
    value: value,
    onChanged: onChanged,
  );
}

class _Slider extends StatelessWidget {
  final IconData icon;
  final String title;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String label;
  final ValueChanged<double> onChanged;
  const _Slider({
    required this.icon,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.label,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon),
    title: Row(
      children: [
        Expanded(child: Text(title)),
        Text(label),
      ],
    ),
    subtitle: Slider(
      value: value.clamp(min, max),
      min: min,
      max: max,
      divisions: divisions,
      onChanged: onChanged,
    ),
  );
}

class _Choice<T> extends StatelessWidget {
  final IconData icon;
  final String title;
  final T value;
  final List<T> values;
  final String Function(T) label;
  final ValueChanged<T> onChanged;
  const _Choice({
    required this.icon,
    required this.title,
    required this.value,
    required this.values,
    required this.label,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon),
    title: Text(title),
    subtitle: Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final v in values)
            ChoiceChip(label: Text(label(v)), selected: v == value, onSelected: (_) => onChanged(v)),
        ],
      ),
    ),
  );
}

class _Swatch extends StatelessWidget {
  final Color? color;
  final bool selected;
  final VoidCallback onTap;
  final Widget? child;
  const _Swatch({this.color, required this.selected, required this.onTap, this.child});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkResponse(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: color ?? cs.surfaceContainerHigh,
          shape: BoxShape.circle,
          border: Border.all(color: selected ? cs.onSurface : Colors.transparent, width: 3),
        ),
        child: child,
      ),
    );
  }
}
