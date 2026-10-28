import 'package:flutter_test/flutter_test.dart';
import 'package:sonify/data.dart';
import 'support.dart';

void main() {
  test(
    'favorites, playlist order and latest 100 distinct songs survive restart',
    () async {
      final store = MemoryStore();
      final library = Library(store);
      await library.favorite(song('a'));
      await library.createPlaylist('Night drive');
      await library.cache([song('b')]);
      library.playlists.single.songIds.addAll(['b', 'a']);
      for (var i = 0; i < 105; i++) {
        await library.played(song('$i'));
      }
      await library.played(song('10'));
      await library.save();
      final restored = Library(store);
      await restored.restore();
      expect(restored.favorites, {'a'});
      expect(restored.playlists.single.songIds, ['b', 'a']);
      expect(restored.recent.length, 100);
      expect(restored.recent.first, '10');
      expect(restored.recent.toSet().length, 100);
    },
  );
  test(
    'deleted catalog rows preserve favorites and playlists as unavailable',
    () async {
      final library = Library(MemoryStore());
      await library.favorite(song('a'));
      await library.createPlaylist('Saved');
      library.playlists.single.songIds.add('a');
      await library.reconcile(FakeCatalog());
      expect(library.songs['a']!.available, false);
      expect(library.favorites, contains('a'));
      expect(library.playlists.single.songIds, ['a']);
      final offline = FakeCatalog()..fail = true;
      await expectLater(library.reconcile(offline), throwsException);
      expect(library.songs['a']!.title, 'Track a');
      await library.reconcile(FakeCatalog()..songs = [song('a')]);
      expect(library.songs['a']!.available, true);
    },
  );
}
