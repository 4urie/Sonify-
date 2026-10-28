import 'dart:async';
import 'package:flutter/foundation.dart';
import 'data.dart';
import 'models.dart';

class CatalogController extends ChangeNotifier {
  CatalogController(this.catalog, this.library);
  final CatalogRepository catalog;
  final Library library;
  final List<Song> songs = [];
  String query = '';
  bool loading = false, hasMore = true, offline = false;
  String? error;
  int _generation = 0;
  bool _disposed = false;
  Timer? _debounce;

  void search(String value) {
    _debounce?.cancel();
    ++_generation;
    query = value.trim();
    songs.clear();
    error = null;
    hasMore = true;
    loading = true;
    notifyListeners();
    _debounce = Timer(const Duration(milliseconds: 300), () => refresh());
  }

  Future<void> refresh() async {
    _debounce?.cancel();
    final generation = ++_generation;
    songs.clear();
    hasMore = true;
    loading = true;
    error = null;
    offline = false;
    notifyListeners();
    await _fetch(generation, 0);
  }

  Future<void> more() async {
    if (loading || !hasMore || offline) return;
    loading = true;
    error = null;
    notifyListeners();
    await _fetch(_generation, songs.length);
  }

  Future<void> _fetch(int generation, int offset) async {
    try {
      final page = await catalog.fetch(offset: offset, query: query);
      if (_disposed || generation != _generation) return;
      songs.addAll(page);
      hasMore = page.length == 50;
      await library.cache(page);
      if (offset == 0 && query.isEmpty) {
        // Only a successful lookup may mark a cached song as unavailable.
        try {
          await library.reconcile(catalog);
        } catch (_) {
          /* Keep cached state on connection loss. */
        }
      }
    } catch (_) {
      if (_disposed || generation != _generation) return;
      error =
          'Cannot reach your music catalog. Check your connection and try again.';
      if (offset == 0) {
        offline = true;
        final q = query.toLowerCase();
        songs.addAll(
          library.songs.values.where(
            (s) =>
                s.title.toLowerCase().contains(q) ||
                s.artist.toLowerCase().contains(q),
          ),
        );
      }
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _debounce?.cancel();
    super.dispose();
  }
}
