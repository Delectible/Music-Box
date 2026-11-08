import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/format.dart' as fmt;
import '../core/models.dart';
import '../core/native.dart';
import '../core/scope.dart';
import '../widgets/art.dart';
import 'fix_tags_sheet.dart';

void openSongInfo(BuildContext context, Song song) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SongInfoScreen(song: song)));

/// Everything known about a song: where the file is, the audio format,
/// every tag in the file, the cover, Android's media index and play stats.
class SongInfoScreen extends StatefulWidget {
  final Song song;
  const SongInfoScreen({super.key, required this.song});

  @override
  State<SongInfoScreen> createState() => _SongInfoScreenState();
}

class _SongInfoScreenState extends State<SongInfoScreen> {
  Map<String, Object?>? _info;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    Map<String, Object?> i;
    try {
      i = await Native.fileInfo(widget.song.path, widget.song.id);
    } on PlatformException catch (e) {
      i = {'error': e.message ?? e.code};
    }
    if (mounted) setState(() => _info = i);
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final s = widget.song;
    final info = _info;
    final tags = (info?['tags'] as Map?)?.cast<String, Object?>();
    final ms = (info?['mediaStore'] as Map?)?.cast<String, Object?>() ?? const {};
    final p = scope.player;
    final lists = scope.playlists.all.where((l) => l.songIds.contains(s.id)).map((l) => l.name).toList();
    final root = info?['root'] as String?;
    final wide = MediaQuery.sizeOf(context).width > 1000;

