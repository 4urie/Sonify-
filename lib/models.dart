import 'dart:convert';

class Song {
  const Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.audioPath,
    this.artworkPath,
    this.durationMs,
    this.available = true,
  });
  final String id, title, artist, album, audioPath;
  final String? artworkPath;
  final int? durationMs;
  final bool available;
  factory Song.fromJson(Map<String, dynamic> j) => Song(
    id: j['id'],
    title: j['title'],
    artist: j['artist'],
    album: j['album'] ?? '',
    audioPath: j['audio_path'],
    artworkPath: j['artwork_path'],
    durationMs: j['duration_ms'],
    available: j['available'] != false,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'album': album,
    'audio_path': audioPath,
    'artwork_path': artworkPath,
    'duration_ms': durationMs,
    'available': available,
  };
  Song unavailable() => Song.fromJson({...toJson(), 'available': false});
}

class QueueEntry {
  QueueEntry(this.id, this.song);
  final String id;
  final Song song;
  Map<String, dynamic> toJson() => {'id': id, 'song': song.toJson()};
  factory QueueEntry.fromJson(Map<String, dynamic> j) =>
      QueueEntry(j['id'], Song.fromJson(j['song']));
}

class LocalPlaylist {
  LocalPlaylist(this.id, this.name, this.songIds);
  final String id;
  String name;
  final List<String> songIds;
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'songs': songIds};
  factory LocalPlaylist.fromJson(Map<String, dynamic> j) =>
      LocalPlaylist(j['id'], j['name'], List<String>.from(j['songs']));
}

String encode(Object value) => jsonEncode(value);
