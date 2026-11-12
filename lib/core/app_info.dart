/// Version shown in Settings and sent to the stores. Bump together with
/// pubspec.yaml's `version:` for every user-visible change.
class AppInfo {
  static const name = 'Roadie';
  static const version = '0.3.5';

  /// Play's "What's new" for this build: one plain-words line.
  static const latest =
      'SoundCloud is the main source, and Spotify and YouTube links now work: Roadie finds each song on SoundCloud and asks about close matches. Faster downloads, made for slow car Wi-Fi, with a summary at the end.';
}
