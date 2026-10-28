import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sonify/data.dart';
import 'support.dart';

void main() {
  test(
    'SQLite round-trips library and playback across database reopen',
    () async {
      sqfliteFfiInit();
      final directory = await Directory.systemTemp.createTemp('sonify_test_');
      final path = '${directory.path}/library.db';
      Future<SqliteStore> open() async => SqliteStore(
        await databaseFactoryFfi.openDatabase(
          path,
          options: OpenDatabaseOptions(
            version: 1,
            onCreate: (db, _) => db.execute(
              'CREATE TABLE documents (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
            ),
          ),
        ),
      );
      var store = await open();
      final library = Library(store);
      await library.favorite(song('a'));
      await library.createPlaylist('SQLite playlist');
      await store.write('playback', {'position': 12345, 'shuffle': true});
      await store.close();
      store = await open();
      final restored = Library(store);
      await restored.restore();
      expect(restored.favorites, {'a'});
      expect(restored.playlists.single.name, 'SQLite playlist');
      expect((await store.read('playback'))!['position'], 12345);
      await store.close();
      await directory.delete(recursive: true);
    },
  );
}
