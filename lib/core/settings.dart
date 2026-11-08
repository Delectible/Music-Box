import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sorting.dart';

enum ThemeChoice {
  system('Follow system'),
  light('Light'),
  dark('Dark'),
  black('Black (night driving)');

  final String label;
  const ThemeChoice(this.label);
}

/// The full screen player's layout.
enum PlayerStyle {
  cover('Cover', 'Big cover, controls beside it'),
  glance('Glance', 'Huge text and buttons, read at a glance'),
  record('Record', 'A spinning record');

  final String label;
  final String blurb;
  const PlayerStyle(this.label, this.blurb);
}

enum NavStyle {
  auto('Automatic'),
  rail('Side rail'),
  bottom('Bottom bar');

  final String label;
  const NavStyle(this.label);
}

enum ArtShape {
  rounded('Rounded'),
  square('Square'),
  circle('Circle');

  final String label;
  const ArtShape(this.label);
}

/// Fixed accent colours; [Settings.accent] null means "from the cover".
const accents = <Color>[
  Color(0xFFFF8A3D), // amber
  Color(0xFFFF5C7A), // coral
  Color(0xFFB57BFF), // violet
  Color(0xFF4F9DFF), // blue
  Color(0xFF2EC4B6), // teal
  Color(0xFF7BD34B), // lime
  Color(0xFFFFD23F), // yellow
];

/// Every user setting, saved as it changes.
class Settings extends ChangeNotifier {
  final SharedPreferences _p;
  Settings(this._p);

  T _enum<T extends Enum>(String key, List<T> values, T fallback) =>
      values.where((v) => v.name == _p.getString(key)).firstOrNull ?? fallback;

  void _set(String key, Object value) {
    switch (value) {
      case final bool v:
        _p.setBool(key, v);
      case final int v:
        _p.setInt(key, v);
      case final double v:
        _p.setDouble(key, v);
      case final Enum v:
        _p.setString(key, v.name);
      case final String v:
        _p.setString(key, v);
      case final List<String> v:
        _p.setStringList(key, v);
    }
    notifyListeners();
  }

  // Look.
  ThemeChoice get theme => _enum('theme', ThemeChoice.values, ThemeChoice.dark);
  set theme(ThemeChoice v) => _set('theme', v);

  /// Accent colour, or null to take it from the playing song's cover.
  Color? get accent {
    final v = _p.getInt('accent');
    return v == null || v < 0 ? null : Color(v);
  }

  set accent(Color? c) => _set('accent', c == null ? -1 : c.toARGB32());

  /// Text size multiplier (car screens are read from further away).
  double get textScale => _p.getDouble('textScale') ?? 1.0;
  set textScale(double v) => _set('textScale', v);

  ArtShape get artShape => _enum('artShape', ArtShape.values, ArtShape.rounded);
  set artShape(ArtShape v) => _set('artShape', v);

  NavStyle get nav => _enum('nav', NavStyle.values, NavStyle.auto);
  set nav(NavStyle v) => _set('nav', v);

  bool get animations => _p.getBool('animations') ?? true;
  set animations(bool v) => _set('animations', v);

  // Library.
  List<LibraryTab> get tabs {
    final saved = _p.getStringList('tabs');
    if (saved == null) return LibraryTab.values;
    return [for (final n in saved) ...LibraryTab.values.where((t) => t.name == n)];
  }

  set tabs(List<LibraryTab> v) => _set('tabs', [for (final t in v) t.name]);

  /// All tabs in the saved order, hidden ones last.
  List<LibraryTab> get tabOrder => [...tabs, ...LibraryTab.values.where((t) => !tabs.contains(t))];

  ViewOptions view(LibraryTab tab) => ViewOptions.decode(_p.getString('view.${tab.name}'), tab);
  void setView(LibraryTab tab, ViewOptions v) => _set('view.${tab.name}', v.encode());

  /// Skip files shorter than this (ringtones, voice notes).
  int get minSeconds => _p.getInt('minSeconds') ?? 30;
  set minSeconds(int v) => _set('minSeconds', v);

  // Player.
  PlayerStyle get playerStyle => _enum('playerStyle', PlayerStyle.values, PlayerStyle.cover);
  set playerStyle(PlayerStyle v) => _set('playerStyle', v);

  bool get openPlayerOnPlay => _p.getBool('openPlayerOnPlay') ?? false;
  set openPlayerOnPlay(bool v) => _set('openPlayerOnPlay', v);

  bool get keepScreenOn => _p.getBool('keepScreenOn') ?? true;
  set keepScreenOn(bool v) => _set('keepScreenOn', v);

  bool get swipeToSkip => _p.getBool('swipeToSkip') ?? true;
  set swipeToSkip(bool v) => _set('swipeToSkip', v);

  bool get showClock => _p.getBool('showClock') ?? true;
  set showClock(bool v) => _set('showClock', v);

  bool get blurBackground => _p.getBool('blurBackground') ?? true;
  set blurBackground(bool v) => _set('blurBackground', v);

  /// Big control size in the full screen player (dp).
  double get buttonSize => _p.getDouble('buttonSize') ?? 88;
  set buttonSize(double v) => _set('buttonSize', v);

  int get seekSeconds => _p.getInt('seekSeconds') ?? 15;
  set seekSeconds(int v) => _set('seekSeconds', v);

  /// "Previous" restarts the song when more than this far in.
  bool get previousRestarts => _p.getBool('previousRestarts') ?? true;
  set previousRestarts(bool v) => _set('previousRestarts', v);

  bool get resumeOnStart => _p.getBool('resumeOnStart') ?? false;
  set resumeOnStart(bool v) => _set('resumeOnStart', v);

  ThemeMode get themeMode => switch (theme) {
    ThemeChoice.system => ThemeMode.system,
    ThemeChoice.light => ThemeMode.light,
    _ => ThemeMode.dark,
  };
}