    final sections = <Widget>[
      _Section('Song', [
        ('Title', s.title),
        ('Artist', s.artist),
        ('Album', s.album),
        ('Album artist', s.albumArtist),
        ('Genre', s.genre),
        ('Year', s.year > 0 ? '${s.year}' : 'Unknown'),
        ('Track', s.track > 0 ? '${s.track}' : '—'),
        ('Disc', '${s.disc}'),
        ('Length', _dur(s.duration)),
      ]),
      _Section('File', [
        ('Name', s.fileName),
        ('Folder', s.folder),
        ('Full path', s.path),
        (
          'Stored on',
          root == null
              ? '…'
              : (info?['removable'] == true ? 'SD card / USB ($root)' : 'Internal storage ($root)'),
        ),
        ('Size', _bytes((info?['bytes'] as num?)?.toInt() ?? s.size)),
        ('Modified', _date((info?['modified'] as num?)?.toInt() ?? s.modified.millisecondsSinceEpoch)),
        ('Added to the device', _date(s.added.millisecondsSinceEpoch)),
        if (info != null)
          ('File found', info['exists'] == true ? 'Yes' : 'No — moved or deleted since the last scan'),
        if (info != null)
          ('Roadie can change it', info['canWrite'] == true ? 'Yes' : 'No (needs All files access)'),
        if (info?['volumeTotal'] != null)
          (
            'Free on that storage',
            '${_bytes((info!['volumeFree'] as num).toInt())} of ${_bytes((info['volumeTotal'] as num).toInt())}',
          ),
        ('Content URI', s.uri),
      ]),
      if (tags != null)
        _Section('Audio', [
          ('Format', '${tags['format'] ?? ''}'),
          if ('${tags['encoding'] ?? ''}'.isNotEmpty && tags['encoding'] != tags['format'])
            ('Encoding', '${tags['encoding']}'),
          ('Quality', tags['lossless'] == true ? 'Lossless' : 'Lossy'),
          ('Bit rate', '${tags['bitRate']} kbps${tags['variableBitRate'] == true ? ' (variable)' : ''}'),
          ('Sample rate', '${_khz(tags['sampleRate'])} kHz'),
          if ((tags['bitsPerSample'] as num? ?? 0) > 0) ('Bit depth', '${tags['bitsPerSample']}-bit'),
          ('Channels', _channels('${tags['channels']}')),
          if (tags['durationMs'] != null)
            ('Exact length', _dur(Duration(milliseconds: (tags['durationMs'] as num).toInt()), exact: true)),
          if (tags['tagType'] != null) ('Tag format', '${tags['tagType']}'),
        ]),
      if (tags != null)
        _Section('Cover', [
          if (tags['coverBytes'] == null)
            ('Embedded cover', 'None')
          else ...[
            ('Embedded cover', '${tags['coverWidth']} × ${tags['coverHeight']} px, ${tags['coverMime']}'),
            ('Cover size', _bytes((tags['coverBytes'] as num).toInt())),
            if ((tags['coverCount'] as num? ?? 1) > 1) ('Pictures in file', '${tags['coverCount']}'),
          ],
        ]),
      if (tags != null && tags['fields'] is List)
        _Section('Every tag in the file', [
          for (final f in (tags['fields'] as List).cast<List<Object?>>()) ('${f[0]}', '${f[1]}'),
        ]),
      if (info?['tagsError'] != null)
        _Section('Tags', [('Couldn\'t read the tags', '${info!['tagsError']}')]),
      _Section('Listening', [
        ('Plays', '${p.plays(s.id)}'),
        (
          'Last played',
          p.lastPlayed(s.id) == null ? 'Never' : _date(p.lastPlayed(s.id)!.millisecondsSinceEpoch),
        ),
        ('Favourite', scope.playlists.isFavourite(s.id) ? 'Yes' : 'No'),
        ('In playlists', lists.isEmpty ? 'None' : lists.join(', ')),
      ]),
      if (ms.isNotEmpty)
        _Section('Android media index', [for (final e in ms.entries) (e.key, '${e.value}')], collapsed: true),
      _Section('Roadie', [('Song id', '${s.id}'), ('Album id', '${s.albumId}')], collapsed: true),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Song info'),
        actions: [
          IconButton(
            tooltip: 'Copy all',
            icon: const Icon(Icons.copy_rounded),
            onPressed: () {
              final text = sections.whereType<_Section>().map((x) => x.asText()).join('\n');
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
            },
          ),
          IconButton(
            tooltip: 'Fix tags',
            icon: const Icon(Icons.auto_fix_high_rounded),
            onPressed: () => showFixTags(context, s),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: wide ? 1500 : 900),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            children: [
              Row(
                children: [
                  Art(albumId: s.albumId, size: wide ? 140 : 100),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.title,
                          style: Theme.of(
                            context,
                          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        Text('${s.artist} · ${s.album}', style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            if (tags != null) _Chip(tags['lossless'] == true ? 'Lossless' : 'Lossy'),
                            if (tags != null) _Chip('${tags['format']}'),
                            if (tags != null) _Chip('${_khz(tags['sampleRate'])} kHz'),
                            if (tags != null && (tags['bitsPerSample'] as num? ?? 0) > 0)
                              _Chip('${tags['bitsPerSample']}-bit'),
                            _Chip(_bytes((info?['bytes'] as num?)?.toInt() ?? s.size)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (info == null)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (info?['error'] != null)
                Padding(padding: const EdgeInsets.all(12), child: Text('${info!['error']}')),
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(children: [for (var i = 0; i < sections.length; i += 2) sections[i]]),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(children: [for (var i = 1; i < sections.length; i += 2) sections[i]]),
                    ),
                  ],
                )
              else
                ...sections,
            ],
          ),
        ),
      ),
    );
  }

  static String _dur(Duration d, {bool exact = false}) {
    final base = fmt.clock(d);
    return exact ? '$base.${(d.inMilliseconds % 1000).toString().padLeft(3, '0')}' : base;
  }

  static String _bytes(int b) {
    if (b <= 0) return '—';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = b.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(i < 2 ? 0 : 1)} ${units[i]}';
  }

  static String _date(int ms) {
    if (ms <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  static String _khz(Object? hz) {
    final v = double.tryParse('$hz') ?? 0;
    final k = v / 1000;
    return k == k.roundToDouble() ? '${k.round()}' : k.toStringAsFixed(1);
  }

  static String _channels(String c) => switch (c.trim()) {
    '1' => 'Mono',
    '2' => 'Stereo',
    '' => '—',
    _ => '${c[0].toUpperCase()}${c.substring(1)}',
  };
}

class _Chip extends StatelessWidget {
  final String text;
  const _Chip(this.text);

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.onSecondaryContainer)),
  );
}

class _Section extends StatelessWidget {
  final String title;
  final List<(String, String)> rows;
  final bool collapsed;
  const _Section(this.title, this.rows, {this.collapsed = false});

  String asText() => '$title\n${rows.map((r) => '  ${r.$1}: ${r.$2}').join('\n')}\n';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final body = [
      for (final (k, v) in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 160,
                child: Text(k, style: TextStyle(color: cs.onSurfaceVariant)),
              ),
              Expanded(child: SelectableText(v)),
            ],
          ),
        ),
    ];
    return Card.filled(
      color: cs.surfaceContainer,
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: collapsed
          ? ExpansionTile(
              title: Text(
                title,
                style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600),
              ),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              shape: const Border(),
              children: body,
            )
          : Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  ...body,
                ],
              ),
            ),
    );
  }
}
