/// Version shown in Settings and sent to the stores. Bump together with
/// pubspec.yaml's `version:` for every user-visible change.
class AppInfo {
  static const name = 'Roadie';
  static const version = '0.2.2';

  /// Play's "What's new" for this build: one plain-words line.
  static const latest =
      'Smoother opening of the player, swipes no longer skip songs by accident, and downloads keep going in the background and retry when the connection drops.';
}
