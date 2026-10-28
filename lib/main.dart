import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'data.dart';
import 'playback.dart';
import 'screens.dart';

final catalogProvider = Provider<CatalogRepository>(
  (ref) => throw UnimplementedError(),
);
final libraryProvider = ChangeNotifierProvider<Library>(
  (ref) => throw UnimplementedError(),
);
final audioProvider = Provider<SonifyAudioHandler>(
  (ref) => throw UnimplementedError(),
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const url = String.fromEnvironment('SUPABASE_URL');
  const key = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty || key.isEmpty) {
    runApp(
      const SonifyApp(
        startupMessage: 'Sonify needs your music connection',
        startupDetails:
            'Add your Supabase project URL and publishable key using the configuration template in the README, then rebuild the app.',
      ),
    );
    return;
  }
  SqliteStore? store;
  SonifyAudioHandler? handler;
  try {
    await Supabase.initialize(url: url, publishableKey: key);
    store = await SqliteStore.open();
    final library = Library(store);
    await library.restore();
    const audioBaseUrl = String.fromEnvironment(
      'R2_AUDIO_BASE_URL',
      defaultValue: 'https://pub-5fd8c445ba6d49db92d81fea14e3e2c9.r2.dev',
    );
    final catalog = SupabaseCatalog(
      Supabase.instance.client,
      audioBaseUrl: audioBaseUrl,
    );
    handler = await AudioService.init<SonifyAudioHandler>(
      builder: () => SonifyAudioHandler(catalog, library),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.example.sonify.playback',
        androidNotificationChannelName: 'Sonify playback',
        androidNotificationIcon: 'drawable/ic_notification',
        androidStopForegroundOnPause: false,
      ),
    );
    await handler.initialize();
    runApp(
      ProviderScope(
        overrides: [
          catalogProvider.overrideWithValue(catalog),
          libraryProvider.overrideWith((ref) => library),
          audioProvider.overrideWithValue(handler),
        ],
        child: const SonifyApp(),
      ),
    );
    unawaited(library.reconcile(catalog).catchError((Object _) {}));
  } catch (_) {
    await handler?.dispose();
    await store?.close();
    runApp(
      const SonifyApp(
        startupMessage: 'Sonify could not start',
        startupDetails:
            'Close and reopen the app to retry. Check that device storage is available and your Supabase configuration is correct.',
      ),
    );
  }
}

class SonifyApp extends StatelessWidget {
  const SonifyApp({super.key, this.startupMessage, this.startupDetails});
  final String? startupMessage, startupDetails;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Sonify',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xFF101311),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF67E8A5),
        brightness: Brightness.dark,
        primary: const Color(0xFF67E8A5),
        surface: const Color(0xFF191E1B),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF101311),
        centerTitle: false,
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: Color(0xFF141815),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
      ),
    ),
    home: startupMessage == null
        ? const Shell()
        : Scaffold(
            body: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.graphic_eq_rounded,
                        size: 72,
                        color: Color(0xFF67E8A5),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        startupMessage!,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      Text(startupDetails ?? '', textAlign: TextAlign.center),
                    ],
                  ),
                ),
              ),
            ),
          ),
  );
}
