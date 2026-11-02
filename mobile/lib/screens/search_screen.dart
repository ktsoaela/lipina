import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../app.dart';
import '../models/models.dart';
import '../services/player_controller.dart';
import '../widgets/common.dart';
import '../widgets/track_tile.dart';
import 'collection_screen.dart';
import 'podcasts_screen.dart';
import 'streaming_screen.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _q = TextEditingController();
  Timer? _debounce;
  Map? _results;
  List<Map<String, dynamic>> _genres = [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    context.read<ApiClient>().get('/api/tracks/genres/').then((g) {
      if (mounted) setState(() => _genres = (g as List).map((e) => Map<String, dynamic>.from(e)).toList());
    }).catchError((_) {});
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(v));
  }

  Future<void> _search(String q) async {
    if (q.trim().isEmpty) {
      setState(() => _results = null);
      return;
    }
    setState(() => _loading = true);
    try {
      final r = await context.read<ApiClient>().get('/api/search/', query: {'q': q.trim()}, cache: false);
      if (mounted && q.trim() == _q.text.trim()) {
        setState(() {
          _results = r as Map;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerController>();
    final r = _results;
    List<T> list<T>(String k, T Function(Map<String, dynamic>) f) =>
        ((r?[k] as List?) ?? []).map((e) => f(Map<String, dynamic>.from(e as Map))).toList();
    final tracks = list('tracks', Track.new);
    final artists = list('artists', Artist.new);
    final albums = list('albums', Album.new);
    final playlists = list('playlists', Playlist.new);
    final stations = list('stations', Station.new);
    final podcasts = list('podcasts', Podcast.new);

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _q,
          onChanged: _onChanged,
          textInputAction: TextInputAction.search,
          onSubmitted: _search,
          decoration: InputDecoration(
            hintText: 'Songs, artists, stations, podcasts',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _q.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      _q.clear();
                      setState(() => _results = null);
                    }),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        bottom: _loading ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator()) : null,
      ),
      body: r == null
          ? ListView(padding: const EdgeInsets.all(16), children: [
              if (_error != null) Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              Card(
                margin: const EdgeInsets.only(bottom: 20),
                child: ListTile(
                  leading: const Icon(Icons.cast_connected_rounded, color: LipinaColors.accent),
                  title: const Text('Spotify, Apple Music & YouTube Music'),
                  subtitle: const Text('Play previews and videos here, or open your streaming apps'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const StreamingScreen())),
                ),
              ),
              const Text('Browse genres', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final (i, g) in _genres.indexed)
                  ActionChip(
                    backgroundColor: Colors.primaries[i % Colors.primaries.length].withValues(alpha: 0.25),
                    label: Text('${g['genre']}'),
                    onPressed: () {
                      _q.text = '${g['genre']}';
                      _search(_q.text);
                    },
                  ),
                if (_genres.isEmpty) const Text('Upload music to see your genres here.', style: TextStyle(color: LipinaColors.muted)),
              ]),
            ])
          : ListView(children: [
              ListTile(
                leading: const Icon(Icons.cast_connected_rounded, color: LipinaColors.accent),
                title: Text('Search streaming services for "${_q.text.trim()}"'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                    context, MaterialPageRoute(builder: (_) => StreamingScreen(initialQuery: _q.text.trim()))),
              ),
              if (tracks.isEmpty && artists.isEmpty && albums.isEmpty && stations.isEmpty && podcasts.isEmpty && playlists.isEmpty)
                EmptyState(icon: Icons.search_off, title: 'No results for "${_q.text}"'),
              if (artists.isNotEmpty) ...[
                const SectionHeader('Artists'),
                CardRow(height: 190, children: [
                  for (final a in artists)
                    MediaCard(
                      title: a.name,
                      subtitle: '${a.trackCount} songs',
                      image: a.imageUrl,
                      round: true,
                      icon: Icons.person,
                      onTap: () => Navigator.push(
                          context, MaterialPageRoute(builder: (_) => CollectionScreen.artist(a.id, a.name))),
                    ),
                ]),
              ],
              if (tracks.isNotEmpty) ...[
                const SectionHeader('Songs'),
                for (final (i, t) in tracks.indexed)
                  TrackTile(item: PlayableItem.fromTrack(t), track: t, onTap: () => player.playTracks(tracks, start: i)),
              ],
              if (albums.isNotEmpty) ...[
                const SectionHeader('Albums'),
                CardRow(children: [
                  for (final a in albums)
                    MediaCard(
                        title: a.title,
                        subtitle: a.artistName,
                        image: a.coverUrl,
                        onTap: () => Navigator.push(
                            context, MaterialPageRoute(builder: (_) => CollectionScreen.album(a.id, a.title)))),
                ]),
              ],
              if (playlists.isNotEmpty) ...[
                const SectionHeader('Playlists'),
                for (final p in playlists)
                  ListTile(
                    leading: Cover(p.coverUrl, size: 48, icon: Icons.queue_music),
                    title: Text(p.name),
                    subtitle: Text('${p.trackCount} songs'),
                    onTap: () => Navigator.push(
                        context, MaterialPageRoute(builder: (_) => CollectionScreen.playlist(p.id, p.name))),
                  ),
              ],
              if (stations.isNotEmpty) ...[
                const SectionHeader('Radio stations'),
                for (final s in stations)
                  ListTile(
                    leading: Cover(s.favicon, size: 48, icon: Icons.radio),
                    title: Text(s.name),
                    subtitle: Text(s.state),
                    trailing: const Icon(Icons.play_circle_outline),
                    onTap: () => player.playStation(s),
                  ),
              ],
              if (podcasts.isNotEmpty) ...[
                const SectionHeader('Podcasts'),
                for (final p in podcasts)
                  ListTile(
                    leading: Cover(p.image, size: 48, icon: Icons.podcasts),
                    title: Text(p.title),
                    subtitle: Text(p.author),
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PodcastDetailScreen(podcast: p))),
                  ),
              ],
              const SizedBox(height: 24),
            ]),
    );
  }
}
