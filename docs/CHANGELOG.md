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

## Ideas

- Android Auto / media browser tree so the car's own media UI can browse.
- Alphabet scroller down the side of long lists.
- Sleep / arrival timer; "pause when the car's Bluetooth disconnects".
- Lyrics; equaliser and loudness levelling.
- AcoustID: identify songs with no usable tags by their sound.
