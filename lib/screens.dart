import 'dart:async';
import 'dart:math';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'catalog_controller.dart';
import 'main.dart';
import 'models.dart';
import 'playback.dart';

class Shell extends ConsumerStatefulWidget {
  const Shell({super.key});
  @override
  ConsumerState<Shell> createState() => _ShellState();
}

class _ShellState extends ConsumerState<Shell> with WidgetsBindingObserver {
  int tab = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(
        ref
            .read(libraryProvider)
            .reconcile(ref.read(catalogProvider))
            .catchError((Object _) {}),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(libraryProvider);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: IndexedStack(
                index: tab,
                children: const [
                  CatalogScreen(),
                  CatalogScreen(search: true),
                  LibraryScreen(),
                ],
              ),
            ),
            if (library.error != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(library.error!),
              ),
            const PlaybackError(),
            const MiniPlayer(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
          NavigationDestination(
            icon: Icon(Icons.library_music_outlined),
            selectedIcon: Icon(Icons.library_music),
            label: 'Library',
          ),
        ],
      ),
    );
  }
}

class CatalogScreen extends ConsumerStatefulWidget {
  const CatalogScreen({super.key, this.search = false});
  final bool search;
  @override
  ConsumerState<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends ConsumerState<CatalogScreen> {
  late final CatalogController controller;
  String sort = 'recent';
  List<Song> get displayedSongs {
    final result = List<Song>.of(controller.songs);
    if (sort == 'title') {
      result.sort(
        (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      );
    } else if (sort == 'artist') {
      result.sort(
        (a, b) => a.artist.toLowerCase().compareTo(b.artist.toLowerCase()),
      );
    }
    return result;
  }

  @override
  void initState() {
    super.initState();
    controller = CatalogController(
      ref.read(catalogProvider),
      ref.read(libraryProvider),
    );
    unawaited(controller.refresh());
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> start(int i, {bool shuffle = false}) async {
    final snapshot = displayedSongs;
    final query = controller.query;
    var offset = snapshot.length;
    final catalog = ref.read(catalogProvider);
    final library = ref.read(libraryProvider);
    final audio = ref.read(audioProvider);
    if (shuffle) await audio.setShuffleMode(AudioServiceShuffleMode.all);
    await audio.start(
      snapshot,
      i,
      more: controller.hasMore && !controller.offline
          ? () async {
              final page = await catalog.fetch(offset: offset, query: query);
              offset += page.length;
              await library.cache(page);
              return page;
            }
          : null,
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => RefreshIndicator(
      onRefresh: controller.refresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(24, 26, 24, 16),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Image.asset(
                    'assets/branding/logo.png',
                    width: 190,
                    height: 67,
                    fit: BoxFit.contain,
                    semanticLabel: 'Sonify',
                  ),
                  const SizedBox(height: 28),
                  Text(
                    widget.search
                        ? 'Find your next favorite.'
                        : 'Your world.\nYour soundtrack.',
                    style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (widget.search)
                    TextField(
                      onChanged: controller.search,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Songs or artists',
                        labelText: 'Search music',
                      ),
                    )
                  else
                    Text(
                      'Fresh sounds, familiar favorites. Make yourself at home.',
                      style: TextStyle(color: Colors.grey.shade400),
                    ),
                  if (!widget.search) ...[
                    const SizedBox(height: 24),
                    const _RecentStrip(),
                    if (controller.songs.any((song) => song.available)) ...[
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: () {
                          final indices = [
                            for (var i = 0; i < displayedSongs.length; i++)
                              if (displayedSongs[i].available) i,
                          ];
                          if (indices.isNotEmpty) {
                            unawaited(
                              start(
                                indices[Random().nextInt(indices.length)],
                                shuffle: true,
                              ),
                            );
                          }
                        },
                        icon: const Icon(Icons.shuffle),
                        label: const Text('Shuffle loaded songs'),
                      ),
                    ],
                  ],
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.search ? 'Results' : 'Made for your listening',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Refresh catalog',
                        onPressed: controller.refresh,
                        icon: const Icon(Icons.refresh),
                      ),
                      PopupMenuButton<String>(
                        tooltip: 'Sort loaded songs',
                        initialValue: sort,
                        onSelected: (value) => setState(() => sort = value),
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'recent',
                            child: Text('Recently added'),
                          ),
                          PopupMenuItem(
                            value: 'title',
                            child: Text('Title A–Z'),
                          ),
                          PopupMenuItem(
                            value: 'artist',
                            child: Text('Artist A–Z'),
                          ),
                        ],
                        icon: const Icon(Icons.sort),
                      ),
                    ],
                  ),
                  if (sort != 'recent')
                    const Text(
                      'Sorting loaded songs',
                      style: TextStyle(color: Colors.grey),
                    ),
                  if (controller.error != null)
                    _Message(
                      icon: Icons.cloud_off,
                      title: controller.offline
                          ? 'You’re viewing saved music'
                          : 'Could not load more',
                      text: controller.error!,
                      onRetry: controller.refresh,
                    ),
                ],
              ),
            ),
          ),
          if (controller.songs.isEmpty &&
              !controller.loading &&
              controller.error == null)
            SliverToBoxAdapter(
              child: _Message(
                icon: Icons.music_note_outlined,
                title: widget.search
                    ? 'No songs found'
                    : 'Your soundtrack starts here',
                text: widget.search
                    ? 'Try another title or artist.'
                    : 'Add your R2 music paths to the Supabase songs catalog.',
              ),
            ),
          SliverList.builder(
            itemCount: displayedSongs.length,
            itemBuilder: (context, i) =>
                SongTile(song: displayedSongs[i], onPlay: () => start(i)),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: controller.loading
                    ? const CircularProgressIndicator()
                    : controller.hasMore && !controller.offline
                    ? OutlinedButton(
                        onPressed: controller.more,
                        child: const Text('Load more'),
                      )
                    : const SizedBox(height: 16),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _RecentStrip extends ConsumerWidget {
  const _RecentStrip();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final songs = ref
        .watch(libraryProvider)
        .lookup(ref.watch(libraryProvider).recent)
        .take(8)
        .toList();
    if (songs.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: const LinearGradient(
            colors: [Color(0xFF224A35), Color(0xFF19271F)],
          ),
        ),
        child: const Row(
          children: [
            Icon(Icons.headphones, size: 40, color: Color(0xFF67E8A5)),
            SizedBox(width: 18),
            Expanded(
              child: Text(
                'A little louder.\nA little more you.',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Back in rotation', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 14),
        SizedBox(
          height: 158,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: songs.length,
            separatorBuilder: (_, _) => const SizedBox(width: 14),
            itemBuilder: (context, i) => SizedBox(
              width: 115,
              child: InkWell(
                onTap: songs[i].available
                    ? () => ref.read(audioProvider).start(songs, i)
                    : null,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Artwork(song: songs[i], size: 110),
                    const SizedBox(height: 8),
                    Text(
                      songs[i].title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      songs[i].artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class Artwork extends ConsumerWidget {
  const Artwork({super.key, required this.song, this.size = 52});
  final Song song;
  final double size;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = ref.read(catalogProvider).artworkUrl(song);
    final placeholder = Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF31553D), Color(0xFF253038)],
        ),
      ),
      child: Icon(
        Icons.graphic_eq_rounded,
        size: size * .42,
        color: const Color(0xFF89E6AF),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: url == null
          ? placeholder
          : Image.network(
              url,
              width: size,
              height: size,
              fit: BoxFit.cover,
              excludeFromSemantics: true,
              errorBuilder: (_, _, _) => placeholder,
            ),
    );
  }
}

class SongTile extends ConsumerWidget {
  const SongTile({
    super.key,
    required this.song,
    required this.onPlay,
    this.trailing,
  });
  final Song song;
  final VoidCallback onPlay;
  final Widget? trailing;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final effective = ref.watch(libraryProvider).songs[song.id] ?? song;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      leading: Artwork(song: effective),
      title: Text(
        effective.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        effective.available
            ? (effective.album.isEmpty
                  ? effective.artist
                  : '${effective.artist} • ${effective.album}')
            : '${effective.artist} • Unavailable',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: effective.available ? onPlay : null,
      trailing:
          trailing ??
          PopupMenuButton<String>(
            tooltip: 'Song options',
            onSelected: (action) async {
              final library = ref.read(libraryProvider);
              final audio = ref.read(audioProvider);
              switch (action) {
                case 'favorite':
                  await library.favorite(effective);
                case 'next':
                  await audio.append(effective, next: true);
                case 'queue':
                  await audio.append(effective);
                case 'playlist':
                  if (context.mounted) {
                    await choosePlaylist(context, ref, effective);
                  }
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'favorite',
                child: Text(
                  ref.read(libraryProvider).favorites.contains(song.id)
                      ? 'Remove favorite'
                      : 'Add to favorites',
                ),
              ),
              PopupMenuItem(
                value: 'next',
                enabled: effective.available,
                child: const Text('Play next'),
              ),
              PopupMenuItem(
                value: 'queue',
                enabled: effective.available,
                child: const Text('Add to queue'),
              ),
              const PopupMenuItem(
                value: 'playlist',
                child: Text('Add to playlist'),
              ),
            ],
          ),
    );
  }
}

Future<String?> askName(
  BuildContext context, {
  String initial = '',
  String title = 'New playlist',
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 80,
        decoration: const InputDecoration(labelText: 'Playlist name'),
        onSubmitted: (v) {
          if (v.trim().isNotEmpty) Navigator.pop(context, v.trim());
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            if (controller.text.trim().isNotEmpty) {
              Navigator.pop(context, controller.text.trim());
            }
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
  // Dialog route may still be animating while its Future completes.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  controller.dispose();
  return result;
}

Future<void> choosePlaylist(
  BuildContext context,
  WidgetRef ref,
  Song song,
) async {
  final library = ref.read(libraryProvider);
  final id = await showModalBottomSheet<String>(
    context: context,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const ListTile(title: Text('Add to playlist')),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('New playlist'),
            onTap: () => Navigator.pop(context, 'new'),
          ),
          for (final p in library.playlists)
            ListTile(
              title: Text(p.name),
              onTap: () => Navigator.pop(context, p.id),
            ),
        ],
      ),
    ),
  );
  if (id == null) return;
  LocalPlaylist? playlist;
  if (id == 'new') {
    if (!context.mounted) return;
    final name = await askName(context);
    if (name == null) return;
    await library.createPlaylist(name);
    playlist = library.playlists.last;
  } else {
    playlist = library.playlists.where((p) => p.id == id).firstOrNull;
  }
  if (playlist == null) return;
  library.songs[song.id] = song;
  if (!playlist.songIds.contains(song.id)) playlist.songIds.add(song.id);
  await library.save();
}

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(libraryProvider);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 24),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            children: [
              Text(
                'Your library',
                style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Create playlist',
                icon: const Icon(Icons.add),
                onPressed: () async {
                  final name = await askName(context);
                  if (name != null) await library.createPlaylist(name);
                },
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Text(
            'The music you keep coming back to.',
            style: TextStyle(color: Colors.grey),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.favorite, color: Color(0xFF67E8A5)),
          title: const Text('Liked songs'),
          subtitle: Text('${library.favorites.length} songs'),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => const CollectionScreen(kind: 'favorites'),
            ),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.history),
          title: const Text('Recently played'),
          subtitle: Text('${library.recent.length} songs'),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => const CollectionScreen(kind: 'recent'),
            ),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.person_outline, color: Color(0xFF67E8A5)),
          title: const Text('Artists'),
          subtitle: const Text('Play songs by the same artist'),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const ArtistsScreen()),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 28, 24, 12),
          child: Text(
            'YOUR PLAYLISTS',
            style: TextStyle(letterSpacing: 2, color: Colors.grey),
          ),
        ),
        if (library.playlists.isEmpty)
          const _Message(
            icon: Icons.queue_music,
            title: 'Keep a mood on repeat',
            text: 'Create a playlist, then add songs from their options menu.',
          ),
        for (final p in library.playlists)
          ListTile(
            leading: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF273C30),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.queue_music),
            ),
            title: Text(p.name),
            subtitle: Text('${p.songIds.length} songs • On this device'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => CollectionScreen(kind: p.id)),
            ),
          ),
      ],
    );
  }
}

