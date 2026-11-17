import 'package:flutter/material.dart';

import '../core/app_info.dart';
import '../core/scope.dart';
import '../core/theme.dart';
import '../core/updater.dart';

void openUpdate(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const UpdateScreen()));

/// The top bar's update button: shows only when a new build is out, with a
/// ring while it downloads.
class UpdateButton extends StatelessWidget {
  const UpdateButton({super.key});

  @override
  Widget build(BuildContext context) {
    final u = Updater.instance;
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: u,
      builder: (context, _) {
        final show = u.hasUpdate;
        return AnimatedSize(
          duration: motion(AppScope.of(context).settings, 250),
          child: !show
              ? const SizedBox.shrink()
              : Stack(
                  alignment: Alignment.center,
                  children: [
                    if (u.stage == UpdateStage.downloading)
                      SizedBox.square(
                        dimension: 44,
                        child: CircularProgressIndicator(value: u.progress, strokeWidth: 3),
                      ),
                    IconButton(
                      iconSize: 28,
                      padding: const EdgeInsets.all(12),
                      tooltip: 'Update available',
                      color: cs.primary,
                      icon: Badge(
                        isLabelVisible: u.stage != UpdateStage.downloading,
                        smallSize: 9,
                        backgroundColor: cs.primary,
                        child: const Icon(Icons.system_update_rounded),
                      ),
                      onPressed: () => openUpdate(context),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

/// What's new, the download with its progress, and the install.
class UpdateScreen extends StatefulWidget {
  const UpdateScreen({super.key});

  @override
  State<UpdateScreen> createState() => _UpdateScreenState();
}

class _UpdateScreenState extends State<UpdateScreen> {
  @override
  void initState() {
    super.initState();
    final u = Updater.instance;
    // Opened from Settings with nothing known yet: look now.
    if (u.latest == null && u.stage != UpdateStage.checking) u.check();
  }

  @override
  Widget build(BuildContext context) {
    final u = Updater.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Update'), toolbarHeight: 64),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: u,
          builder: (context, _) => LayoutBuilder(
            builder: (context, box) {
              final wide = box.maxWidth > 760;
              final status = _Status(u: u);
              final notes = _Notes(u: u);
              if (wide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: box.maxWidth * 0.42,
                      child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: status),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: notes),
                  ],
                );
              }
              return CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.all(20),
                    sliver: SliverToBoxAdapter(child: status),
                  ),
                  const SliverToBoxAdapter(child: Divider(height: 1)),
                  SliverToBoxAdapter(child: notes),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Status extends StatelessWidget {
  final Updater u;
  const _Status({required this.u});

  static String _mb(num b) => '${(b / 1048576).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final r = u.latest;
    final busy = u.stage == UpdateStage.downloading || u.stage == UpdateStage.verifying;
    final (IconData icon, String head) = switch (u.stage) {
      UpdateStage.checking => (Icons.sync_rounded, 'Looking for updates…'),
      UpdateStage.upToDate => (Icons.verified_rounded, 'Roadie is up to date'),
      UpdateStage.downloading => (Icons.downloading_rounded, 'Downloading'),
      UpdateStage.verifying => (Icons.shield_rounded, 'Checking the download'),
      UpdateStage.ready => (Icons.install_mobile_rounded, 'Ready to install'),
      UpdateStage.installing => (Icons.install_mobile_rounded, 'Follow Android\'s prompt to install'),
      UpdateStage.failed => (Icons.error_outline_rounded, 'Something went wrong'),
      _ when r != null => (Icons.system_update_rounded, 'A new version is out'),
      _ => (Icons.system_update_rounded, 'Updates'),
    };
    Widget button(String text, IconData icon, VoidCallback? onTap, {bool filled = true}) => SizedBox(
      width: double.infinity,
      height: 60,
      child: filled
          ? FilledButton.icon(onPressed: onTap, icon: Icon(icon), label: Text(text))
          : OutlinedButton.icon(onPressed: onTap, icon: Icon(icon), label: Text(text)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(20)),
              child: Icon(icon, size: 34, color: cs.onPrimaryContainer),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(head, style: tt.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        const SizedBox(height: 20),
        // This version → the new one.
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 10,
          runSpacing: 6,
          children: [
            _Chip(text: '${AppInfo.version} · build ${u.current}', color: cs.surfaceContainerHigh),
            if (r != null) ...[
              Icon(Icons.arrow_forward_rounded, color: cs.onSurfaceVariant),
              _Chip(text: r.label, color: cs.primaryContainer, bold: true),
            ],
          ],
        ),
        if (r != null) ...[
          const SizedBox(height: 10),
          Text(
            [
              if (r.size > 0) _mb(r.size),
              if (u.newer.length > 1) '${u.newer.length} builds newer than yours',
            ].join(' · '),
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 15),
          ),
        ],
        const SizedBox(height: 24),
        if (busy || u.stage == UpdateStage.installing) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: u.stage == UpdateStage.downloading ? u.progress : 1),
              duration: const Duration(milliseconds: 200),
              builder: (context, v, _) => LinearProgressIndicator(
                value: u.stage == UpdateStage.verifying ? null : v,
                minHeight: 14,
                backgroundColor: cs.surfaceContainerHighest,
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (u.stage == UpdateStage.downloading)
            Row(
              children: [
                Text(
                  '${_mb(u.received)}${r != null && r.size > 0 ? ' of ${_mb(r.size)}' : ''}',
                  style: const TextStyle(fontSize: 15, fontFeatures: [FontFeature.tabularFigures()]),
                ),
                const Spacer(),
                Text(
                  '${(u.progress * 100).round()}%'
                  '${u.speed > 0 ? ' · ${_mb(u.speed)}/s' : ''}',
                  style: const TextStyle(fontSize: 15, fontFeatures: [FontFeature.tabularFigures()]),
                ),
              ],
            ),
          const SizedBox(height: 16),
        ],
        if (u.error != null)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: (u.stage == UpdateStage.failed ? cs.errorContainer : cs.secondaryContainer),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              u.error!,
              style: TextStyle(
                color: u.stage == UpdateStage.failed ? cs.onErrorContainer : cs.onSecondaryContainer,
                fontSize: 15,
              ),
            ),
          ),
        ...switch (u.stage) {
          UpdateStage.available => [button('Download and install', Icons.download_rounded, u.download)],
          UpdateStage.downloading => [button('Cancel', Icons.close_rounded, u.cancel, filled: false)],
          UpdateStage.verifying => [button('Checking…', Icons.shield_rounded, null)],
          UpdateStage.ready ||
          UpdateStage.installing => [button('Install', Icons.install_mobile_rounded, u.install)],
          UpdateStage.failed => [
            button('Try again', Icons.refresh_rounded, r == null ? u.check : u.download),
            const SizedBox(height: 12),
            button('Open the release page', Icons.open_in_new_rounded, u.openPage, filled: false),
          ],
          UpdateStage.checking => [button('Looking…', Icons.sync_rounded, null)],
          _ => [button('Check again', Icons.refresh_rounded, u.check, filled: false)],
        },
        const SizedBox(height: 16),
        Text(
          'Downloads from Roadie\'s release page. The file is checked (it must be Roadie, newer, and signed '
          'like this copy) and removed once installed.',
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final String text;
  final Color color;
  final bool bold;
  const _Chip({required this.text, required this.color, this.bold = false});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(20)),
    child: Text(text, style: TextStyle(fontSize: 16, fontWeight: bold ? FontWeight.w600 : FontWeight.w500)),
  );
}

/// What changed, newest build first.
class _Notes extends StatelessWidget {
  final Updater u;
  const _Notes({required this.u});

  static String _ago(DateTime? d) {
    if (d == null) return '';
    final days = DateTime.now().difference(d).inDays;
    return days <= 0 ? 'today' : (days == 1 ? 'yesterday' : '$days days ago');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    if (u.newer.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          u.stage == UpdateStage.checking ? '' : 'What\'s new shows here when there\'s an update.',
          style: TextStyle(color: cs.onSurfaceVariant),
        ),
      );
    }
    final items = [
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
        child: Text('What\'s new', style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
      ),
      for (final r in u.newer)
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 10, 24, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    r.label,
                    style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600, fontSize: 16),
                  ),
                  const SizedBox(width: 10),
                  Text(_ago(r.date), style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14)),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                r.notes.isEmpty ? 'No notes.' : r.notes,
                style: const TextStyle(fontSize: 16, height: 1.35),
              ),
            ],
          ),
        ),
      const SizedBox(height: 24),
    ];
    return LayoutBuilder(
      builder: (context, box) => box.maxHeight.isFinite
          ? ListView(children: items)
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: items),
    );
  }
}
