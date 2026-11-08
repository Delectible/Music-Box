import 'package:flutter/material.dart';

/// Getting music from sites, straight into the library. The sources and
/// the download queue arrive in a later version; this is where they live.
class GetMusicScreen extends StatelessWidget {
  const GetMusicScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    Widget card(IconData icon, String title, String body) => Card.filled(
      color: cs.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 36, color: cs.primary),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(body, style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
      children: [
        card(
          Icons.travel_explore_rounded,
          'Sources',
          'Sites you get music from. Search one here and the songs download straight into your library.',
        ),
        card(
          Icons.downloading_rounded,
          'Downloads',
          'Progress for each song, then it shows up in Songs and Albums with its cover and tags.',
        ),
        card(Icons.folder_special_rounded, 'Saved to', 'Music/Roadie on this device.'),
        const SizedBox(height: 12),
        Center(
          child: Text(
            'Coming in the next version',
            style: tt.labelLarge?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
