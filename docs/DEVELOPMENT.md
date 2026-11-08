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
- `lib/core/audio.dart`: the real engine: just_audio (gapless queue) inside
  an audio_service handler (notification, lock screen, steering wheel and
  Bluetooth buttons).
- `lib/core/settings.dart`: every setting, saved as it changes.
- `lib/core/playlists.dart`: the app's own playlists and Favourites.
- `lib/screens/`: home (tabs: side rail on wide screens, bottom bar on
  phones), library views, collection (album / artist / ...), full screen
  player (three layouts: Cover, Glance, Record), queue, search, settings,
  Get music (placeholder for downloads).
- `lib/widgets/`: covers (and drawn stand-ins, and the accent taken from
  the cover), tiles, menus, mini player, controls.

## Screens

`SHOTS=dir flutter test test/screens_test.dart` writes car-sized (1280x720)
and phone screenshots.
