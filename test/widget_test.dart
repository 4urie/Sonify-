import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonify/data.dart';
import 'package:sonify/main.dart';
import 'package:sonify/playback.dart';
import 'package:sonify/screens.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    PlayerHarness.registerFallbacks();
    // Use SDK fonts so phone-sized layout checks exercise real glyph metrics.
    final configFile = File('.dart_tool/package_config.json');
    final packages =
        jsonDecode(await configFile.readAsString())['packages'] as List;
    final flutter = packages.firstWhere((p) => p['name'] == 'flutter');
    final flutterUri = configFile.absolute.uri.resolve(flutter['rootUri']);
    final root = Directory.fromUri(flutterUri).parent.parent.path;
    final fonts = '$root/bin/cache/artifacts/material_fonts';
    final text = FontLoader('Roboto');
    for (final name in [
      'roboto-regular.ttf',
      'roboto-medium.ttf',
      'roboto-bold.ttf',
    ]) {
      text.addFont(
        File(
          '$fonts/$name',
        ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
      );
    }
    await text.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(
        File(
          '$fonts/materialicons-regular.otf',
        ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
      );
    await icons.load();
  });
  late FakeCatalog catalog;
  late Library library;
  late SonifyAudioHandler audio;
  final previewKey = GlobalKey();
  setUp(() {
    catalog = FakeCatalog();
    library = Library(MemoryStore());
  });
  Future<void> mount(WidgetTester tester) async {
    // Construct asynchronous subjects in the same clock zone as widget pumping.
    audio = SonifyAudioHandler(
      catalog,
      library,
      player: PlayerHarness().player,
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      var done = false;
      final disposed = audio.dispose().then((_) => done = true);
      // Tear-down runs outside the fake clock. Drain both clock zones while
      // pending handler commands and stream cancellations finish.
      for (var i = 0; i < 20 && !done; i++) {
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      expect(done, isTrue, reason: 'Audio owner must finish disposal');
      await disposed;
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          catalogProvider.overrideWithValue(catalog),
          libraryProvider.overrideWith((ref) => library),
          audioProvider.overrideWithValue(audio),
        ],
        child: RepaintBoundary(key: previewKey, child: const SonifyApp()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('missing configuration explains setup without native plugins', (
    tester,
  ) async {
    await tester.pumpWidget(
      const SonifyApp(
        startupMessage: 'Sonify needs your music connection',
        startupDetails: 'Configure Supabase.',
      ),
    );
    expect(find.text('Sonify needs your music connection'), findsOneWidget);
  });
  testWidgets('phone layout supports home, playing and library', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    catalog.songs = [song('a'), song('b'), song('c')];
    await mount(tester);
    Future<void> capture(String name) async {
      if (!const bool.fromEnvironment('SONIFY_CAPTURE_PREVIEWS')) return;
      final boundary =
          previewKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final directory = Directory('build/previews');
        await directory.create(recursive: true);
        await File(
          '${directory.path}/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await capture('sonify-home');
    await audio.start(catalog.songs, 0);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(MiniPlayer),
        matching: find.text('Track a'),
      ),
    );
    await tester.pumpAndSettle();
    await capture('sonify-playing');
    expect(tester.takeException(), isNull);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();
    await capture('sonify-library');
    expect(tester.takeException(), isNull);
  });
  testWidgets('empty catalog and bottom navigation work', (tester) async {
    await mount(tester);
    expect(find.text('Your soundtrack starts here'), findsOneWidget);
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    expect(find.text('No songs found'), findsOneWidget);
    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();
    expect(find.text('Your library'), findsOneWidget);
  });
  testWidgets('search filters by artist', (tester) async {
    catalog.songs = [song('a'), song('b')];
    await mount(tester);
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Artist b');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('Track b'), findsOneWidget);
    expect(find.text('Track a'), findsNothing);
  });
  testWidgets('offline state offers retry', (tester) async {
    catalog.fail = true;
    await mount(tester);
    expect(find.text('You’re viewing saved music'), findsOneWidget);
    catalog.fail = false;
    await tester.drag(
      find.byType(CustomScrollView).first,
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Your soundtrack starts here'), findsOneWidget);
  });
  testWidgets('mini player persists across tabs and opens Now Playing', (
    tester,
  ) async {
    catalog.songs = [song('a')];
    await mount(tester);
    await audio.start(catalog.songs, 0);
    await tester.pumpAndSettle();
    expect(find.byType(MiniPlayer), findsOneWidget);
    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();
    expect(find.text('Track a'), findsOneWidget);
    await tester.tap(find.text('Track a'));
    await tester.pumpAndSettle();
    expect(find.text('NOW PLAYING'), findsOneWidget);
    expect(find.text('Album'), findsOneWidget);
    await tester.tap(find.byTooltip('Open queue'));
    await tester.pumpAndSettle();
    expect(find.text('Play queue'), findsOneWidget);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(find.text('Room for your next favorite'), findsOneWidget);
  });
  testWidgets('playlist can be created, renamed and track removed', (
    tester,
  ) async {
    await library.createPlaylist('Road trip');
    await library.cache([song('a')]);
    library.playlists.single.songIds.add('a');
    await library.save();
    await mount(tester);
    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Road trip'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Remove from playlist'));
    await tester.pumpAndSettle();
    expect(find.text('Nothing here yet'), findsOneWidget);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Night drive');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('Night drive'), findsOneWidget);
  });
}
