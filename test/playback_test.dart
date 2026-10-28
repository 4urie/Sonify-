import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:sonify/data.dart';
import 'package:sonify/playback.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(PlayerHarness.registerFallbacks);
  late PlayerHarness engine;
  late MemoryStore store;
  late SonifyAudioHandler audio;
  setUp(() {
    engine = PlayerHarness();
    store = MemoryStore();
    audio = SonifyAudioHandler(
      FakeCatalog(),
      Library(store),
      player: engine.player,
    );
  });
  tearDown(() async {
    await audio.dispose();
  });
  test(
    'manual skips follow shuffled order even with repeat-one enabled',
    () async {
      await audio.start([song('a'), song('b'), song('c')], 0);
      engine.shuffledOrder = [0, 2, 1];
      await audio.setShuffleMode(AudioServiceShuffleMode.all);
      await audio.setRepeatMode(AudioServiceRepeatMode.one);
      await audio.skipToNext();
      expect(audio.currentSong!.id, 'c');
      expect(engine.loop, LoopMode.one);
      await audio.skipToPrevious();
      expect(audio.currentSong!.id, 'a');
      await audio.setRepeatMode(AudioServiceRepeatMode.all);
      await audio.skipToPrevious();
      expect(audio.currentSong!.id, 'b');
      await audio.skipToNext();
      expect(audio.currentSong!.id, 'a');
    },
  );

  test(
    'queue edits preserve current song and position; duplicates have unique IDs',
    () async {
      await audio.start([song('a'), song('b'), song('c')], 1);
      engine.position = const Duration(seconds: 40);
      await audio.append(song('b'), next: true);
      expect(audio.entries.map((e) => e.song.id), ['a', 'b', 'b', 'c']);
      expect(audio.entries.map((e) => e.id).toSet().length, 4);
      await audio.move(1, 3);
      expect(audio.currentSong!.id, 'b');
      expect(audio.position.inSeconds, 40);
      await audio.removeAt(0);
      expect(audio.currentSong!.id, 'b');
      expect(audio.position.inSeconds, 40);
      await audio.clear();
      expect(audio.entries, isEmpty);
      expect(engine.playing, false);
    },
  );
  test('removing the current song advances to successor', () async {
    await audio.start([song('a'), song('b'), song('c')], 1);
    await audio.removeAt(1);
    expect(audio.currentSong!.id, 'c');
    expect(engine.position, Duration.zero);
    await audio.removeAt(1);
    await audio.removeAt(0);
    expect(audio.entries, isEmpty);
    expect(engine.playing, false);
  });
  test('rapid removals target entry IDs rather than stale indexes', () async {
    await audio.start([song('a'), song('b'), song('c')], 2);
    await Future.wait([audio.removeAt(0), audio.removeAt(1)]);
    expect(audio.entries.map((e) => e.song.id), ['c']);
    expect(audio.currentSong!.id, 'c');
  });
  test('pause during a pending start prevents late autoplay', () async {
    final loading = Completer<void>();
    engine.onLoad = () => loading.future;
    final starting = audio.start([song('a')], 0);
    await Future<void>.delayed(Duration.zero);
    await audio.pause();
    loading.complete();
    await starting;
    expect(engine.playCalls, 0);
    expect(engine.playing, false);
  });
  test(
    'previous restarts after three seconds and otherwise goes back',
    () async {
      await audio.start([song('a'), song('b')], 1);
      engine.position = const Duration(seconds: 5);
      await audio.skipToPrevious();
      expect(engine.current, 1);
      expect(engine.position, Duration.zero);
      await audio.skipToPrevious();
      expect(engine.current, 0);
      await audio.skipToPrevious();
      expect(engine.current, 0);
    },
  );
  test(
    'shuffle and repeat are mapped, queue boundary respects repeat all',
    () async {
      await audio.start([song('a'), song('b')], 1);
      await audio.setShuffleMode(AudioServiceShuffleMode.all);
      expect(engine.shuffle, true);
      await audio.setRepeatMode(AudioServiceRepeatMode.one);
      expect(engine.loop, LoopMode.one);
      await audio.setRepeatMode(AudioServiceRepeatMode.none);
      await audio.skipToNext();
      expect(engine.playing, false);
      await audio.setRepeatMode(AudioServiceRepeatMode.all);
      await audio.skipToNext();
      expect(engine.current, 0);
      await audio.setShuffleMode(AudioServiceShuffleMode.none);
      expect(engine.shuffle, false);
    },
  );
  test(
    'rapid selection suppresses an old in-flight load from starting playback',
    () async {
      final loading = Completer<void>();
      engine.onLoad = () => loading.future;
      final first = audio.start([song('a')], 0);
      await Future<void>.delayed(Duration.zero);
      final second = audio.start([song('b')], 0);
      engine.onLoad = null;
      loading.complete();
      await Future.wait([first, second]);
      expect(audio.currentSong!.id, 'b');
      expect(engine.playCalls, 1);
    },
  );
  test('clear invalidates pending collection pagination', () async {
    final page = Completer<List<Never>>();
    await audio.start([song('a')], 0, more: () => page.future);
    await audio.clear();
    page.complete([]);
    await Future<void>.delayed(Duration.zero);
    expect(audio.entries, isEmpty);
  });
  test(
    'restart restores position and modes paused without preloading audio',
    () async {
      await audio.start([song('a'), song('b')], 1);
      engine.position = const Duration(seconds: 42);
      await audio.setRepeatMode(AudioServiceRepeatMode.all);
      await audio.setShuffleMode(AudioServiceShuffleMode.all);
      await audio.pause();
      await audio.dispose();
      engine = PlayerHarness();
      audio = SonifyAudioHandler(
        FakeCatalog(),
        Library(store),
        player: engine.player,
      );
      await audio.initialize(configureSession: () async {});
      expect(audio.currentSong!.id, 'b');
      expect(engine.position.inSeconds, 42);
      expect(engine.shuffle, true);
      expect(engine.loop, LoopMode.all);
      expect(engine.playCalls, 0);
      expect(engine.preload, false);
    },
  );
  test('failed loads pause with an error and can be retried', () async {
    engine.onLoad = () async => throw Exception('network down');
    await audio.start([song('a')], 0);
    expect(audio.error, isNotNull);
    expect(engine.playing, false);
    engine.onLoad = null;
    await audio.retry();
    expect(audio.error, isNull);
    expect(engine.playing, true);
  });
  test('unavailable songs cannot start or join the queue', () async {
    await audio.start([song('a', available: false)], 0);
    await audio.append(song('b', available: false));
    expect(audio.entries, isEmpty);
  });
  test('initialization and disposal are idempotent', () async {
    var sessions = 0;
    await audio.initialize(
      configureSession: () async {
        sessions++;
      },
    );
    await audio.initialize(
      configureSession: () async {
        sessions++;
      },
    );
    expect(sessions, 1);
    await audio.dispose();
    await audio.dispose();
    expect(engine.disposed, 1);
    await audio.start([song('a')], 0);
    expect(engine.playCalls, 0);
  });
}
