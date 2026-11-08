import 'package:flutter/material.dart';

import '../core/library.dart';
import '../core/scope.dart';
import '../core/settings.dart';
import '../core/sorting.dart';
import '../core/theme.dart';
import '../widgets/mini_player.dart';
import 'get_music_screen.dart';
import 'library_view.dart';
import 'search_screen.dart';
import 'settings_screen.dart';
import 'visualizer_screen.dart';

IconData tabIcon(LibraryTab t, {bool selected = false}) => switch (t) {
  LibraryTab.songs => Icons.music_note_rounded,
  LibraryTab.albums => Icons.album_rounded,
  LibraryTab.artists => selected ? Icons.person_rounded : Icons.person_outline_rounded,
  LibraryTab.genres => Icons.category_rounded,
  LibraryTab.years => Icons.calendar_month_rounded,
  LibraryTab.folders => selected ? Icons.folder_rounded : Icons.folder_outlined,
  LibraryTab.playlists => Icons.queue_music_rounded,
  LibraryTab.podcasts => Icons.podcasts_rounded,
  LibraryTab.get => Icons.download_rounded,
};

/// The library: tabs down the side on a wide (car) screen, along the
/// bottom on a phone; the mini player under everything.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  LibraryTab _tab = LibraryTab.songs;
  late final _fade = AnimationController(vsync: this, duration: const Duration(milliseconds: 260), value: 1);

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  void _select(LibraryTab t) {
    if (t == _tab) return;
    setState(() => _tab = t);
    _fade.duration = motion(AppScope.of(context).settings, 260);
    _fade.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([scope.settings, scope.library]),
      builder: (context, _) {
        final s = scope.settings;
        final tabs = s.tabs.isEmpty ? [LibraryTab.songs] : s.tabs;
        if (!tabs.contains(_tab)) _tab = tabs.first;
        final size = MediaQuery.sizeOf(context);
        final rail = switch (s.nav) {
          NavStyle.rail => true,
          NavStyle.bottom => false,
          NavStyle.auto => size.width > size.height,
        };
        final i = tabs.indexOf(_tab);
        final body = Column(
          children: [
            _Header(tab: _tab, showActions: !rail),
            Expanded(child: _content(tabs)),
            const MiniPlayer(),
          ],
        );
        if (rail) {
          return Scaffold(
            body: SafeArea(
              bottom: false,
              child: Row(
                children: [
                  _Rail(tabs: tabs, index: i, onSelect: (n) => _select(tabs[n])),
                  Expanded(child: body),
                ],
              ),
            ),
          );
        }
        return Scaffold(
          body: SafeArea(bottom: false, child: body),
          bottomNavigationBar: NavigationBar(
            selectedIndex: i,
            height: 68,
            labelBehavior: tabs.length > 5
                ? NavigationDestinationLabelBehavior.onlyShowSelected
                : NavigationDestinationLabelBehavior.alwaysShow,
            onDestinationSelected: (n) => _select(tabs[n]),
            destinations: [
              for (final t in tabs)
                NavigationDestination(
                  icon: Icon(tabIcon(t)),
                  selectedIcon: Icon(tabIcon(t, selected: true)),
                  label: t.label,
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _content(List<LibraryTab> tabs) {
    final scope = AppScope.of(context);
    final lib = scope.library;
    if (_tab != LibraryTab.get && lib.state == LibraryState.needsPermission) return const _AskPermission();
    if (_tab != LibraryTab.get && lib.state != LibraryState.ready) {
      return const Center(child: CircularProgressIndicator());
    }
    return FadeTransition(
      opacity: CurvedAnimation(parent: _fade, curve: Curves.easeOut),
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, 0.02),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: _fade, curve: Curves.easeOutCubic)),
        child: IndexedStack(
          index: tabs.indexOf(_tab),
          children: [
            for (final t in tabs)
              t == LibraryTab.get ? const GetMusicScreen() : LibraryView(key: PageStorageKey(t), tab: t),
          ],
        ),
      ),
    );
  }
}

class _Rail extends StatelessWidget {
  final List<LibraryTab> tabs;
  final int index;
  final ValueChanged<int> onSelect;
  const _Rail({required this.tabs, required this.index, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, box) {
        // Labels only when there's room for them.
        final room = box.maxHeight > tabs.length * 76 + 160;
        return Container(
          color: cs.surfaceContainerLow,
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: box.maxHeight),
              child: IntrinsicHeight(
                child: NavigationRail(
                  backgroundColor: Colors.transparent,
                  selectedIndex: index,
                  onDestinationSelected: onSelect,
                  labelType: room ? NavigationRailLabelType.all : NavigationRailLabelType.none,
                  minWidth: 92,
                  groupAlignment: -0.9,
                  leading: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: IconButton.filledTonal(
                      iconSize: 30,
                      padding: const EdgeInsets.all(14),
                      tooltip: 'Search',
                      icon: const Icon(Icons.search_rounded),
                      onPressed: () => openSearch(context),
                    ),
                  ),
                  trailing: Expanded(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: IconButton(
                          iconSize: 30,
                          padding: const EdgeInsets.all(14),
                          tooltip: 'Settings',
                          icon: const Icon(Icons.settings_rounded),
                          onPressed: () => openSettings(context),
                        ),
                      ),
                    ),
                  ),
                  destinations: [
                    for (final t in tabs)
                      NavigationRailDestination(
                        icon: Icon(tabIcon(t), size: 30),
                        selectedIcon: Icon(tabIcon(t, selected: true), size: 30),
                        label: Text(t.label),
                        padding: const EdgeInsets.symmetric(vertical: 4),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  final LibraryTab tab;
  final bool showActions;
  const _Header({required this.tab, required this.showActions});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: AnimatedSwitcher(
              layoutBuilder: (current, previous) =>
                  Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
              duration: motion(AppScope.of(context).settings, 200),
              child: Text(
                tab.label,
                key: ValueKey(tab),
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ),
          if (tab != LibraryTab.get)
            IconButton(
              iconSize: 28,
              padding: const EdgeInsets.all(12),
              tooltip: 'Sort and view',
              icon: const Icon(Icons.tune_rounded),
              onPressed: () => showViewOptions(context, tab),
            ),
          IconButton(
            iconSize: 28,
            padding: const EdgeInsets.all(12),
            tooltip: 'Visualiser',
            icon: const Icon(Icons.graphic_eq_rounded),
            onPressed: () => openVisualizer(context),
          ),
          if (showActions) ...[
            IconButton(
              iconSize: 28,
              padding: const EdgeInsets.all(12),
              tooltip: 'Search',
              icon: const Icon(Icons.search_rounded),
              onPressed: () => openSearch(context),
            ),
            IconButton(
              iconSize: 28,
              padding: const EdgeInsets.all(12),
              tooltip: 'Settings',
              icon: const Icon(Icons.settings_rounded),
              onPressed: () => openSettings(context),
            ),
          ],
        ],
      ),
    );
  }
}

class _AskPermission extends StatelessWidget {
  const _AskPermission();

  @override
  Widget build(BuildContext context) {
    final lib = AppScope.of(context).library;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.library_music_rounded, size: 72, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text('Let Roadie see your music', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            const Text('It reads the songs on this device. Nothing leaves it.', textAlign: TextAlign.center),
            const SizedBox(height: 24),
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(220, 60)),
              onPressed: () => lib.load(ask: true),
              icon: const Icon(Icons.check_rounded),
              label: const Text('Allow'),
            ),
          ],
        ),
      ),
    );
  }
}
