import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'models.dart';

abstract interface class CatalogRepository {
  Future<List<Song>> fetch({int offset = 0, String query = ''});
  Future<List<Song>> resolve(List<String> ids);
  String audioUrl(Song song);
  String? artworkUrl(Song song);
}

class SupabaseCatalog implements CatalogRepository {
  SupabaseCatalog(this.client, {String? audioBaseUrl})
    : audioBaseUrl = audioBaseUrl == null ? null : Uri.parse(audioBaseUrl);
  final SupabaseClient client;
  final Uri? audioBaseUrl;
  @override
  Future<List<Song>> fetch({int offset = 0, String query = ''}) async {
    // RPC parameters keep punctuation out of PostgREST filter syntax.
    final rows = await client
        .rpc(
          'search_songs',
          params: {
            'search_term': query,
            'page_offset': offset,
            'page_size': 50,
          },
        )
        .timeout(const Duration(seconds: 20));
    return (rows as List)
        .map((j) => Song.fromJson(Map<String, dynamic>.from(j)))
        .toList();
  }

  @override
  Future<List<Song>> resolve(List<String> ids) async {
    if (ids.isEmpty) return [];
    final result = <Song>[];
    for (var i = 0; i < ids.length; i += 100) {
      final rows = await client
          .from('songs')
          .select()
          .inFilter('id', ids.sublist(i, (i + 100).clamp(0, ids.length)))
          .timeout(const Duration(seconds: 20));
      result.addAll(rows.map(Song.fromJson));
    }
    return result;
  }

  @override
  String audioUrl(Song song) {
    final base = audioBaseUrl;
    if (base == null) {
      return client.storage.from('music').getPublicUrl(song.audioPath);
    }
    return base
        .replace(
          pathSegments: [
            ...base.pathSegments.where((segment) => segment.isNotEmpty),
            ...song.audioPath.split('/'),
          ],
        )
        .toString();
  }

  @override
  String? artworkUrl(Song song) {
    final path = song.artworkPath;
    if (path == null) return null;
    final uri = Uri.tryParse(path);
    if (uri != null &&
        uri.scheme == 'https' &&
        uri.host == 'coverartarchive.org') {
      return path;
    }
    if (path.startsWith('r2:')) {
      final base = audioBaseUrl;
      if (base == null) return null;
      return base
          .replace(
            pathSegments: [
              ...base.pathSegments.where((segment) => segment.isNotEmpty),
              ...path.substring(3).split('/'),
            ],
          )
          .toString();
    }
    return client.storage.from('artwork').getPublicUrl(path);
  }
}

abstract interface class LocalStore {
  Future<Map<String, dynamic>?> read(String key);
  Future<void> write(String key, Map<String, dynamic> value);
  Future<void> close();
}

class SqliteStore implements LocalStore {
  SqliteStore(this.db);
  final Database db;
  static Future<SqliteStore> open() async => SqliteStore(
    await openDatabase(
      p.join(await getDatabasesPath(), 'sonify.db'),
      version: 1,
      onCreate: (db, version) => db.execute(
        'CREATE TABLE documents (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
      ),
    ),
  );
  @override
  Future<Map<String, dynamic>?> read(String key) async {
    final rows = await db.query(
      'documents',
      where: 'key = ?',
      whereArgs: [key],
    );
    return rows.isEmpty
        ? null
        : jsonDecode(rows.first['value'] as String) as Map<String, dynamic>;
  }

  @override
  Future<void> write(String key, Map<String, dynamic> value) async {
    await db.insert('documents', {
      'key': key,
      'value': encode(value),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> close() => db.close();
}

class Library extends ChangeNotifier {
  Library(this.store);
  final LocalStore store;
  final Map<String, Song> songs = {};
  final Set<String> favorites = {};
  final List<LocalPlaylist> playlists = [];
  final List<String> recent = [];
  String? error;
  Future<void> restore() async {
    final j = await store.read('library');
    if (j == null) return;
    for (final s in j['songs'] as List) {
      final song = Song.fromJson(s);
      songs[song.id] = song;
    }
    favorites.addAll(List<String>.from(j['favorites']));
    recent.addAll(List<String>.from(j['recent']));
    playlists.addAll(
      (j['playlists'] as List).map((j) => LocalPlaylist.fromJson(j)),
    );
  }

  Future<void> save() async {
    try {
      await store.write('library', {
        'songs': songs.values.map((s) => s.toJson()).toList(),
        'favorites': favorites.toList(),
        'recent': recent,
        'playlists': playlists.map((p) => p.toJson()).toList(),
      });
      error = null;
    } catch (_) {
      error = 'Could not save your library. Please try again.';
    }
    notifyListeners();
  }

  Future<void> cache(Iterable<Song> values) async {
    for (final s in values) {
      songs[s.id] = s;
    }
    await save();
  }

  Future<void> reconcile(CatalogRepository catalog) async {
    final ids = songs.keys.toList();
    final found = await catalog.resolve(ids);
    final map = {for (final s in found) s.id: s};
    for (final id in ids) {
      songs[id] = map[id] ?? songs[id]!.unavailable();
    }
    await save();
  }

  Future<void> favorite(Song s) async {
    songs[s.id] = s;
    if (!favorites.remove(s.id)) favorites.add(s.id);
    await save();
  }

  Future<void> played(Song s) async {
    songs[s.id] = s;
    recent.remove(s.id);
    recent.insert(0, s.id);
    if (recent.length > 100) recent.removeRange(100, recent.length);
    await save();
  }

  List<Song> lookup(Iterable<String> ids) =>
      ids.map((id) => songs[id]).whereType<Song>().toList();
  Future<void> createPlaylist(String name) async {
    playlists.add(
      LocalPlaylist(
        DateTime.now().microsecondsSinceEpoch.toString(),
        name.trim(),
        [],
      ),
    );
    await save();
  }
}