class ArtistsScreen extends ConsumerStatefulWidget {
  const ArtistsScreen({super.key});
  @override
  ConsumerState<ArtistsScreen> createState() => _ArtistsScreenState();
}

class _ArtistsScreenState extends ConsumerState<ArtistsScreen> {
  late Future<List<Song>> songs;

  @override
  void initState() {
    super.initState();
    songs = load();
  }

  Future<List<Song>> load() async {
    final result = <Song>[];
    final catalog = ref.read(catalogProvider);
    final library = ref.read(libraryProvider);
    while (true) {
      final page = await catalog.fetch(offset: result.length);
      result.addAll(page);
      if (page.length < 50) break;
    }
    await library.cache(result);
    return result;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Artists')),
    body: Column(
      children: [
        Expanded(
          child: FutureBuilder<List<Song>>(
            future: songs,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return _Message(
                  icon: Icons.cloud_off,
                  title: 'Could not load artists',
                  text: 'Check your connection and try again.',
                  onRetry: () => setState(() => songs = load()),
                );
              }
              final groups = <String, List<Song>>{};
              final names = <String, String>{};
              for (final song in snapshot.data ?? <Song>[]) {
                final name = song.artist.trim();
                final key = name.toLowerCase();
                if (key.isEmpty || key == 'unknown artist') continue;
                names.putIfAbsent(key, () => name);
                groups.putIfAbsent(key, () => []).add(song);
              }
              final keys = groups.keys.toList()..sort();
              if (keys.isEmpty) {
                return const _Message(
                  icon: Icons.person_outline,
                  title: 'No artists yet',
                  text: 'Add artist names to your songs to see them here.',
                );
              }
              return ListView.builder(
                itemCount: keys.length,
                itemBuilder: (context, i) {
                  final key = keys[i];
                  final artistSongs = groups[key]!;
                  return ListTile(
                    leading: Artwork(song: artistSongs.first),
                    title: Text(names[key]!),
                    subtitle: Text('${artistSongs.length} songs'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ArtistSongsScreen(
                          artist: names[key]!,
                          songs: artistSongs,
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
        const PlaybackError(),
        const MiniPlayer(),
      ],
    ),
  );
}

class ArtistSongsScreen extends ConsumerWidget {
  const ArtistSongsScreen({
    super.key,
    required this.artist,
    required this.songs,
  });
  final String artist;
  final List<Song> songs;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: Text(artist)),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: () async {
                final available = songs
                    .where((song) => song.available)
                    .toList();
                if (available.isEmpty) return;
                final audio = ref.read(audioProvider);
                await audio.setShuffleMode(AudioServiceShuffleMode.all);
                await audio.start(
                  available,
                  Random().nextInt(available.length),
                );
              },
              icon: const Icon(Icons.shuffle),
              label: const Text('Shuffle artist'),
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: songs.length,
            itemBuilder: (context, i) => SongTile(
              song: songs[i],
              onPlay: () => ref.read(audioProvider).start(songs, i),
            ),
          ),
        ),
        const PlaybackError(),
        const MiniPlayer(),
      ],
    ),
  );
}

