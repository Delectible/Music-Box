/// Version shown in Settings and sent to the stores. Bump together with
/// pubspec.yaml's `version:` for every user-visible change.
class AppInfo {
  static const name = 'Roadie';
  static const version = '0.2.4';

  /// Play's "What's new" for this build: one plain-words line.
  static const latest =
      'Links are checked before downloading (web pages open in the browser, other files are refused), and songs downloaded together can be saved as a playlist.';
}
