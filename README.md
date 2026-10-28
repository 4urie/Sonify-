# Sonify

An Android music streaming app built with Flutter. Sonify uses your existing Supabase project for a public, read-only music catalog and public audio/artwork storage. Your library stays on your device.

## Connect Supabase

1. In your project's **SQL Editor**, run `supabase/migrations/202610230001_catalog.sql` once. It creates `songs`, the `search_songs` function, and public `music` and `artwork` buckets. It intentionally fails rather than changing an existing table or bucket with those names. Inspect conflicting names before adapting the migration.
2. In **Storage → music**, upload an MP3 you own or have permission to stream. Upload cover images to **Storage → artwork**. Project storage/upload/egress limits still apply. These buckets are public, so do not put private files in them.
3. Add song rows in **Table Editor → songs**. Paths are object paths **inside** each bucket, not full URLs or device file paths. Paths and filename case must match exactly.

Example (replace with paths you uploaded):

```sql
insert into public.songs (title, artist, album, audio_path, artwork_path, duration_ms)
values ('First Light', 'Your Artist', 'Morning Sessions',
        'your-artist/first-light.mp3', 'your-artist/morning.jpg', 183000);
```

Artwork and duration may be null. The player reads actual duration when audio loads. Missing covers use a placeholder. No commercial music or fabricated catalog entries are bundled.

4. Copy `config.example.json` to `config.json`. Fill in the project URL and **publishable** key from the dashboard. A legacy `anon` key also works as the value. Never use a `service_role`, secret, database password, or administrative key. `config.json` is ignored by Git, but client configuration remains visible inside a built app: security comes from RLS/storage policies.
5. Connect an Android phone with USB debugging:

```powershell
flutter pub get
flutter run --dart-define-from-file=config.json
```

Build a development APK:

```powershell
flutter build apk --debug --dart-define-from-file=config.json
```

Output: `build/app/outputs/flutter-apk/app-debug.apk`. Without configuration, the app shows a setup screen. Rebuild after changing configuration. Android is the supported target; the other platform starter directories are not configured for this app. The development application ID remains `com.example.sonify`; release signing and store publication are not configured.

## Using Sonify

- **Home** lists the catalog and recent listening. Pull down to refresh; Load more fetches the next 50 songs.
- **Search** matches literal title/artist substrings after a 300 ms debounce. Results are paginated.
- Tap a song to play its displayed collection. Catalog playback fetches additional pages near the end of the loaded queue.
- Tap the persistent mini-player for Now Playing, seek, favorites, shuffle, repeat, and queue access.
- Song options add to favorites, a local playlist, the queue, or immediately after the current song. Duplicate queue entries are supported.
- Open the queue to drag, remove, or clear entries. Removing the current entry selects its successor, or the last remaining track if no successor exists.
- In Library, create playlists with **+**. Open one to reorder/remove songs, rename, or delete it.
- Previous restarts after three seconds; otherwise it selects the previous track. Repeat cycles off → all → one → off. Manual Next advances while repeat-one is active.
- The latest 100 distinct played songs are retained. Favorites, playlists, metadata, and playback settings survive restart. A new process restores **paused**, without downloading audio. Reopening an already-playing background service reconnects to it.
- Cached library metadata remains available offline. There are no audio downloads. Removed catalog rows remain in saved collections as unavailable after successful reconciliation; network errors do not delete library data.
- Playback continues in the background and on the lock screen. Notification/media headset controls use the same handler. Headphone disconnection pauses playback. Android force-stop terminates playback; manufacturers may impose extra background restrictions.
- **Stop** in Now Playing or the notification releases active playback resources. Pause keeps the media foreground service available for reliable background resume. Removing a paused app from Recents stops the service.

## Architecture and lifecycle

- `CatalogRepository` isolates Supabase queries and URLs. Parameterized SQL search treats punctuation literally. Anonymous catalog writes are denied; uploads are dashboard-only.
- `LocalStore` provides versioned SQLite persistence. V1 stores atomic JSON documents for library and playback in a keyed table, keeping related library changes in one write. Future schema changes must migrate the database version. No library data is uploaded.
- `CatalogController` owns pagination, debouncing, cached fallback, and generation tokens that discard stale responses.
- Riverpod supplies the shared catalog, library, and audio handler. Widgets never construct audio engines.
- `SonifyAudioHandler` is initialized once with `AudioService.init` and owns one `AudioPlayer`. Queue mutations are serialized; separate entry IDs support repeats. All media state and controls use this handler.
- Playback snapshots are saved every five seconds and after commands, outside queue mutations. Abrupt process termination can lose up to five seconds of position. Restart never autoplays.
- `audio_session` configures music focus; `just_audio` handles interruption/noisy-device events. `AudioServiceActivity` shares the Flutter engine across activity recreation. Routes cancel UI subscriptions, not background audio. Explicit owner teardown calls idempotent `dispose` to cancel timers/subscriptions and dispose the player. `stop` releases native playback resources while retaining the reusable handler. Android releases process-owned resources on termination.

## Verification

```powershell
flutter analyze
flutter test
flutter build apk --debug
```

To regenerate the phone-sized UI previews with test fixtures, run `flutter test --dart-define=SONIFY_CAPTURE_PREVIEWS=true`. Images are written to `build/previews`.

Automated tests cover pagination, debounce/stale search, offline retry, local persistence/unavailable songs, SQLite reopening, queue operations, command mapping, paused restoration, interrupted loads, disposal, navigation, mini-player, and playlist editing. Unit/widget tests replace native audio with an injectable engine double and do not prove hardware playback.

### Real Supabase / Android checklist

Use at least three uploaded tracks; use 51+ catalog rows to check pagination:

1. Fetch catalog and artwork, search title/artist including punctuation, and load more. Verify anonymous reads and denied writes, and public file streaming with client configuration only.
2. Play/pause, seek near the end, next/previous before/after three seconds, all repeat modes, and shuffle. Rapidly tap songs and verify only one audible stream.
3. Append duplicates, play next, reorder across the current track, remove current/earlier/last entries, clear, and restart. Unrelated queue edits must preserve current position.
4. Create/rename/delete playlists, reorder/remove tracks, toggle favorites, and relaunch. Delete a saved catalog row in Supabase and resume the app; the saved item should remain marked unavailable.
5. Lock the screen, use media controls, and reopen the activity. Test wired/Bluetooth headset buttons where supported, headphone disconnection, calls, and another app requesting audio focus.
6. Toggle airplane mode during browsing and streaming. Verify cached library, retry/skip, and recovery without duplicate playback. Test missing audio and artwork objects independently.
7. Relaunch after process termination: restore paused with position and modes. Test Android force-stop separately: playback must terminate.
8. Check narrow screens, large text, and TalkBack labels, seeking, queue, and playlist controls.

No Supabase credentials, uploaded test audio, Android device, or emulator were supplied. The real-service/hardware checklist requires configuration and a device. Local results are recorded in `docs/verification.md`.

References: [Supabase Flutter](https://supabase.com/docs/guides/getting-started/quickstarts/flutter), [public buckets](https://supabase.com/docs/guides/storage/buckets/fundamentals), [audio_service](https://pub.dev/packages/audio_service), [just_audio](https://pub.dev/packages/just_audio).