class CollectionScreen extends ConsumerWidget {
  const CollectionScreen({super.key, required this.kind});
  final String kind;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(libraryProvider);
    final playlist = library.playlists.where((p) => p.id == kind).firstOrNull;
    final ids = kind == 'favorites'
        ? library.favorites.toList()
        : kind == 'recent'
        ? library.recent
        : playlist?.songIds ?? <String>[];
    final songs = library.lookup(ids);
    final title = kind == 'favorites'
        ? 'Liked songs'
        : kind == 'recent'
        ? 'Recently played'
        : playlist?.name ?? 'Playlist';
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (playlist != null)
            PopupMenuButton<String>(
              onSelected: (action) async {
                if (action == 'rename') {
                  final name = await askName(
                    context,
                    initial: playlist.name,
                    title: 'Rename playlist',
                  );
                  if (name != null) {
                    playlist.name = name;
                    await library.save();
                  }
                } else {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Delete playlist?'),
                      content: Text(
                        'Remove “${playlist.name}” from this device?',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    library.playlists.remove(playlist);
                    await library.save();
                    if (context.mounted) Navigator.pop(context);
                  }
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('Rename')),
                PopupMenuItem(value: 'delete', child: Text('Delete playlist')),
              ],
            ),
        ],
      ),
      body: Column(
        children: [
          if (songs.any((song) => song.available))
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: () async {
                    final indices = [
                      for (var i = 0; i < songs.length; i++)
                        if (songs[i].available) i,
                    ];
                    final audio = ref.read(audioProvider);
                    await audio.setShuffleMode(AudioServiceShuffleMode.all);
                    await audio.start(
                      songs,
                      indices[Random().nextInt(indices.length)],
                    );
                  },
                  icon: const Icon(Icons.shuffle),
                  label: const Text('Shuffle'),
                ),
              ),
            ),
          Expanded(
            child: songs.isEmpty
                ? const _Message(
                    icon: Icons.library_music_outlined,
                    title: 'Nothing here yet',
                    text: 'Add a song from the catalog to get started.',
                  )
                : ReorderableListView.builder(
                    buildDefaultDragHandles: false,
                    itemCount: songs.length,
                    onReorder: (from, to) {
                      if (playlist == null) return;
                      if (to > from) to--;
                      final id = playlist.songIds.removeAt(from);
                      playlist.songIds.insert(to, id);
                      unawaited(library.save());
                    },
                    itemBuilder: (context, i) => SongTile(
                      key: ValueKey(songs[i].id),
                      song: songs[i],
                      onPlay: () => ref.read(audioProvider).start(songs, i),
                      trailing: playlist == null
                          ? null
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: 'Remove from playlist',
                                  icon: const Icon(Icons.remove_circle_outline),
                                  onPressed: () {
                                    playlist.songIds.removeAt(i);
                                    unawaited(library.save());
                                  },
                                ),
                                ReorderableDragStartListener(
                                  index: i,
                                  child: const Padding(
                                    padding: EdgeInsets.all(8),
                                    child: Icon(Icons.drag_handle),
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),
          ),
          const PlaybackError(),
          const MiniPlayer(),
        ],
      ),
    );
  }
}

