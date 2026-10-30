# Sonify

An Android music streaming app built with Flutter. Sonify uses Supabase for a public, read-only music catalog and artwork, and Cloudflare R2 for public audio. Your library stays on your device.

## Connect Supabase

1. In your project's **SQL Editor**, run `supabase/migrations/202610230001_catalog.sql` once. It creates `songs`, the `search_songs` function, and public `music` and `artwork` buckets. It intentionally fails rather than changing an existing table or bucket with those names. Inspect conflicting names before adapting the migration.
2. Put audio you have permission to stream in your public R2 bucket. Upload cover images to Supabase **Storage → artwork**. Public bucket files are accessible to anyone with their URLs.
3. Add song rows in **Table Editor → songs**. `audio_path` is the object path inside the R2 bucket, and `artwork_path` is the object path inside the Supabase artwork bucket. They are not full URLs or device file paths. Paths and filename case must match exactly. R2 files do not automatically create catalog rows.

Example (replace with paths you uploaded):

```sql
insert into public.songs (title, artist, album, audio_path, artwork_path, duration_ms)
values ('First Light', 'Your Artist', 'Morning Sessions',
        'your-artist/first-light.mp3', 'your-artist/morning.jpg', 183000);
```

Artwork and duration may be null. The player reads actual duration when audio loads. Missing covers use a placeholder. No commercial music or fabricated catalog entries are bundled.

### Scheduled sync

The GitHub Actions workflow `.github/workflows/sync-music.yml` checks R2 hourly and can also be run manually from GitHub Actions. It adds new songs to Supabase without changing or deleting existing songs. It reads embedded metadata and uploads embedded covers to R2; files are downloaded once when first imported. Songs without tags use their filenames and `Unknown Artist`. It does not identify untagged recordings. Existing song changes or deletions in R2 are not synchronized. Failed songs are retried on the next run.

Setup:

