import 'dart:async';

import 'package:flutter/material.dart';

import '../core/downloads.dart';
import '../core/matcher.dart';
import '../core/preview.dart';
import '../core/scope.dart';
import '../core/sources.dart';

void openCloseMatches(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const CloseMatchesScreen()));

/// Songs where SoundCloud only had something close: the song wanted on the
/// left, what was found on the right; keep it (Allow) or not (Disallow).
class CloseMatchesScreen extends StatefulWidget {
  const CloseMatchesScreen({super.key});

  @override
  State<CloseMatchesScreen> createState() => _CloseMatchesScreenState();
}

class _CloseMatchesScreenState extends State<CloseMatchesScreen> {
  late final Preview _preview;

  @override
  void initState() {
    super.initState();
    _preview = AppScope.of(context).preview;
  }

  @override
  void dispose() {
    _preview.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = AppScope.of(context).downloads;
    return ListenableBuilder(
      listenable: d,
      builder: (context, _) {
        final list = d.toReview;
        final wide = MediaQuery.sizeOf(context).width >= 700;
        final all = [
          TextButton.icon(
            style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
            onPressed: () {
              unawaited(_preview.stop());
              d.disallowAllClose();
            },
            icon: const Icon(Icons.block_rounded),
            label: const Text('Disallow all'),
          ),
          const SizedBox(width: 8),
          FilledButton.tonalIcon(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
            onPressed: () {
              unawaited(_preview.stop());
              d.allowAllClose();
            },
            icon: const Icon(Icons.check_rounded),
            label: const Text('Allow all'),
          ),
        ];
        return Scaffold(
          appBar: AppBar(
            title: Text(list.isEmpty ? 'Close matches' : 'Close matches (${list.length})'),
            actions: [
              if (wide && list.length > 1) ...[...all, const SizedBox(width: 12)],
            ],
          ),
          body: list.isEmpty
              ? const Center(child: Text('Nothing left to check'))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 40),
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(4, 4, 4, 8),
                      child: Text(
                        'SoundCloud didn\'t have an exact match for these. Allow keeps what was found; '
                        'Disallow skips the song.',
                      ),
                    ),
                    if (!wide && list.length > 1)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(mainAxisAlignment: MainAxisAlignment.end, children: all),
                      ),
                    for (final j in list) _Pair(job: j, downloads: d, wide: wide),
                  ],
                ),
        );
      },
    );
  }
}

/// A decision on a song ends its preview (the pair disappears with it).
void _stop(Preview pv, Uri page) {
  if (pv.current == page) unawaited(pv.stop());
}

String _len(Duration? d) {
  if (d == null || d == Duration.zero) return '';
  final s = d.inSeconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

class _Pair extends StatelessWidget {
  final DownloadJob job;
  final Downloads downloads;
  final bool wide;
  const _Pair({required this.job, required this.downloads, required this.wide});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = job.track;
    final f = job.close!;
    final diff = t.length != null && f.length != null ? (f.length! - t.length!).inSeconds : null;
    final pv = AppScope.of(context).preview;
    final wanted = _Side(
      label: 'You wanted',
      cover: t.cover,
      title: t.title,
      wide: wide,
      lines: [
        t.artist,
        if (t.album.isNotEmpty) t.album,
        if (_len(t.length).isNotEmpty) 'Length ${_len(t.length)}',
      ],
    );
    final found = _Side(
      label: 'Found on SoundCloud',
      cover: f.cover,
      title: f.title,
      wide: wide,
      lines: [
        'Uploaded by ${f.uploader}',
        if (_len(f.length).isNotEmpty)
          'Length ${_len(f.length)}'
              '${diff == null || diff.abs() < 3 ? '' : ' (${diff > 0 ? '+' : '−'}${diff.abs()} s)'}',
        '${(f.score * 100).clamp(0, 100).round()}% match',
      ],
      action: ListenableBuilder(
        listenable: pv,
        builder: (context, _) {
          final on = pv.current == f.page;
          return TextButton.icon(
            style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
            onPressed: () => pv.toggle(f.page, resolve: () => SoundCloud.streamUrl('${f.page}')),
            icon: on && pv.loading
                ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2.5))
                : Icon(on ? Icons.stop_rounded : Icons.play_arrow_rounded),
            label: Text(on ? 'Stop' : 'Listen'),
          );
        },
      ),
    );
    final disallow = OutlinedButton.icon(
      style: OutlinedButton.styleFrom(minimumSize: const Size(0, 56)),
      onPressed: () {
        _stop(pv, f.page);
        downloads.disallowClose(job);
      },
      icon: const Icon(Icons.block_rounded),
      label: const Text('Disallow'),
    );
    final allow = FilledButton.icon(
      style: FilledButton.styleFrom(minimumSize: const Size(0, 56)),
      onPressed: () {
        _stop(pv, f.page);
        downloads.allowClose(job);
      },
      icon: const Icon(Icons.check_rounded),
      label: const Text('Allow'),
    );
    final sides = IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: wanted),
          VerticalDivider(width: 24, color: cs.outlineVariant),
          Expanded(child: found),
        ],
      ),
    );
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: wide
            // Car screen: one row each, the buttons on the right.
            ? Row(
                children: [
                  Expanded(child: sides),
                  const SizedBox(width: 16),
                  SizedBox(
                    width: 180,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [allow, const SizedBox(height: 10), disallow],
                    ),
                  ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  sides,
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(child: disallow),
                      const SizedBox(width: 12),
                      Expanded(child: allow),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

class _Side extends StatelessWidget {
  final String label, title;
  final String? cover;
  final List<String> lines;
  final Widget? action;
  final bool wide;
  const _Side({
    required this.label,
    required this.title,
    required this.cover,
    required this.lines,
    required this.wide,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final art = ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox.square(
        dimension: 72,
        child: cover == null
            ? ColoredBox(
                color: cs.surfaceContainerHighest,
                child: Icon(Icons.music_note_rounded, color: cs.onSurfaceVariant, size: 36),
              )
            : Image.network(
                cover!,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => ColoredBox(color: cs.surfaceContainerHighest),
              ),
      ),
    );
    final text = [
      Text(title, style: tt.titleMedium, maxLines: wide ? 2 : 3, overflow: TextOverflow.ellipsis),
      for (final l in lines)
        if (l.isNotEmpty)
          Text(
            l,
            style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            maxLines: wide ? 1 : 2,
            overflow: TextOverflow.ellipsis,
          ),
    ];
    final heading = Text(label, style: tt.labelLarge?.copyWith(color: cs.primary));
    if (wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          heading,
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              art,
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [...text, ?action]),
              ),
            ],
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [heading, const SizedBox(height: 8), art, const SizedBox(height: 8), ...text, ?action],
    );
  }
}

/// Used by tests: a job waiting on a close match.
DownloadJob reviewJob(RemoteTrack t, Found f) => DownloadJob(t)
  ..state = JobState.review
  ..close = f
  ..error = 'Close match found';
