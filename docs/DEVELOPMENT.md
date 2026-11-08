# Developer guide

## Setup

Flutter stable 3.47+. `flutter create --org com.dingo --project-name roadie
--platforms android .` fills in the platform boilerplate we don't keep,
then `flutter pub get`.

## Structure

- `lib/core/source.dart`: where songs come from. `MediaStoreSource` talks
  to `MainActivity.kt` (channel `roadie/library`): permission, the song
  list from Android's media index, covers cut to size into the cache, and
  media scans for new files. `DemoSource` is a made-up library for tests.
- `lib/core/library.dart`: songs grouped into albums, artists, genres,
  years and folders; search.
- `lib/core/sorting.dart`: sort keys, view modes (list / compact / grid /
  big cards), per-tab view options, section headers.
- `lib/core/player.dart`: the queue (the play order; shuffle reorders it and
  keeps the original), play counts, saving / restoring the last queue.
  Talks to an `Engine`.
- `lib/core/audio.dart`: the real engine (two decks for crossfade; per-song
  gain / speed / silence skipping via `SongSound`): just_audio (gapless queue) inside
  an audio_service handler (notification, lock screen, steering wheel and
  Bluetooth buttons).
- `lib/core/settings.dart`: every setting, saved as it changes.
- `lib/core/playlists.dart`: the app's own playlists and Favourites.
- `lib/core/native.dart`: the rest of MainActivity.kt: storage roots and
  folders, All files access, microphone permission (visualiser), tags.
  `Tags.kt` reads / writes tags and covers with jaudiotagger;
  `Visualizer.kt` streams Android's Visualizer FFT + waveform
  (channel `roadie/visualizer`).
- `lib/core/metadata.dart` / `tag_fixer.dart`: MusicBrainz lookups (1 a
  second), Cover Art Archive, file-name guesses, single and batch Fix tags.
- `lib/core/sources.dart` / `downloads.dart`: Get music sources (Internet
  Archive, Jamendo with a user key, ccMixter, direct link) and the queue
  (2 at a time, Artist/Album/NN Title.ext, then tagged and scanned).
- `lib/screens/browser_screen.dart`: webview_flutter browser for added
  sites (`CustomSite`); a script lists audio links / <audio> / og:audio on
  each page, taps on audio files are caught; found files open as a
  `PageSource` item (same preview / download screen).
- `lib/core/visualizer.dart` + `widgets/visualizer_painter.dart`: the
  feed (live, or made up when there's no permission / data) and 10 styles.
- `lib/core/levelling.dart` + `Loudness.kt`: volume levelling (ReplayGain
  or measured LUFS, cached in prefs `gains`).
- `lib/core/lyrics.dart`, `quality.dart`, `smart.dart`: lyrics (LRCLIB /
  .lrc), quality badge, smart playlists and the duplicate finder.
- `lib/core/crash_log.dart`: Dart and native errors to
  `files/problems.log` and `native_crash.txt`, shown in Settings > Problem
  reports.
- `lib/screens/`: home (tabs: side rail on wide screens, bottom bar on
  phones), library views, collection (album / artist / ...), full screen
  player (three layouts: Cover, Glance, Record), queue, search, settings,
  Get music (placeholder for downloads).
- `lib/widgets/`: covers (and drawn stand-ins, and the accent taken from
  the cover), tiles, menus, mini player, controls.

## Screens

`SHOTS=dir flutter test test/screens_test.dart` writes car-sized (1280x720)
and phone screenshots.

## Builds

Every push to `main` runs `.github/workflows/build-apk.yml`: `flutter
analyze` and `flutter test`, then a release APK and app bundle (build
number = run number). The APK is published on the Releases page as
`build-<n>`. Signing uses the upload key from the repo secrets
`ANDROID_KEYSTORE_BASE64` / `ANDROID_KEYSTORE_PASSWORD` when set, else the
public test key `android/app/roadie-test.jks`. With the secret
`PLAY_SERVICE_ACCOUNT_JSON` the bundle also goes to Play internal testing
(the first .aab must be uploaded by hand). Old releases:
`prune-releases.yml` (run by hand).
