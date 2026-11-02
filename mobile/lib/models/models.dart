// Plain data models mirroring the Lipina REST API. Kept dependency-free so they
// can be cached in Hive as JSON maps for offline use.

typedef Json = Map<String, dynamic>;

int? _int(dynamic v) => v is int ? v : (v is num ? v.toInt() : int.tryParse('${v ?? ''}'));
double _double(dynamic v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;

enum MediaKind { track, episode, station, device, preview }

/// Anything the player can play: a library track, podcast episode, radio station or a
/// file on the device. `key` is stable across sessions and used for downloads/history.
class PlayableItem {
  PlayableItem({
    required this.key,
    required this.kind,
    required this.title,
    required this.url,
    this.subtitle = '',
    this.album = '',
    this.artUrl,
    this.duration,
    this.remoteId,
    this.localPath,
    this.startPosition,
    this.extra = const {},
  });

  final String key;
  final MediaKind kind;
  final String title;
  final String subtitle;
  final String album;
  final String? artUrl;
  final String url;
  final Duration? duration;
  final int? remoteId;
  String? localPath;
  final Duration? startPosition;
  final Json extra;

  bool get isLive => kind == MediaKind.station;
  bool get isPodcast => kind == MediaKind.episode;

  factory PlayableItem.fromTrack(Track t) => PlayableItem(
        key: 'track:${t.id}',
        kind: MediaKind.track,
        title: t.title,
        subtitle: t.artistName,
        album: t.albumTitle,
        artUrl: t.coverUrl,
        url: t.streamUrl,
        duration: Duration(milliseconds: (t.duration * 1000).round()),
        remoteId: t.id,
        extra: {'download_url': t.downloadUrl, 'mime': t.mimeType, 'liked': t.liked},
      );

  factory PlayableItem.fromEpisode(Episode e) => PlayableItem(
        key: 'episode:${e.id}',
        kind: MediaKind.episode,
        title: e.title,
        subtitle: e.podcastTitle,
        artUrl: (e.image?.isNotEmpty ?? false) ? e.image : e.podcastImage,
        url: e.audioUrl,
        duration: e.duration > 0 ? Duration(seconds: e.duration) : null,
        remoteId: e.id,
        startPosition: e.position > 0 && !e.completed ? Duration(seconds: e.position) : null,
        extra: {'download_url': e.audioUrl, 'mime': e.mimeType},
      );

  /// 30-second Apple Music preview from the iTunes Search API (via /api/connect/itunes/search/).
  factory PlayableItem.fromITunes(Json r) => PlayableItem(
        key: 'itunes:${r['id']}',
        kind: MediaKind.preview,
        title: r['title'] as String? ?? '',
        subtitle: r['artist'] as String? ?? '',
        album: r['album'] as String? ?? '',
        artUrl: r['art'] as String?,
        url: r['preview_url'] as String? ?? '',
        duration: const Duration(seconds: 30),
        extra: {'external_url': r['url'], 'service': 'Apple Music'},
      );

  factory PlayableItem.fromStation(Station s) => PlayableItem(
        key: 'station:${s.id}',
        kind: MediaKind.station,
        title: s.name,
        subtitle: [s.state, ...s.tags.take(2)].where((x) => x.isNotEmpty).join(' · '),
        artUrl: s.favicon.isEmpty ? null : s.favicon,
        url: s.streamUrl,
        remoteId: s.id,
      );

  Json toJson() => {
        'key': key,
        'kind': kind.name,
        'title': title,
        'subtitle': subtitle,
        'album': album,
        'artUrl': artUrl,
        'url': url,
        'duration': duration?.inMilliseconds,
        'remoteId': remoteId,
        'localPath': localPath,
        'extra': extra,
      };

  factory PlayableItem.fromJson(Json j) => PlayableItem(
        key: j['key'] as String,
        kind: MediaKind.values.byName(j['kind'] as String),
        title: j['title'] as String? ?? '',
        subtitle: j['subtitle'] as String? ?? '',
        album: j['album'] as String? ?? '',
        artUrl: j['artUrl'] as String?,
        url: j['url'] as String? ?? '',
        duration: j['duration'] == null ? null : Duration(milliseconds: _int(j['duration'])!),
        remoteId: _int(j['remoteId']),
        localPath: j['localPath'] as String?,
        extra: Map<String, dynamic>.from(j['extra'] as Map? ?? {}),
      );
}

class Track {
  Track(this.json);
  final Json json;
  int get id => _int(json['id'])!;
  String get title => json['title'] as String? ?? 'Untitled';
  String get artistName => (json['artist'] as Map?)?['name'] as String? ?? 'Unknown Artist';
  int? get artistId => _int((json['artist'] as Map?)?['id']);
  String get albumTitle => (json['album'] as Map?)?['title'] as String? ?? '';
  int? get albumId => _int((json['album'] as Map?)?['id']);
  String? get coverUrl => json['cover_url'] as String?;
  String get streamUrl => json['stream_url'] as String? ?? '';
  String get downloadUrl => json['download_url'] as String? ?? streamUrl;
  String get mimeType => json['mime_type'] as String? ?? 'audio/mpeg';
  double get duration => _double(json['duration']);
  String get genre => json['genre'] as String? ?? '';
  bool get liked => json['liked'] == true;
  set liked(bool v) => json['liked'] = v;
  bool get isOwner => json['is_owner'] == true;
}

class Playlist {
  Playlist(this.json);
  final Json json;
  int get id => _int(json['id'])!;
  String get name => json['name'] as String? ?? '';
  String get description => json['description'] as String? ?? '';
  String? get coverUrl => json['cover_url'] as String?;
  int get trackCount => _int(json['track_count']) ?? 0;
  bool get isOwner => json['is_owner'] == true;
  List<Track> get tracks => ((json['tracks'] as List?) ?? []).map((e) => Track(Map<String, dynamic>.from(e))).toList();
}

class Album {
  Album(this.json);
  final Json json;
  int get id => _int(json['id'])!;
  String get title => json['title'] as String? ?? '';
  String get artistName => (json['artist'] as Map?)?['name'] as String? ?? '';
  String? get coverUrl => json['cover_url'] as String?;
  int? get year => _int(json['year']);
}

class Artist {
  Artist(this.json);
  final Json json;
  int get id => _int(json['id'])!;
  String get name => json['name'] as String? ?? '';
  String? get imageUrl => json['image_url'] as String?;
  int get trackCount => _int(json['track_count']) ?? 0;
}

class Station {
  Station(this.json);
  final Json json;
  int get id => _int(json['id'])!;
  String get name => json['name'] as String? ?? '';
  String get streamUrl => json['stream_url'] as String? ?? '';
  String get favicon => json['favicon'] as String? ?? '';
  String get state => json['state'] as String? ?? '';
  String get codec => json['codec'] as String? ?? '';
  int get bitrate => _int(json['bitrate']) ?? 0;
  List<String> get tags => ((json['tags'] as List?) ?? []).cast<String>();
  bool get isFavorite => json['is_favorite'] == true;
  set isFavorite(bool v) => json['is_favorite'] = v;
}

class Podcast {
  Podcast(this.json);
  final Json json;
  int? get id => _int(json['id']);
  int? get itunesId => _int(json['itunes_id']);
  String get title => json['title'] as String? ?? '';
  String get author => json['author'] as String? ?? '';
  String get image => json['image'] as String? ?? '';
  String get description => json['description'] as String? ?? '';
  String get feedUrl => json['feed_url'] as String? ?? '';
  bool get isSubscribed => json['is_subscribed'] == true;
  set isSubscribed(bool v) => json['is_subscribed'] = v;
}

class Episode {
  Episode(this.json);
  final Json json;
  int get id => _int(json['id'])!;
  String get title => json['title'] as String? ?? '';
  String get description => json['description'] as String? ?? '';
  String get audioUrl => json['audio_url'] as String? ?? '';
  String get mimeType => json['mime_type'] as String? ?? 'audio/mpeg';
  String get podcastTitle => json['podcast_title'] as String? ?? '';
  String get podcastImage => json['podcast_image'] as String? ?? '';
  String? get image => json['image'] as String?;
  int get duration => _int(json['duration']) ?? 0;
  int get position => _int(json['position']) ?? 0;
  bool get completed => json['completed'] == true;
  DateTime? get publishedAt => DateTime.tryParse(json['published_at'] as String? ?? '');
}

/// One time-stamped lyric line from an LRC file.
class LyricLine {
  const LyricLine(this.time, this.text);
  final Duration time;
  final String text;

  static final _tag = RegExp(r'\[(\d+):(\d+(?:\.\d+)?)\]');

  static List<LyricLine> parseLrc(String lrc) {
    final lines = <LyricLine>[];
    for (final raw in lrc.split('\n')) {
      final matches = _tag.allMatches(raw).toList();
      if (matches.isEmpty) continue;
      final text = raw.substring(matches.last.end).trim();
      for (final m in matches) {
        final ms = (int.parse(m.group(1)!) * 60000) + (double.parse(m.group(2)!) * 1000).round();
        lines.add(LyricLine(Duration(milliseconds: ms), text));
      }
    }
    lines.sort((a, b) => a.time.compareTo(b.time));
    return lines;
  }
}

String formatDuration(Duration? d) {
  if (d == null) return '--:--';
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(h > 0 ? 2 : 1, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}
