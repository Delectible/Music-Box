import 'package:flutter/widgets.dart';

import 'library.dart';
import 'player.dart';
import 'playlists.dart';
import 'settings.dart';

/// Hands the app's state down the tree.
class AppScope extends InheritedWidget {
  final Settings settings;
  final Library library;
  final Player player;
  final Playlists playlists;

  const AppScope({
    super.key,
    required this.settings,
    required this.library,
    required this.player,
    required this.playlists,
    required super.child,
  });

  static AppScope of(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!;

  @override
  bool updateShouldNotify(AppScope old) => false;
}
