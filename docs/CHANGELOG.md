# Requests and ideas

## Requests

1. A car-screen music player like the simple, customisable players on the
   Play store: more sorting and views, a full screen player for the car,
   nice animations. (0.1.0: library tabs, 13 sort keys, 4 views per tab,
   three full screen player layouts, settings.)
2. Get music from sites, downloaded automatically from inside the app.
   Details to come. (0.1.0: Get music tab placeholder. 0.2.0: Internet
   Archive, Jamendo, ccMixter and direct links, a browser, download queue,
   chosen folder (default Music/Roadie), MusicBrainz tags and covers.
   tidal.squid.wtf declined: it serves TIDAL's catalogue without the rights.)
3. Turn bottom-row tabs on and off (already in 0.1.0: Settings > Tabs).
4. App icon inspired by a vinyl record, something different (0.2.0: B, the
   record setting over the road, polished; source in docs/icon.)
5. Visualisers like old Windows Media Player / iTunes, from the home
   screen and the player, one using the cover. (0.2.0: 9 styles, all but
   Cover ring.)
6. Choose where music comes from: include / exclude folders. (0.2.0)
7. Rich metadata: look up missing tags on a database, for downloads and
   existing files. (0.2.0: MusicBrainz + Cover Art Archive, Fix tags.)
8. Basic error / crash reporting. (0.2.0: Settings > Problem reports.)
9. Preview a song from a source before downloading. (0.2.1: play / stop
   on each track, streams a lighter MP3 where the source has one.)
10. An info button on songs: everything about it, where it's stored.
   (0.2.1: Song info in the song menu: song, file and storage, audio
   format, cover, every tag, play stats, Android's media index.)
11. Player opening: the cover flashed its stand-in and landed in the wrong
   place (record layout). (0.2.2: cover warmed ahead and shown on the first
   frame, flies unscaled and unrotated onto the label.)
12. Back / app-switch gestures skipped songs. (0.2.2: swipes starting at
   the screen edges or on the gesture bar, or too short, are ignored.)
13. Fix tags: MusicBrainz 503. (0.2.2: waits and retries, plain message.)
14. Downloads failed (no internet / connection dropped) when Roadie was in
   the background. (0.2.2: foreground notification while downloading,
   automatic retries that continue the partial file, plain error text.)
15. The clock in the player doubled the phone's. (0.2.2: car screens only.)
16. Search several sources at once. (0.2.3: tick any number; results
   grouped by source.)
17. Add new free sites, whatever their structure. (0.2.3: "Add a site":
   name, home page, optional search address with {q}; opens in a built-in
   browser that lists the music files on each page and catches taps on
   them, to preview and download. "Use this page for searching" learns the
   search address from a search done on the site.)
18. Internet Archive results unrelated to the search. (0.2.3: radio /
   podcast / audiobook collections left out; ranked by how much of the
   search is in the title and artist, then popularity.)
19. A YouTube link "downloaded" a broken file. (0.2.4: links are checked
   first: music downloads, web pages open in the browser, anything else is
   refused; every download's first bytes must be audio or it's deleted.)
20. YouTube links and whole playlists. (0.2.4 declined; 0.2.5 after the
   owner pointed at the free / Creative Commons / podcast content there:
   YouTube source (search, videos, playlists up to 500, best AAC audio,
   tags from title / channel, thumbnail cover) via youtube_explode_dart.
   What's downloaded is the owner's call.)
21. Keep a group of downloads together as a playlist. (0.2.4: asked when
   downloading more than one song; made in order once they're done.)
22. Podcasts by normal means. (0.2.5: Podcasts source: Apple's free
   podcast search, episodes from the show's own RSS feed; pasted feed
   links work; episodes aren't pre-ticked; no MusicBrainz lookup.)
23. A Podcasts section. (0.2.6: Podcasts tab (shows as covers; sort by
   newest episode, title, episodes, recently played); a show's episodes by
   newest / oldest / number / title, unplayed filter, played ticks;
   podcasts kept out of the music tabs; Android podcast files scanned.)
24. Fix tags found nothing for a specific classical track. (0.2.6: the
   artist was searched as one exact phrase ("A; B") and the album had to
   match; now tries each artist, then looser searches, until something
   matches; also fixed a crash on matches without tags.)
25. Fade between visualiser styles. (0.2.7: 0.6 s cross-fade.)
26. A nice media notification. (0.3.0: Roadie status icon, accent colour,
   cover, prev / play / next and a favourite heart.)
27. Prettier player. (0.3.0: wavy seek bar that ripples while playing and
   lies flat when paused; cover eases back when paused; drifting blurred
   backdrop; controls fade in one after another.)
28. Remember the last song and position; autoplay; straight into the full
   player. (0.3.0: the open-player option; the rest was already there.)
29. Podcast basics. (0.3.0: carry on where you left off, played at 90%,
   time left, mark played / not played, speed 0.75-2x, skip silences.)
30. Volume levelling. (0.3.0: ReplayGain tags, else measured once on the
   device (BS.1770, K-weighted, gated) and remembered; each song or albums
   as a whole; extra volume.)
31. Day & night theme. (0.3.0: by time of day, black at night.)
32. Favourites shelf. (0.3.0: above Songs.)
33. Quality badge in the player. (0.3.0: "Hi-Res FLAC 24-bit · 96 kHz",
   "MP3 320 kbps".)
34. Crossfade. (0.3.0: 0-12 s, equal power, two players; albums that
   follow on play straight through.)
35. Duplicate finder. (0.3.0: same title / artist, length within 3 s;
   best copy kept, the rest deleted after confirming.)
36. Synced lyrics. (0.3.0: .lrc next to the song or LRCLIB; current line
   highlighted, tap to jump.)
37. Smart playlists. (0.3.0: Road trip mix (2 h, daily), Recently added,
   Most played, Forgotten favourites, Not heard in a while, Never played.)
38. Navigation buttons hide themselves (immersive). (0.3.1: Settings >
   Full screen: hide navigation buttons (default) / navigation and status
   bar / always shown; a swipe from the edge shows them for a moment.)
39. YouTube downloads stuck at 0%. (0.3.2: the library re-asked YouTube
   forever when a stream was refused; now Roadie tries the VR, Android and
   TV app types in turn with time limits, downloads in 9 MB pieces, shows
   which step it's on, and fails with a plain message if all refuse.)
40. YouTube: "private, age restricted or removed" on normal videos. (0.3.3:
   that text was a guess; now YouTube's own reason is shown. YouTube's
   stream challenges are solved with yt-dlp's solver (hash-checked)
   running in a hidden WebView, which opens the web player and TV clients;
   VR, web, TV, Android and mobile web are tried in turn; each refusal is
   logged in Problem reports. Builds now pin Flutter 3.47.9: a new
   stable release broke the build.)
41. Download toast: 5 s and a close button; "Show" crashed after leaving
   the album page. (0.3.4: all toasts have a close button; fixed.)
42. YouTube "web player: No host specified in URI". (0.3.4: the library
   passed the solver a player address without the host; fixed, web
   player tried first, web / TV get 90 s.)
43. Manage download sources: reorder, remove all, add built-ins back, add
   sites by link, each one's settings. (0.3.4: Get music > Sources.)
44. Delete a song or album from the device (⋮, with confirmation). (0.3.4)
45. Edit tags for a song, or in bulk for an album / playlist / any group:
   title, artist, album, album artist, genre, year, track, disc. (0.3.4)
46. SoundCloud as the main source: search, track / set / artist links,
   previews, the artist's original file when they allow downloads. Runs on
   bundled yt-dlp, which updates itself: daily in the background (can be
   turned off: Get music > Sources > SoundCloud) and straight away when a
   failure looks like SoundCloud changed something (stable, then nightly).
   (0.3.5)
47. Spotify (track, album, playlist) and YouTube (video, playlist) links
   give the song details; each song is found on SoundCloud (`SongMatcher`:
   title, artist, length, refuses remixes / covers / sped up / live / Go+
   clips unless that's the song) and saved with the Spotify / YouTube tags.
   Spotify playlists: first 100 songs. Any pasted link opens, whatever
   source is ticked. (0.3.5)
48. Downloads at the same time: 1–8 (Settings > Get music, default 4);
   streams fetched in 4 pieces at once; yt-dlp started at launch.
   A summary when a run finishes (saved / already there / didn't work and
   why, try the failed ones again). (0.3.5)
49. Close matches: when SoundCloud only has something near (another
   version, a different length, a cover), the song waits with a "Close
   match found" button: the song wanted on the left, the upload found on
   the right (with Listen), Allow / Disallow each, Allow all / Disallow
   all. (0.3.5)
50. Slow car Wi-Fi: longer timeouts (60 s), more tries with growing waits,
   IPv4 only (half-working IPv6 on hotspots); when downloads crawl or keep
   dropping, offers "Use 2 at once". (0.3.5)
51. Android 10 / head units: 2 downloads at once by default under 3 GB of
   memory (each runs its own Python); plain messages for a wrong device
   clock (common before a GPS fix) and for SD cards / USB sticks, which
   apps can't save to on Android 10. (0.3.5)
52. Fix: 0.3.5 closed straight away on start. R8 stripped what WorkManager
   (the daily yt-dlp check) needs to open its database at launch. Kept
   now, and WorkManager only starts when first used (`RoadieApp`), so it
   can't stop the app opening; crashes this early are now recorded for
   Problem reports. Checked on an Android 10 emulator with a release
   build. (0.3.6)
53. Faster SoundCloud search: yt-dlp checked each result's original cover
   with an extra request (~0.3 s each, 40 results ~13 s). Roadie's yt-dlp
   plugin (`Ytdlp.plugin`, written at start, `--plugin-dirs`) skips that:
   ~1.5 s. Also a lasting yt-dlp cache (`--cache-dir`). (0.3.7)
54. Go+ preview-only and DRM-locked SoundCloud uploads: the download looks
   for another upload of the same song (the matcher, close matches to
   check); plain message for DRM. (0.3.7)
55. Downloads screen in groups: Needs you (close matches) at the very top,
   then Downloading (running, then the queue), Didn't work (Try all
   again), Done (Clear). "Clear finished" keeps close matches waiting on
   a decision. (0.3.8)
56. Close matches: Allow / Disallow (and all) stop that song's preview.
   Messages at the bottom go away after 4 s, also those with a button
   (newer Flutter kept those up until tapped: `persist: false`). (0.3.9)
57. Added sites and links on plain http:// (no https) work: the browser
   showed net::ERR_CLEARTEXT_NOT_PERMITTED (manifest
   usesCleartextTraffic). Typed addresses still try https first. (0.3.9)
58. Teach Roadie a site (browser > ⋮ > Teach Roadie to download from this
   site): on its search results, tap a song, then the download button(s)
   until the file comes. Roadie keeps those taps as a recipe (link address
   patterns, button words, where they sit; `SiteRecipe`) and from then on
   searching that site in Get music lists its songs like any source; a
   preview or download opens the song's page in a hidden browser
   (`PageRunner.kt`, sharing the browser's cookies / sign-ins), presses
   the taught buttons and catches the file (a music link, a download, or
   an address that serves audio, checked by its first bytes). Falls back to
   any music file on the page, then to "See on site". ⋮ > Forget what
   Roadie learned. Links that download without ".mp3" in the address now
   work in the browser too. Tested on Android 10 against a local test site
   with a JavaScript download button. (0.4.0)
59. Fix: adding a site listed it twice in Get music (two "Browse" buttons).
   (0.4.0)
60. Full screen player open / close: the page slides on the same curve as
   the cover, so they arrive together; the spinning record's label turns
   back upright during the flight (no snap at the end), eases from round
   to the mini player's square, and the spindle hole travels with it and
   fades. (0.4.1)
61. Playlist covers: a playlist downloaded from Spotify / YouTube /
   SoundCloud keeps that playlist's picture; ⋮ > Change cover… picks one
   of its songs' covers, a picture on the device (Android's picker, copied
   into Roadie), or back to automatic (the first song's). (0.4.2)
62. Fix: the − next to a song in a playlist removed it, but the screen
   didn't update; the playlist screen now follows changes. (0.4.2)
63. Layout sweep: text ran into the next row of covers (and other overlaps)
   at some sizes. Grids now size rows from the cover plus the text's real
   height at the current text size (`FitGrid`, `cardTextRoom`); wide cards,
   shelves and the artist page's album row too; the player's cover / record
   gives way on short screens; the play bar's count gives way; tab titles
   shrink rather than break mid-word; bottom bar labels hidden with more
   than 5 tabs. A test opens every main screen at car, phone, small phone
   and tablet sizes at 100 / 130 / 160 % text and fails on any overflow.
   (0.4.3)

## Ideas

- Android Auto / media browser tree so the car's own media UI can browse.
- Alphabet scroller down the side of long lists.
- Sleep / arrival timer; start / stop with the car's Bluetooth.
- Volume that rises with speed; voice commands.
- Equaliser (per output: car, headphones).
- AcoustID: identify songs with no usable tags by their sound.
