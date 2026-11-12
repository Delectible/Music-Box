import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'levelling.dart';
import 'sorting.dart';

enum ThemeChoice {
  dayNight('Day & night (by time)'),
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

enum BarsMode {
  shown('Always shown'),
  navigation('Hide navigation buttons'),
  all('Hide navigation and status bar');

  final String label;
  const BarsMode(this.label);
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

  /// System bars: what hides (a swipe from the edge shows them for a moment).
  BarsMode get bars => _enum('bars', BarsMode.values, BarsMode.navigation);
  set bars(BarsMode v) => _set('bars', v);

  bool get animations => _p.getBool('animations') ?? true;
  set animations(bool v) => _set('animations', v);

  // Library.
  List<LibraryTab> get tabs {
    final saved = _p.getStringList('tabs');
    if (saved == null) return LibraryTab.values;
    final out = [for (final n in saved) ...LibraryTab.values.where((t) => t.name == n)];
    // Tabs added in a later version show up (before Get music) until switched off.
    final known =
        _p.getStringList('tabsKnown') ??
        const ['songs', 'albums', 'artists', 'genres', 'years', 'folders', 'playlists', 'get'];
    for (final t in LibraryTab.values) {
      if (!known.contains(t.name) && !out.contains(t)) {
        final g = out.indexOf(LibraryTab.get);
        g < 0 ? out.add(t) : out.insert(g, t);
      }
    }
    return out;
  }

  set tabs(List<LibraryTab> v) {
    _p.setStringList('tabsKnown', [for (final t in LibraryTab.values) t.name]);
    _set('tabs', [for (final t in v) t.name]);
  }

  /// Episode order in a podcast: newest, oldest, number, title.
  String get episodeOrder => _p.getString('episodeOrder') ?? 'newest';
  set episodeOrder(String v) => _set('episodeOrder', v);

  bool get unplayedOnly => _p.getBool('unplayedOnly') ?? false;
  set unplayedOnly(bool v) => _set('unplayedOnly', v);

  /// All tabs in the saved order, hidden ones last.
  List<LibraryTab> get tabOrder => [...tabs, ...LibraryTab.values.where((t) => !tabs.contains(t))];

  ViewOptions view(LibraryTab tab) => ViewOptions.decode(_p.getString('view.${tab.name}'), tab);
  void setView(LibraryTab tab, ViewOptions v) => _set('view.${tab.name}', v.encode());

  /// Folders the library comes from (empty: everywhere) and folders it skips.
  List<String> get includeFolders => _p.getStringList('includeFolders') ?? const [];
  set includeFolders(List<String> v) => _set('includeFolders', v);
  List<String> get excludeFolders => _p.getStringList('excludeFolders') ?? const [];
  set excludeFolders(List<String> v) => _set('excludeFolders', v);

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

  // Get music.
  /// Where downloads are saved; empty means Music/Roadie.
  String get downloadFolder => _p.getString('downloadFolder') ?? '';
  set downloadFolder(String v) => _set('downloadFolder', v);

  /// Look up missing tags and covers for downloads on MusicBrainz.
  bool get lookUpDownloads => _p.getBool('lookUpDownloads') ?? true;
  set lookUpDownloads(bool v) => _set('lookUpDownloads', v);

  /// Prefer lossless (FLAC) when a source has it.
  bool get preferLossless => _p.getBool('preferLossless') ?? true;
  set preferLossless(bool v) => _set('preferLossless', v);

  /// The sources shown in Get music, in order (built-in and site ids).
  /// Removed ones aren't listed; sites added later go on the end.
  List<String> get sourceOrder {
    final saved = _p.getStringList('sourceOrder');
    if (saved != null) return saved;
    final sites = (RegExp(r'"id":"([^"]+)"').allMatches(customSitesJson)).map((m) => m.group(1)!);
    return ['archive', 'youtube', 'podcasts', 'jamendo', 'ccmixter', 'link', ...sites];
  }

  set sourceOrder(List<String> v) => _set('sourceOrder', v);

  /// Lossless (FLAC) when a source has it, per source.
  bool losslessFor(String id) => _p.getBool('lossless.$id') ?? preferLossless;
  void setLossless(String id, bool v) => _set('lossless.$id', v);

  /// Sources ticked in Get music (built-in ids and custom site ids).
  List<String> get sources => _p.getStringList('sources') ?? const ['archive'];
  set sources(List<String> v) => _set('sources', v);

  /// Websites the user added (JSON, see CustomSite).
  String get customSitesJson => _p.getString('customSites') ?? '';
  set customSitesJson(String v) => _set('customSites', v);

  /// Jamendo's free API key (developer.jamendo.com).
  String get jamendoKey => _p.getString('jamendoKey') ?? '';
  set jamendoKey(String v) => _set('jamendoKey', v);

  // Visualiser.
  String get visualizer => _p.getString('visualizer') ?? 'bars';
  set visualizer(String v) => _set('visualizer', v);

  /// Day & night: light from [dayStarts] to [nightStarts] (hours), then
  /// dark (or black with [nightBlack]).
  int get dayStarts => _p.getInt('dayStarts') ?? 7;
  set dayStarts(int v) => _set('dayStarts', v);
  int get nightStarts => _p.getInt('nightStarts') ?? 19;
  set nightStarts(int v) => _set('nightStarts', v);
  bool get nightBlack => _p.getBool('nightBlack') ?? true;
  set nightBlack(bool v) => _set('nightBlack', v);

  bool isNight([DateTime? at]) {
    final h = (at ?? DateTime.now()).hour;
    return dayStarts <= nightStarts
        ? (h < dayStarts || h >= nightStarts)
        : (h >= nightStarts && h < dayStarts);
  }

  ThemeMode get themeMode => switch (theme) {
    ThemeChoice.system => ThemeMode.system,
    ThemeChoice.light => ThemeMode.light,
    ThemeChoice.dayNight => isNight() ? ThemeMode.dark : ThemeMode.light,
    _ => ThemeMode.dark,
  };

  /// All-black dark theme now (Black, or Day & night at night with black on).
  bool get blackNow => theme == ThemeChoice.black || (theme == ThemeChoice.dayNight && nightBlack);

  // Sound.
  LevelMode get levelMode => _enum('levelMode', LevelMode.values, LevelMode.track);
  set levelMode(LevelMode v) => _set('levelMode', v);

  /// Extra gain on top of levelling (dB): loud cars may want +3.
  double get preamp => _p.getDouble('preamp') ?? 0;
  set preamp(double v) => _set('preamp', v);

  /// Crossfade seconds (0 = off) and whether album tracks run straight on.
  int get crossfade => _p.getInt('crossfade') ?? 0;
  set crossfade(int v) => _set('crossfade', v);
  bool get albumGapless => _p.getBool('albumGapless') ?? true;
  set albumGapless(bool v) => _set('albumGapless', v);

  // Podcasts.
  double get podcastSpeed => _p.getDouble('podcastSpeed') ?? 1.0;
  set podcastSpeed(double v) => _set('podcastSpeed', v);
  bool get skipSilence => _p.getBool('skipSilence') ?? false;
  set skipSilence(bool v) => _set('skipSilence', v);

  // Start up and extras.
  bool get openPlayerOnStart => _p.getBool('openPlayerOnStart') ?? false;
  set openPlayerOnStart(bool v) => _set('openPlayerOnStart', v);
  bool get lyrics => _p.getBool('lyrics') ?? true;
  set lyrics(bool v) => _set('lyrics', v);
  bool get favouritesShelf => _p.getBool('favouritesShelf') ?? true;
  set favouritesShelf(bool v) => _set('favouritesShelf', v);
}
