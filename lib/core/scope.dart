import 'package:flutter/widgets.dart';

import 'downloads.dart';
import 'library.dart';
import 'player.dart';
import 'playlists.dart';
import 'preview.dart';
import 'settings.dart';
import 'tag_fixer.dart';

/// Hands the app's state down the tree.
class AppScope extends InheritedWidget {
  final Settings settings;
  final Library library;
  final Player player;
  final Playlists playlists;
  final Downloads downloads;
  final TagFixer fixer;
  final Preview preview;

  const AppScope({
    super.key,
    required this.settings,
    required this.library,
    required this.player,
    required this.playlists,
    required this.downloads,
    required this.fixer,
    required this.preview,
    required super.child,
  });

  static AppScope of(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!;

  @override
  bool updateShouldNotify(AppScope old) => false;
}
