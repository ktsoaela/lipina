import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../app.dart';
import '../models/models.dart';
import '../services/auth_service.dart';
import '../services/download_service.dart';
import '../services/player_controller.dart';
import '../widgets/common.dart';
import '../widgets/track_tile.dart';
import 'collection_screen.dart';
import 'recognize_screen.dart';
import 'settings_screen.dart';
import 'tools_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  List<Track> _tracks(dynamic list) =>
      ((list as List?) ?? []).map((e) => Track(Map<String, dynamic>.from(e as Map))).toList();

  @override
  Widget build(BuildContext context) {
    final api = context.read<ApiClient>();
    final player = context.read<PlayerController>();
    return Scaffold(
      appBar: AppBar(
        title: Text(context.watch<AuthService>().displayName, style: const TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            tooltip: 'What\'s this song?',
            icon: const Icon(Icons.graphic_eq_rounded, color: LipinaColors.accent),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RecognizeScreen())),
          ),
          IconButton(
            tooltip: 'Focus & tools',
            icon: const Icon(Icons.self_improvement_rounded),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ToolsScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: AsyncView<Map>(
        load: () async => await api.get('/api/home/') as Map,
        builder: (context, data, reload) {
          final recent = _tracks(data['recently_played']);
          final mix = _tracks(data['daily_mix']);
          final top = _tracks(data['top_tracks']);
          final fresh = _tracks(data['new_uploads']);
          final popular = _tracks(data['popular']);
          final playlists = ((data['playlists'] as List?) ?? []).map((e) => Playlist(Map<String, dynamic>.from(e))).toList();
          final albums = ((data['albums'] as List?) ?? []).map((e) => Album(Map<String, dynamic>.from(e))).toList();
          final offline = context.watch<DownloadService>().all;
          final empty = recent.isEmpty && fresh.isEmpty && popular.isEmpty;

          return RefreshIndicator(
            onRefresh: reload,
            child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Text('${data['greeting'] ?? 'Hello'} 👋',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
              ),
              _QuickGrid(children: [
                _Quick(Icons.favorite_rounded, 'Liked Songs', () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const CollectionScreen.liked()))),
                _Quick(Icons.graphic_eq_rounded, 'Identify song', () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const RecognizeScreen()))),
                _Quick(Icons.timer_outlined, 'Focus session', () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const ToolsScreen()))),
                _Quick(Icons.shuffle_rounded, 'Shuffle all', () async {
                  final list = await api.getList('/api/tracks/', query: {'limit': 200});
                  await player.playTracks(list.map(Track.new).toList(), shuffle: true);
                }),
              ]),
              if (empty)
                EmptyState(
                  icon: Icons.library_music_outlined,
                  title: 'Your library is empty',
                  message: 'Upload music from the web app or import files from this phone in Library → On this device. '
                      'Meanwhile, try Radio for live South African stations.',
                ),
              if (mix.isNotEmpty) ...[
                const SectionHeader('Your daily mix'),
                _TrackCards(tracks: mix),
              ],
              if (recent.isNotEmpty) ...[
                const SectionHeader('Recently played'),
                _TrackCards(tracks: recent),
              ],
              if (playlists.isNotEmpty) ...[
                const SectionHeader('Your playlists'),
                CardRow(children: [
                  for (final p in playlists)
                    MediaCard(
                      title: p.name,
                      subtitle: '${p.trackCount} tracks',
                      image: p.coverUrl,
                      icon: Icons.queue_music,
                      onTap: () => Navigator.push(context,
                          MaterialPageRoute(builder: (_) => CollectionScreen.playlist(p.id, p.name))),
                    ),
                ]),
              ],
              if (top.isNotEmpty) ...[
                const SectionHeader('On repeat'),
                for (final t in top.take(5))
                  TrackTile(
                    item: PlayableItem.fromTrack(t),
                    track: t,
                    onTap: () => player.playTracks(top, start: top.indexOf(t)),
                  ),
              ],
              if (albums.isNotEmpty) ...[
                const SectionHeader('Albums'),
                CardRow(children: [
                  for (final a in albums)
                    MediaCard(
                      title: a.title,
                      subtitle: a.artistName,
                      image: a.coverUrl,
                      onTap: () => Navigator.push(context,
                          MaterialPageRoute(builder: (_) => CollectionScreen.album(a.id, a.title))),
                    ),
                ]),
              ],
              if (fresh.isNotEmpty) ...[
                const SectionHeader('Fresh in your library'),
                _TrackCards(tracks: fresh),
              ],
              if (popular.isNotEmpty) ...[
                const SectionHeader('Popular on Lipina'),
                _TrackCards(tracks: popular),
              ],
              if (offline.isNotEmpty) ...[
                const SectionHeader('Ready offline'),
                CardRow(children: [
                  for (final (i, item) in offline.take(12).indexed)
                    MediaCard(
                      title: item.title,
                      subtitle: item.subtitle,
                      image: item.artUrl,
                      onTap: () => player.playItems(offline, start: i),
                    ),
                ]),
              ],
            ]),
          );
        },
      ),
    );
  }
}

class _QuickGrid extends StatelessWidget {
  const _QuickGrid({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 3.4,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          children: children,
        ),
      );
}

class _Quick extends StatelessWidget {
  const _Quick(this.icon, this.label, this.onTap);
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: LipinaColors.surfaceHi,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Row(children: [
            Container(
              width: 48,
              height: double.infinity,
              decoration: const BoxDecoration(
                gradient: LinearGradient(colors: [LipinaColors.accent, Color(0xFF0E8F6C)]),
                borderRadius: BorderRadius.horizontal(left: Radius.circular(8)),
              ),
              child: Icon(icon, color: Colors.black),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700))),
          ]),
        ),
      );
}

class _TrackCards extends StatelessWidget {
  const _TrackCards({required this.tracks});
  final List<Track> tracks;

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerController>();
    return CardRow(children: [
      for (final (i, t) in tracks.indexed)
        GestureDetector(
          onLongPress: () => showItemActions(context, PlayableItem.fromTrack(t), track: t),
          child: MediaCard(
            title: t.title,
            subtitle: t.artistName,
            image: t.coverUrl,
            onTap: () => player.playTracks(tracks, start: i),
          ),
        ),
    ]);
  }
}