1. Run `supabase/migrations/202610300001_sync.sql` in the Supabase SQL Editor after the original catalog migration. It creates a sync-only function that is not executable by public app users.
2. In your GitHub repository settings, open **Secrets and variables → Actions → New repository secret**. Add `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `SUPABASE_URL`, and `SUPABASE_SECRET_KEY`. Use an R2 token with Object Read & Write scoped to the music bucket for cover uploads. Create a Supabase secret key in the project's API keys settings. These are server credentials: never put them in `config.json`, the app, or a public issue.
3. Commit and push the workflow, sync script, migration, and importer to the repository's default branch. In GitHub **Actions → Sync R2 music**, select **Run workflow** for the first run, and check the job log. After that, the schedule runs approximately hourly; GitHub can delay scheduled jobs. Refresh Sonify to see new songs. GitHub Actions must be enabled; schedules can be disabled after 60 days of inactivity in a public repository.

The phone app has no admin login, so it cannot securely trigger the job itself. Manual sync is available from GitHub Actions instead. This job only imports objects present in your R2 bucket and never deletes catalog rows. The Supabase secret key has broad project access; restrict access to GitHub repository secrets and rotate it if exposed.

### Manual bulk import from R2

The import tool reads existing song paths from Supabase, then lists audio objects in R2. It skips existing paths before downloading, and downloads new files temporarily to read their metadata. It creates a SQL file for review and does not change the database itself. Title falls back to the filename and artist to `Unknown Artist` when tags are missing. Downloading files uses bandwidth and R2 operations.

1. Ensure `config.json` contains your Supabase project URL and publishable key as described below. Alternatively set `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` in the terminal. The public catalog must allow that key to read all songs. In Cloudflare R2, find your **Account ID** and create an R2 API token scoped to `sonify-music` with object read/list access. Keep the access key and secret private; do not put them in the Flutter app or send them in chat.
2. In PowerShell, install the import dependencies and set the credentials for this terminal session:

```powershell
python -m pip install -r scripts/requirements-import.txt
$env:R2_ACCOUNT_ID = 'YOUR_ACCOUNT_ID'
$env:AWS_ACCESS_KEY_ID = 'YOUR_R2_ACCESS_KEY_ID'
$env:AWS_SECRET_ACCESS_KEY = 'YOUR_R2_SECRET_ACCESS_KEY'
python scripts/import_r2.py --bucket sonify-music
```

3. Review `r2-songs-import.sql`, correct missing metadata if needed, then paste its contents into the Supabase SQL Editor and run it. Refresh Sonify's catalog. Run the catalog migration first if the `songs` table does not exist. To limit the import to a folder, add `--prefix 'folder/'`. The generated SQL file is ignored by Git.

To extract embedded covers for new songs, use an R2 token with **Object Read & Write** access to the bucket, then run `python scripts/import_r2.py --bucket sonify-music --upload-covers`. The script uploads supported embedded JPEG, PNG and WebP covers to `sonify-artwork/` in the public R2 bucket, using content-based filenames. To also download and inspect existing songs to fill missing covers, add `--reprocess-existing`. Run the generated SQL in Supabase: it fills missing artwork without replacing existing artwork. Files without a supported embedded cover keep their current artwork or placeholder.

Close the terminal when finished to clear its environment variables. For a large bucket, allow time for the script to download the files one at a time.

### Find missing artists and covers

The title lookup understands filenames in `Title - Artist` and `Artist - Title` formats, including names with hyphens such as `Pa-umaga - Al James`. Try `python scripts/find_metadata.py find --limit 5 --csv metadata-review-check.csv` to test a few rows first. The review includes `lookup_status` and `lookup_note`: `suggested` needs review, `no_match` means the provider found no recording, `request_failed` describes a network/provider error, and `needs_fingerprint` means there was no usable title. Existing review files are backed up before regeneration. HTTP rate-limit and temporary server errors are retried.

With Supabase configured in `config.json`, run `python scripts/find_metadata.py find`. The script sends song titles and known artists to MusicBrainz and writes possible matches to `metadata-review.csv`. Open it in a spreadsheet, check each suggested title, artist, and MusicBrainz link, and set `approve` to `yes` only for correct matches. Numeric titles cannot be identified by title and need manual research. The script checks front-image availability and tries other releases when artwork is missing. If no release has a front cover, it leaves the cover URL blank and explains this in lookup_note. Open verified covers to check that they match before approving; third-party images can become unavailable later. Cover Art Archive is a third-party service and artwork may be subject to rights or availability restrictions.

Close the CSV, then run `python scripts/find_metadata.py sql`. Review `metadata-update.sql` and run it in the Supabase SQL Editor. Only missing artists and artwork are filled, and existing information is preserved. Rebuild Sonify to display Cover Art Archive images. The lookup does not identify recordings from their audio and may suggest the wrong version or artist.

For recordings without reliable titles, install Chromaprint `fpcalc` and obtain an AcoustID application client key. Set `ACOUSTID_CLIENT_KEY` along with the R2 read credentials shown above, and run `python scripts/find_metadata.py fingerprint` (or provide `--fpcalc` with the executable path). This downloads songs missing an artist or cover and sends audio fingerprints and durations to AcoustID; it does not upload the audio itself. Run `python scripts/find_metadata.py review` to select suggested matches in the desktop review window, then run `python scripts/find_metadata.py sql` and review the generated SQL before applying it. Review the CSV's MusicBrainz and cover links too; fingerprint matches can be wrong or have no cover. The SQL only replaces a title when it still matches its filename. AcoustID's free service is for noncommercial use and subject to its usage limits. This workflow requires a desktop and is not an in-app review screen.

4. Copy `config.example.json` to `config.json`. Fill in the Supabase project URL and **publishable** key from the dashboard. The R2 audio URL defaults to the configured public development bucket; change `R2_AUDIO_BASE_URL` to your R2 custom domain for production. A legacy `anon` key also works as the value. Never use a `service_role`, secret, database password, or administrative key. `config.json` is ignored by Git, but client configuration remains visible inside a built app: security comes from RLS/storage policies.
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
- Sort and artist/album filters load the full matching catalog before applying locally; large libraries may take longer to load. Library → Artists and Albums loads and groups the catalog.
- Playlists can have a description and a cover selected from their songs. Open a playlist's menu to edit these or add multiple songs.
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
