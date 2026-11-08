# Roadie: notes for Claude

A simple, customisable music player for car screens (Flutter, Android first).
This page is the rules; `docs/DEVELOPMENT.md` has setup and structure.
Same workflow as Sisyphus and Darkroom (Delectible/...).

## How we work

- The owner tests on his car's head unit (Android 10, landscape) and his
  phone, often low on usage: short plain replies, stay focused, batch
  tweaks, run only the tests that matter (full suite before committing).
- Big changes: ask first. Open-ended visual changes: show 2–3 screenshot
  options before building (`SHOTS=dir flutter test test/screens_test.dart`).
- Not on GitHub yet: work locally, commit freely, push nothing until he
  says so. Then the Sisyphus flow (main → Play internal testing).
- User-visible change: bump `pubspec.yaml` version+build and
  `AppInfo.version`; set `AppInfo.latest` (plain words).
- Commit messages plain: no session links, no Co-Authored-By.
- Log requests in `docs/CHANGELOG.md` by number; new ideas go there too.

## Design rules

- Car first: landscape at ~1280x720, touch targets 56dp+, big type, works
  at arm's length. Phone portrait must still work.
- Animations are short (200–450 ms) and all go through `motion()` so the
  Animations switch turns them off.
- No image or audio assets: placeholder covers are drawn in code.
- No real brand names in the app or listings.

## Never

- Changing `com.dingo.roadie`; deleting `AndroidManifest.xml`,
  `android/app/build.gradle.kts` or `MainActivity.kt`.
- Committing signing keys.

## Checks

`flutter analyze`, `flutter test` (SDK may be at `/tmp/flutter/bin`; set
`FLUTTER_ROOT`). `dart format -l 110` on changed files only.
