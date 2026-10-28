# Sonify verification — 23 October 2026

## Local results

- Flutter 3.41.7 / Dart 3.11.5 on Windows.
- `flutter analyze`: no issues.
- `flutter test`: 29 passing tests covering catalog, search races, local library, SQLite reopening, playback commands, queue races, shuffle-aware Play next, restart restoration, disposal, and UI flows.
- `flutter build apk --debug`: successful Android development build. Output: `build/app/outputs/flutter-apk/app-debug.apk`.
- Phone layout rendered at 390 × 844 logical pixels with actual Roboto and Material icon fonts. Home, Now Playing, and Library previews inspected; an action-row overflow was fixed.
- Generated previews: `build/previews/sonify-home.png`, `sonify-playing.png`, `sonify-library.png`. These use clearly labeled test fixtures (`Track a`, etc.) and a simulated audio engine, not real streaming. Recreate them with `flutter test --dart-define=SONIFY_CAPTURE_PREVIEWS=true`.
- Kotlin incremental compilation is disabled in `android/gradle.properties` because this Windows environment places Pub sources on C: and the project on D:, causing Kotlin relative-path cache failures. The resulting build succeeds.

## Checks that require external setup

- The migration was delivered as SQL; it has not been applied to your existing Supabase project.
- No project URL/key or uploaded audio was provided. Real catalog/RPC/RLS and Storage streaming have not been exercised against your project.
- `flutter devices` found desktop/web targets only; `flutter emulators` reported no available emulators. Background audio, notification and lock-screen controls, headset buttons, focus interruptions, and device restart behavior therefore still require a physical Android device or an emulator.
- The APK was built without Supabase configuration and opens the setup screen. Follow the README and rebuild with `--dart-define-from-file=config.json` to connect your project.
- Unit/widget playback tests use an injected engine double. They verify app logic and state flow, not codecs, network audio, Android media integration, or audible output.

The complete real-service/device acceptance checklist is in the README.
