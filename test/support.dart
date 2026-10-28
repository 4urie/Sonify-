import 'dart:convert';
import 'package:just_audio/just_audio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sonify/data.dart';
import 'package:sonify/models.dart';

Song song(String id, {bool available = true}) => Song(
  id: id,
  title: 'Track $id',
  artist: 'Artist $id',
  album: 'Album',
  audioPath: '$id.mp3',
  available: available,
);

class MemoryStore implements LocalStore {
  final Map<String, Map<String, dynamic>> values = {};
  @override
  Future<Map<String, dynamic>?> read(String key) async =>
      values[key] == null ? null : jsonDecode(jsonEncode(values[key]));
  @override
  Future<void> write(String key, Map<String, dynamic> value) async {
    values[key] = jsonDecode(jsonEncode(value));
  }

  @override
  Future<void> close() async {}
}

class FakeCatalog implements CatalogRepository {
  List<Song> songs = [];
  final List<String> queries = [];
  final List<int> offsets = [];
  bool fail = false;
  Future<List<Song>> Function(int, String)? fetchOverride;
  @override
  Future<List<Song>> fetch({int offset = 0, String query = ''}) async {
    queries.add(query);
    offsets.add(offset);
    if (fail) throw Exception('offline');
    if (fetchOverride != null) return fetchOverride!(offset, query);
    final result = songs
        .where(
          (s) =>
              s.title.toLowerCase().contains(query.toLowerCase()) ||
              s.artist.toLowerCase().contains(query.toLowerCase()),
        )
        .toList();
    return result.skip(offset).take(50).toList();
  }

  @override
  Future<List<Song>> resolve(List<String> ids) async {
    if (fail) throw Exception('offline');
    return songs.where((s) => ids.contains(s.id)).toList();
  }

  @override
  String audioUrl(Song song) => 'https://example.com/${song.audioPath}';
  @override
  String? artworkUrl(Song song) => null;
}

class MockPlayer extends Mock implements AudioPlayer {}

/// An in-memory engine double: native audio is covered by the device checklist.
class PlayerHarness {
  PlayerHarness() {
    when(() => player.currentIndex).thenAnswer((_) => current);
    when(() => player.position).thenAnswer((_) => position);
    when(() => player.duration).thenReturn(const Duration(minutes: 3));
    when(() => player.playing).thenAnswer((_) => playing);
    when(() => player.shuffleModeEnabled).thenAnswer((_) => shuffle);
    when(() => player.loopMode).thenAnswer((_) => loop);
    when(() => player.effectiveIndices).thenAnswer(
      (_) => shuffle && shuffledOrder != null
          ? shuffledOrder!
          : List.generate(count, (i) => i),
    );
    when(() => player.processingState).thenAnswer((_) => processing);
    when(() => player.bufferedPosition).thenReturn(Duration.zero);
    when(() => player.speed).thenReturn(1);
    when(
      () => player.hasNext,
    ).thenAnswer((_) => current != null && current! < count - 1);
    when(
      () => player.hasPrevious,
    ).thenAnswer((_) => current != null && current! > 0);
    when(() => player.positionStream).thenAnswer((_) => const Stream.empty());
    when(
      () => player.playbackEventStream,
    ).thenAnswer((_) => const Stream.empty());
    when(() => player.errorStream).thenAnswer((_) => const Stream.empty());
    when(
      () => player.playerStateStream,
    ).thenAnswer((_) => const Stream.empty());
    when(
      () => player.currentIndexStream,
    ).thenAnswer((_) => const Stream.empty());
    when(() => player.durationStream).thenAnswer((_) => const Stream.empty());
    when(
      () => player.setAudioSources(
        any(),
        initialIndex: any(named: 'initialIndex'),
        initialPosition: any(named: 'initialPosition'),
        preload: any(named: 'preload'),
        shuffleOrder: any(named: 'shuffleOrder'),
      ),
    ).thenAnswer((invocation) async {
      count = (invocation.positionalArguments.first as List).length;
      current = invocation.namedArguments[#initialIndex] as int? ?? 0;
      position =
          invocation.namedArguments[#initialPosition] as Duration? ??
          Duration.zero;
      preload = invocation.namedArguments[#preload] as bool? ?? true;
      if (onLoad != null) await onLoad!();
      processing = preload ? ProcessingState.ready : ProcessingState.idle;
      return const Duration(minutes: 3);
    });
    when(() => player.play()).thenAnswer((_) async {
      playing = true;
      playCalls++;
    });
    when(() => player.pause()).thenAnswer((_) async {
      playing = false;
    });
    when(() => player.stop()).thenAnswer((_) async {
      playing = false;
      processing = ProcessingState.idle;
    });
    when(() => player.dispose()).thenAnswer((_) async {
      disposed++;
    });
    when(() => player.shuffle()).thenAnswer((_) async {});
    when(() => player.setShuffleModeEnabled(any())).thenAnswer((i) async {
      shuffle = i.positionalArguments.first as bool;
    });
    when(() => player.setLoopMode(any())).thenAnswer((i) async {
      loop = i.positionalArguments.first as LoopMode;
    });
    when(() => player.seek(any(), index: any(named: 'index'))).thenAnswer((
      i,
    ) async {
      position = i.positionalArguments.first as Duration? ?? Duration.zero;
      current = i.namedArguments[#index] as int? ?? current;
    });
    when(() => player.seekToNext()).thenAnswer((_) async {
      current = current! + 1;
      position = Duration.zero;
    });
    when(() => player.seekToPrevious()).thenAnswer((_) async {
      current = current! - 1;
      position = Duration.zero;
    });
    when(() => player.insertAudioSource(any(), any())).thenAnswer((i) async {
      final at = i.positionalArguments.first as int;
      count++;
      if (current != null && at <= current!) current = current! + 1;
      current ??= 0;
    });
    when(() => player.addAudioSources(any())).thenAnswer((i) async {
      count += (i.positionalArguments.first as List).length;
    });
    when(() => player.removeAudioSourceAt(any())).thenAnswer((i) async {
      final at = i.positionalArguments.first as int;
      count--;
      if (current != null && at < current!) current = current! - 1;
      if (current != null && current! >= count) current = count - 1;
    });
    when(() => player.moveAudioSource(any(), any())).thenAnswer((i) async {
      final from = i.positionalArguments[0] as int;
      final to = i.positionalArguments[1] as int;
      if (current == from) {
        current = to;
      } else if (current != null && from < current! && to >= current!) {
        current = current! - 1;
      } else if (current != null && from > current! && to <= current!) {
        current = current! + 1;
      }
    });
    when(() => player.clearAudioSources()).thenAnswer((_) async {
      count = 0;
      current = null;
    });
  }
  final player = MockPlayer();
  int? current;
  int count = 0, playCalls = 0, disposed = 0;
  bool playing = false, shuffle = false, preload = true;
  Duration position = Duration.zero;
  LoopMode loop = LoopMode.off;
  List<int>? shuffledOrder;
  ProcessingState processing = ProcessingState.idle;
  Future<void> Function()? onLoad;
  static void registerFallbacks() {
    registerFallbackValue(Duration.zero);
    registerFallbackValue(LoopMode.off);
    registerFallbackValue(
      AudioSource.uri(Uri.parse('https://example.com/a.mp3')),
    );
  }
}
