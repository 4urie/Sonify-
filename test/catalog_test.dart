import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonify/catalog_controller.dart';
import 'package:sonify/data.dart';
import 'package:sonify/models.dart';
import 'support.dart';

void main() {
  test('catalog pages in 50s without duplicate in-flight loads', () async {
    final catalog = FakeCatalog()
      ..songs = List.generate(101, (i) => song('$i'));
    final controller = CatalogController(catalog, Library(MemoryStore()));
    await controller.refresh();
    expect(controller.songs.length, 50);
    await Future.wait([controller.more(), controller.more()]);
    expect(controller.songs.length, 100);
    await controller.more();
    expect(controller.hasMore, false);
    expect(catalog.offsets, [0, 50, 100]);
    controller.dispose();
  });
  testWidgets(
    'search debounces and discards stale responses, including punctuation',
    (tester) async {
      final old = Completer<List<Song>>();
      final catalog = FakeCatalog()
        ..fetchOverride = (_, query) =>
            query == 'old' ? old.future : Future.value([song(query)]);
      final controller = CatalogController(catalog, Library(MemoryStore()));
      controller.search('old');
      await tester.pump(const Duration(milliseconds: 301));
      controller.search('new');
      await tester.pump(const Duration(milliseconds: 150));
      controller.search('A,B (100%)');
      await tester.pump(const Duration(milliseconds: 301));
      expect(catalog.queries, ['old', 'A,B (100%)']);
      old.complete([song('old')]);
      await tester.pump();
      expect(controller.songs.single.id, 'A,B (100%)');
      expect(controller.loading, false);
      controller.dispose();
    },
  );
  test('offline retains cached details and retry refreshes', () async {
    final library = Library(MemoryStore());
    await library.cache([song('cached')]);
    final catalog = FakeCatalog()..fail = true;
    final controller = CatalogController(catalog, library);
    await controller.refresh();
    expect(controller.offline, true);
    expect(controller.songs.single.id, 'cached');
    catalog
      ..fail = false
      ..songs = [song('online')];
    await controller.refresh();
    expect(controller.offline, false);
    expect(controller.songs.single.id, 'online');
    controller.dispose();
  });
  test('disposing during fetch ignores completion', () async {
    final pending = Completer<List<Song>>();
    final catalog = FakeCatalog()..fetchOverride = (_, _) => pending.future;
    final controller = CatalogController(catalog, Library(MemoryStore()));
    final result = controller.refresh();
    controller.dispose();
    pending.complete([song('a')]);
    await result;
    expect(controller.songs, isEmpty);
  });
}