class PlaybackError extends ConsumerWidget {
  const PlaybackError({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final audio = ref.read(audioProvider);
    return StreamBuilder<String?>(
      stream: audio.errors.stream,
      initialData: audio.error,
      builder: (context, snapshot) => snapshot.data == null
          ? const SizedBox.shrink()
          : Container(
              color: Theme.of(context).colorScheme.errorContainer,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      snapshot.data!,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  TextButton(
                    onPressed: audio.retry,
                    child: const Text('Retry'),
                  ),
                  IconButton(
                    tooltip: 'Skip failed song',
                    onPressed: audio.skipToNext,
                    icon: const Icon(Icons.skip_next),
                  ),
                ],
              ),
            ),
    );
  }
}

class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final audio = ref.read(audioProvider);
    return StreamBuilder<MediaItem?>(
      stream: audio.mediaItem,
      builder: (context, snapshot) {
        final song = audio.currentSong;
        if (song == null) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.fromLTRB(8, 4, 8, 6),
          decoration: BoxDecoration(
            color: const Color(0xFF26382D),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            children: [
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                leading: Artwork(song: song, size: 44),
                title: Text(
                  song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  song.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const NowPlayingScreen()),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PlayButton(audio: audio),
                    IconButton(
                      tooltip: 'Next song',
                      onPressed: audio.skipToNext,
                      icon: const Icon(Icons.skip_next),
                    ),
                  ],
                ),
              ),
              StreamBuilder<Duration>(
                stream: audio.positions,
                builder: (context, snapshot) {
                  final total = audio.duration?.inMilliseconds ?? 0;
                  return LinearProgressIndicator(
                    minHeight: 2,
                    value: total <= 0
                        ? 0
                        : ((snapshot.data ?? audio.position).inMilliseconds /
                                  total)
                              .clamp(0, 1),
                    backgroundColor: Colors.transparent,
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class PlayButton extends StatelessWidget {
  const PlayButton({super.key, required this.audio, this.large = false});
  final SonifyAudioHandler audio;
  final bool large;
  @override
  Widget build(BuildContext context) => StreamBuilder<PlaybackState>(
    stream: audio.playbackState,
    builder: (context, snapshot) {
      final state = snapshot.data;
      final loading =
          state?.processingState == AudioProcessingState.loading ||
          state?.processingState == AudioProcessingState.buffering;
      return IconButton.filledTonal(
        tooltip: audio.playing ? 'Pause' : 'Play',
        iconSize: large ? 42 : 26,
        onPressed: () {
          if (audio.playing) {
            unawaited(audio.pause());
          } else {
            unawaited(audio.play());
          }
        },
        icon: loading
            ? SizedBox(
                width: large ? 42 : 26,
                height: large ? 42 : 26,
                child: const CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                audio.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              ),
      );
    },
  );
}

String formatTime(Duration duration) {
  final seconds = duration.inSeconds.clamp(0, 359999);
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

class NowPlayingScreen extends ConsumerWidget {
  const NowPlayingScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final audio = ref.read(audioProvider);
    final library = ref.watch(libraryProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'NOW PLAYING',
          style: TextStyle(fontSize: 13, letterSpacing: 3),
        ),
        actions: [
          IconButton(
            tooltip: 'Open queue',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const QueueScreen()),
            ),
            icon: const Icon(Icons.queue_music),
          ),
        ],
      ),
      body: StreamBuilder<MediaItem?>(
        stream: audio.mediaItem,
        builder: (context, snapshot) {
          final song = audio.currentSong;
          if (song == null) {
            return const _Message(
              icon: Icons.music_note,
              title: 'Your queue is empty',
              text: 'Choose a song to start listening.',
            );
          }
          return SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(28),
              children: [
                Center(
                  child: Artwork(
                    song: song,
                    size: (MediaQuery.sizeOf(context).width - 56).clamp(
                      100,
                      400,
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            song.title,
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            song.artist,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(color: Colors.grey),
                          ),
                          Text(
                            song.album,
                            style: const TextStyle(color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: library.favorites.contains(song.id)
                          ? 'Remove favorite'
                          : 'Add favorite',
                      onPressed: () => library.favorite(song),
                      icon: Icon(
                        library.favorites.contains(song.id)
                            ? Icons.favorite
                            : Icons.favorite_border,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                SeekBar(audio: audio),
                const SizedBox(height: 16),
                StreamBuilder<PlaybackState>(
                  stream: audio.playbackState,
                  builder: (context, snapshot) => Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        tooltip: audio.shuffled
                            ? 'Disable shuffle'
                            : 'Enable shuffle',
                        color: audio.shuffled
                            ? Theme.of(context).colorScheme.primary
                            : Colors.grey,
                        onPressed: () => audio.setShuffleMode(
                          audio.shuffled
                              ? AudioServiceShuffleMode.none
                              : AudioServiceShuffleMode.all,
                        ),
                        icon: const Icon(Icons.shuffle),
                      ),
                      IconButton(
                        tooltip: 'Previous song',
                        iconSize: 38,
                        onPressed: audio.skipToPrevious,
                        icon: const Icon(Icons.skip_previous_rounded),
                      ),
                      PlayButton(audio: audio, large: true),
                      IconButton(
                        tooltip: 'Next song',
                        iconSize: 38,
                        onPressed: audio.skipToNext,
                        icon: const Icon(Icons.skip_next_rounded),
                      ),
                      IconButton(
                        tooltip: 'Repeat: ${audio.loopMode.name}',
                        color: audio.loopMode == LoopMode.off
                            ? Colors.grey
                            : Theme.of(context).colorScheme.primary,
                        onPressed: () =>
                            audio.setRepeatMode(switch (audio.loopMode) {
                              LoopMode.off => AudioServiceRepeatMode.all,
                              LoopMode.all => AudioServiceRepeatMode.one,
                              LoopMode.one => AudioServiceRepeatMode.none,
                            }),
                        icon: Icon(
                          audio.loopMode == LoopMode.one
                              ? Icons.repeat_one
                              : Icons.repeat,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Wrap(
                  alignment: WrapAlignment.spaceEvenly,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    TextButton.icon(
                      onPressed: () => choosePlaylist(context, ref, song),
                      icon: const Icon(Icons.playlist_add),
                      label: const Text('Save to playlist'),
                    ),
                    TextButton.icon(
                      onPressed: audio.stop,
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: const Text('Stop'),
                    ),
                  ],
                ),
                const PlaybackError(),
              ],
            ),
          );
        },
      ),
    );
  }
}

class SeekBar extends StatefulWidget {
  const SeekBar({super.key, required this.audio});
  final SonifyAudioHandler audio;
  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? dragging;
  @override
  Widget build(BuildContext context) => StreamBuilder<Duration>(
    stream: widget.audio.positions,
    builder: (context, snapshot) {
      final total = widget.audio.duration?.inMilliseconds.toDouble() ?? 0;
      final value =
          (dragging ??
                  (snapshot.data ?? widget.audio.position).inMilliseconds
                      .toDouble())
              .clamp(0.0, total > 0 ? total : 1.0);
      return Column(
        children: [
          Slider(
            value: value,
            max: total > 0 ? total : 1,
            semanticFormatterCallback: (v) =>
                formatTime(Duration(milliseconds: v.round())),
            onChanged: total > 0 ? (v) => setState(() => dragging = v) : null,
            onChangeEnd: (v) {
              widget.audio.seek(Duration(milliseconds: v.round()));
              setState(() => dragging = null);
            },
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                formatTime(Duration(milliseconds: value.round())),
                style: const TextStyle(color: Colors.grey),
              ),
              Text(
                total > 0
                    ? formatTime(Duration(milliseconds: total.round()))
                    : '--:--',
                style: const TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ],
      );
    },
  );
}

class QueueScreen extends ConsumerWidget {
  const QueueScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final audio = ref.read(audioProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Play queue'),
        actions: [
          TextButton(onPressed: audio.clear, child: const Text('Clear')),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<MediaItem>>(
              stream: audio.queue,
              builder: (context, snapshot) {
                final entries = List<QueueEntry>.of(audio.entries);
                if (entries.isEmpty) {
                  return const _Message(
                    icon: Icons.queue_music,
                    title: 'Room for your next favorite',
                    text: 'Add songs from the catalog to build your queue.',
                  );
                }
                return ReorderableListView.builder(
                  itemCount: entries.length,
                  buildDefaultDragHandles: false,
                  onReorder: (from, to) {
                    if (to > from) to--;
                    audio.move(from, to);
                  },
                  itemBuilder: (context, i) => ListTile(
                    key: ValueKey(entries[i].id),
                    leading: Artwork(song: entries[i].song, size: 44),
                    title: Text(
                      entries[i].song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: i == audio.index
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                    ),
                    subtitle: Text(entries[i].song.artist),
                    onTap: () => audio.skipToQueueItem(i),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Remove from queue',
                          onPressed: () => audio.removeAt(i),
                          icon: const Icon(Icons.close),
                        ),
                        ReorderableDragStartListener(
                          index: i,
                          child: const Padding(
                            padding: EdgeInsets.all(8),
                            child: Icon(Icons.drag_handle),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const PlaybackError(),
          const MiniPlayer(),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.text,
    this.onRetry,
  });
  final IconData icon;
  final String title, text;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 42, color: Colors.grey),
        const SizedBox(height: 12),
        Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.grey),
        ),
        if (onRetry != null)
          TextButton(onPressed: onRetry, child: const Text('Try again')),
      ],
    ),
  );
}
