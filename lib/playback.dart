import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'data.dart';
import 'models.dart';
import 'shuffle_order.dart';

/// One app-scoped handler owns the only native playback engine.
class SonifyAudioHandler extends BaseAudioHandler with SeekHandler {
  SonifyAudioHandler(this.catalog, this.library, {AudioPlayer? player})
    : _player = player ?? AudioPlayer();
  final CatalogRepository catalog;
  final Library library;
  final AudioPlayer _player;
  final _shuffleOrder = SonifyShuffleOrder();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final errors = StreamController<String?>.broadcast();
  final List<QueueEntry> entries = [];
  Future<void>? _pending;
  Timer? _saveTimer;
  bool _disposed = false,
      _restoring = false,
      _initialized = false,
      _mutating = false;
  int _request = 0, _entrySerial = 0, _pauseGeneration = 0;
  String? _lastPlayed;
  String? error;
  Future<List<Song>> Function()? loadMore;
  bool _loadingMore = false;

  Stream<Duration> get positions => _player.positionStream;
  Duration get position => _player.position;
  Duration? get duration => _player.duration;
  bool get playing => _player.playing;
  int? get index => _player.currentIndex;
  bool get shuffled => _player.shuffleModeEnabled;
  LoopMode get loopMode => _player.loopMode;
  Song? get currentSong =>
      index != null && index! < entries.length ? entries[index!].song : null;

  Future<void> initialize({Future<void> Function()? configureSession}) async {
    if (_initialized || _disposed) return;
    _initialized = true;
    if (configureSession != null) {
      await configureSession();
    } else {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
    }
    // just_audio handles focus interruptions and becoming-noisy events.
    _subscriptions.add(
      _player.playbackEventStream.listen(
        (_) => _broadcast(),
        onError: (Object e, StackTrace s) => _fail(e),
      ),
    );
    _subscriptions.add(_player.errorStream.listen(_fail));
    _subscriptions.add(
      _player.playerStateStream.listen((_) {
        _broadcast();
        _recordPlayed();
      }),
    );
    _subscriptions.add(
      _player.currentIndexStream.listen((_) {
        _broadcast();
        _recordPlayed();
        _maybeLoadMore();
      }),
    );
    _subscriptions.add(_player.durationStream.listen((_) => _broadcast()));
    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_persist());
    });
    await _restore();
  }

  void _recordPlayed() {
    final song = currentSong;
    final entry = index != null && index! < entries.length
        ? entries[index!].id
        : null;
    if (!_restoring &&
        !_mutating &&
        playing &&
        _player.processingState == ProcessingState.ready &&
        song != null &&
        entry != _lastPlayed) {
      _lastPlayed = entry;
      unawaited(library.played(song));
    }
  }

  MediaItem _item(QueueEntry entry, {Duration? duration}) => MediaItem(
    id: entry.id,
    title: entry.song.title,
    artist: entry.song.artist,
    album: entry.song.album,
    artUri: catalog.artworkUrl(entry.song) == null
        ? null
        : Uri.parse(catalog.artworkUrl(entry.song)!),
    duration:
        duration ??
        (entry.song.durationMs == null
            ? null
            : Duration(milliseconds: entry.song.durationMs!)),
    extras: {'songId': entry.song.id},
  );
  AudioSource _source(QueueEntry entry) => AudioSource.uri(
    Uri.parse(catalog.audioUrl(entry.song)),
    tag: _item(entry),
  );
  QueueEntry _entry(Song s) => QueueEntry(
    '${DateTime.now().microsecondsSinceEpoch}-${_entrySerial++}',
    s,
  );

  void _broadcast() {
    if (_disposed || _mutating) return;
    queue.add(entries.map((e) => _item(e)).toList());
    final i = index;
    mediaItem.add(
      i != null && i < entries.length
          ? _item(entries[i], duration: duration)
          : null,
    );
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        systemActions: {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: [0, 1, 2],
        processingState: switch (_player.processingState) {
          ProcessingState.idle => AudioProcessingState.idle,
          ProcessingState.loading => AudioProcessingState.loading,
          ProcessingState.buffering => AudioProcessingState.buffering,
          ProcessingState.ready => AudioProcessingState.ready,
          ProcessingState.completed => AudioProcessingState.completed,
        },
        playing: playing,
        updatePosition: position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
        queueIndex: i,
        repeatMode: switch (loopMode) {
          LoopMode.off => AudioServiceRepeatMode.none,
          LoopMode.one => AudioServiceRepeatMode.one,
          LoopMode.all => AudioServiceRepeatMode.all,
        },
        shuffleMode: shuffled
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
      ),
    );
  }

  void _fail(Object e) {
    if (_disposed || e is PlayerInterruptedException) return;
    error =
        'Unable to stream this song. Check your connection, then retry or skip.';
    errors.add(error);
    unawaited(_player.pause());
    _broadcast();
  }

  void _clearError() {
    error = null;
    errors.add(null);
  }

  Future<void> _serialize(Future<void> Function() action) {
    final next = (_pending ?? Future<void>.value()).then((_) async {
      if (_disposed) return;
      _mutating = true;
      try {
        await action();
      } catch (e) {
        _fail(e);
      } finally {
        _mutating = false;
        if (!_disposed) {
          _broadcast();
          _recordPlayed();
          _maybeLoadMore();
          await _persist();
        }
      }
    });
    _pending = next;
    return next;
  }

  Future<void> start(
    List<Song> songs,
    int selected, {
    Future<List<Song>> Function()? more,
  }) {
    final request = ++_request;
    final pauseGeneration = _pauseGeneration;
    return _serialize(() async {
      if (request != _request ||
          songs.isEmpty ||
          selected < 0 ||
          selected >= songs.length) {
        return;
      }
      final selectedId = songs[selected].id;
      final available = songs.where((s) => s.available).toList();
      final startIndex = available.indexWhere((s) => s.id == selectedId);
      if (startIndex < 0) return;
      _clearError();
      loadMore = more;
      await _player.pause();
      entries
        ..clear()
        ..addAll(available.map(_entry));
      await _player.setAudioSources(
        entries.map(_source).toList(),
        initialIndex: startIndex,
        shuffleOrder: _shuffleOrder,
        preload: false,
      );
      if (request != _request) return;
      _broadcast();
      if (pauseGeneration == _pauseGeneration) unawaited(play());
      _maybeLoadMore();
      await _persist();
    });
  }

  void _maybeLoadMore() {
    if (_mutating ||
        _disposed ||
        loadMore == null ||
        _loadingMore ||
        index == null ||
        _player.effectiveIndices.indexOf(index!) < entries.length - 3) {
      return;
    }
    _loadingMore = true;
    final request = _request;
    final loader = loadMore!;
    unawaited(() async {
      try {
        final songs = await loader();
        if (request != _request || _disposed) return;
        if (songs.isEmpty) {
          loadMore = null;
          return;
        }
        await _serialize(() async {
          if (request != _request) return;
          final additions = songs
              .where((s) => s.available)
              .map(_entry)
              .toList();
          entries.addAll(additions);
          await _player.addAudioSources(additions.map(_source).toList());
          _broadcast();
        });
      } catch (_) {
        if (!_disposed) {
          error = 'Could not load more songs. Retry from the catalog.';
          errors.add(error);
        }
      } finally {
        _loadingMore = false;
      }
    }());
  }

  Future<void> append(Song song, {bool next = false}) => _serialize(() async {
    if (!song.available) return;
    final entry = _entry(song);
    final at = next && index != null ? index! + 1 : entries.length;
    entries.insert(at, entry);
    if (entries.length == 1) {
      await _player.setAudioSources(
        [_source(entry)],
        preload: false,
        shuffleOrder: _shuffleOrder,
      );
    } else {
      _shuffleOrder.insertAfter = next && shuffled ? index : null;
      try {
        await _player.insertAudioSource(at, _source(entry));
      } finally {
        _shuffleOrder.insertAfter = null;
      }
    }
    _broadcast();
    await _persist();
  });
  Future<void> removeAt(int at) {
    if (at < 0 || at >= entries.length) return Future.value();
    final id = entries[at].id;
    return _serialize(() async {
      final at = entries.indexWhere((entry) => entry.id == id);
      if (at < 0) return;
      final wasCurrent = index == at;
      final wasPlaying = playing;
      entries.removeAt(at);
      if (entries.isEmpty) {
        loadMore = null;
        ++_request;
        await _player.stop();
        await _player.clearAudioSources();
      } else {
        await _player.removeAudioSourceAt(at);
        if (wasCurrent) {
          await _player.seek(
            Duration.zero,
            index: at.clamp(0, entries.length - 1),
          );
          if (wasPlaying) unawaited(play());
        }
      }
      _broadcast();
      await _persist();
    });
  }

  Future<void> move(int from, int to) {
    if (from == to ||
        from < 0 ||
        from >= entries.length ||
        to < 0 ||
        to >= entries.length) {
      return Future.value();
    }
    final movingId = entries[from].id;
    final targetId = entries[to].id;
    return _serialize(() async {
      final from = entries.indexWhere((entry) => entry.id == movingId);
      final to = entries.indexWhere((entry) => entry.id == targetId);
      if (from < 0 || to < 0) return;
      final entry = entries.removeAt(from);
      entries.insert(to, entry);
      await _player.moveAudioSource(from, to);
      _broadcast();
      await _persist();
    });
  }

  Future<void> clear() {
    ++_request;
    loadMore = null;
    return _serialize(() async {
      await _player.stop();
      await _player.clearAudioSources();
      entries.clear();
      _clearError();
      _broadcast();
      await _persist();
    });
  }

  Future<void> retry() => _serialize(() async {
    if (entries.isEmpty) return;
    _clearError();
    await _player.setAudioSources(
      entries.map(_source).toList(),
      initialIndex: index ?? 0,
      initialPosition: position,
      shuffleOrder: _shuffleOrder,
      preload: false,
    );
    unawaited(play());
  });
  @override
  Future<void> play() async {
    if (_disposed || entries.isEmpty) return;
    final request = _request;
    try {
      _clearError();
      if (_player.processingState == ProcessingState.completed) {
        await _player.seek(Duration.zero);
      }
      await _player.play();
    } catch (e) {
      if (request == _request) _fail(e);
    }
  }

  @override
  Future<void> pause() async {
    ++_pauseGeneration;
    await _player.pause();
    await _persist();
  }

  @override
  Future<void> seek(Duration position) =>
      _serialize(() => _player.seek(position));
  @override
  Future<void> skipToQueueItem(int index) {
    if (index < 0 || index >= entries.length) return Future.value();
    final id = entries[index].id;
    return _serialize(() async {
      final index = entries.indexWhere((entry) => entry.id == id);
      if (index < 0) return;
      _clearError();
      await _player.seek(Duration.zero, index: index);
      unawaited(play());
    });
  }

  @override
  Future<void> skipToNext() => _serialize(() async {
    _clearError();
    final target = _adjacentIndex(1);
    if (target == null) {
      await _player.pause();
      return;
    }
    await _player.seek(Duration.zero, index: target);
    unawaited(play());
  });
  @override
  Future<void> skipToPrevious() => _serialize(() async {
    if (position > const Duration(seconds: 3)) {
      await _player.seek(Duration.zero);
    } else {
      await _player.seek(Duration.zero, index: _adjacentIndex(-1));
    }
  });

  // Native nextIndex repeats the current item under repeat-one. Manual skips
  // walk the effective (possibly shuffled) order without changing the mode.
  int? _adjacentIndex(int delta) {
    final order = _player.effectiveIndices;
    final at = order.indexOf(index ?? -1);
    if (at < 0 || order.isEmpty) return null;
    final next = at + delta;
    if (next >= 0 && next < order.length) return order[next];
    return loopMode == LoopMode.all ? order[next % order.length] : null;
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) =>
      _serialize(() async {
        if (shuffleMode != AudioServiceShuffleMode.none) {
          await _player.shuffle();
        }
        await _player.setShuffleModeEnabled(
          shuffleMode != AudioServiceShuffleMode.none,
        );
        _broadcast();
        await _persist();
      });
  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) =>
      _serialize(() async {
        await _player.setLoopMode(switch (repeatMode) {
          AudioServiceRepeatMode.one => LoopMode.one,
          AudioServiceRepeatMode.all ||
          AudioServiceRepeatMode.group => LoopMode.all,
          _ => LoopMode.off,
        });
        _broadcast();
        await _persist();
      });
  @override
  Future<void> stop() {
    ++_pauseGeneration;
    return _serialize(() async {
      await _persist();
      await _player.stop();
      await super.stop();
    });
  }

  @override
  Future<void> onTaskRemoved() async {
    if (!playing) await stop();
  }

  Future<void> _persist() async {
    if (_restoring || _disposed || _mutating) return;
    try {
      await library.store.write('playback', {
        'entries': entries.map((e) => e.toJson()).toList(),
        'index': index ?? 0,
        'position': position.inMilliseconds,
        'shuffle': shuffled,
        'repeat': loopMode.name,
      });
    } catch (_) {
      if (!_disposed) errors.add('Playback preferences could not be saved.');
    }
  }

  Future<void> _restore() async {
    _restoring = true;
    try {
      final j = await library.store.read('playback');
      if (j == null) return;
      entries.addAll((j['entries'] as List).map((e) => QueueEntry.fromJson(e)));
      await _player.setLoopMode(
        LoopMode.values.firstWhere(
          (m) => m.name == j['repeat'],
          orElse: () => LoopMode.off,
        ),
      );
      if (entries.isNotEmpty) {
        await _player.setAudioSources(
          entries.map(_source).toList(),
          preload: false,
          shuffleOrder: _shuffleOrder,
          initialIndex: (j['index'] as int).clamp(0, entries.length - 1),
          initialPosition: Duration(milliseconds: j['position'] as int),
        );
      }
      await _player.setShuffleModeEnabled(j['shuffle'] == true);
      _broadcast();
    } catch (_) {
      error = 'Could not restore playback. Choose a song to start again.';
    } finally {
      _restoring = false;
    }
  }

  /// Called only by the service owner, never by a route or mini-player.
  Future<void> dispose() async {
    if (_disposed) return;
    await _persist();
    _disposed = true;
    ++_request;
    _saveTimer?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _pending;
    await _player.dispose();
    // Closing broadcasts must not wait for an external paused subscriber.
    unawaited(errors.close());
    unawaited(queue.close());
    unawaited(mediaItem.close());
    unawaited(playbackState.close());
    unawaited(queueTitle.close());
    unawaited(androidPlaybackInfo.close());
    unawaited(ratingStyle.close());
    unawaited(customEvent.close());
    unawaited(customState.close());
  }
}
