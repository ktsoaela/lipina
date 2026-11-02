import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../app.dart';
import '../models/models.dart';
import '../services/download_service.dart';
import '../services/player_controller.dart';
import '../widgets/common.dart';
import '../widgets/track_tile.dart';

enum CollectionKind { playlist, album, artist, liked }

/// One screen for anything that is "a list of tracks": playlist, album, artist, Liked Songs.
class CollectionScreen extends StatefulWidget {
  const CollectionScreen._(this.kind, this.id, this.title);
  const CollectionScreen.playlist(int id, String title) : this._(CollectionKind.playlist, id, title);
  const CollectionScreen.album(int id, String title) : this._(CollectionKind.album, id, title);
  const CollectionScreen.artist(int id, String title) : this._(CollectionKind.artist, id, title);
  const CollectionScreen.liked() : this._(CollectionKind.liked, null, 'Liked Songs');

  final CollectionKind kind;
  final int? id;
  final String title;

  @override
  State<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends State<CollectionScreen> {
  Map<String, dynamic>? _meta;

  Future<List<Track>> _load() async {
    final api = context.read<ApiClient>();
    List list;
    switch (widget.kind) {
      case CollectionKind.playlist:
        final data = Map<String, dynamic>.from(await api.get('/api/playlists/${widget.id}/') as Map);
        _meta = data;
        list = data['tracks'] as List;
      case CollectionKind.album:
        list = await api.get('/api/albums/${widget.id}/tracks/') as List;
      case CollectionKind.artist:
        list = await api.get('/api/artists/${widget.id}/tracks/') as List;
      case CollectionKind.liked:
        list = await api.getList('/api/tracks/liked/', query: {'limit': 500});
    }
    return list.map((e) => Track(Map<String, dynamic>.from(e as Map))).toList();
  }

  Future<void> _rename(Future<void> Function() reload) async {
    final name = await promptText(context, 'Rename playlist', 'Name', initial: widget.title);
    if (name == null || name.isEmpty || !mounted) return;
    await context.read<ApiClient>().patch('/api/playlists/${widget.id}/', {'name': name});
    await reload();
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Delete playlist?'),
        content: Text('"${widget.title}" will be removed. Songs stay in your library.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context.read<ApiClient>().delete('/api/playlists/${widget.id}/');
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerController>();
    final downloads = context.read<DownloadService>();
    return Scaffold(
      body: AsyncView<List<Track>>(
        load: _load,
        builder: (context, tracks, reload) {
          final items = tracks.map(PlayableItem.fromTrack).toList();
          final total = tracks.fold<double>(0, (s, t) => s + t.duration);
          final isOwner = _meta?['is_owner'] == true;
          final cover = widget.kind == CollectionKind.playlist
              ? (_meta?['cover_url'] as String?)
              : tracks.firstOrNull?.coverUrl;
          return RefreshIndicator(
            onRefresh: reload,
            child: CustomScrollView(slivers: [
              SliverAppBar(
                pinned: true,
                expandedHeight: 300,
                actions: [
                  if (widget.kind == CollectionKind.playlist && isOwner)
                    PopupMenuButton<String>(
                      onSelected: (v) => v == 'rename' ? _rename(reload) : _delete(),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'rename', child: Text('Rename')),
                        PopupMenuItem(value: 'delete', child: Text('Delete playlist')),
                      ],
                    ),
                ],
                flexibleSpace: FlexibleSpaceBar(
                  title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  background: Stack(fit: StackFit.expand, children: [
                    widget.kind == CollectionKind.liked
                        ? Container(
                            decoration: const BoxDecoration(
                                gradient: LinearGradient(colors: [Color(0xFF4527A0), LipinaColors.accent])),
                            child: const Icon(Icons.favorite, size: 96))
                        : Cover(cover, size: 300, radius: 0, icon: Icons.queue_music),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                            begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, LipinaColors.bg]),
                      ),
                    ),
                  ]),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                  child: Row(children: [
                    Expanded(
                      child: Text('${tracks.length} songs · ${formatDuration(Duration(seconds: total.round()))}',
                          style: const TextStyle(color: LipinaColors.muted)),
                    ),
                    IconButton(
                      tooltip: 'Download all',
                      icon: const Icon(Icons.download_for_offline_outlined),
                      onPressed: tracks.isEmpty
                          ? null
                          : () {
                              downloads.downloadAll(items);
                              toast(context, 'Downloading ${items.length} songs for offline');
                            },
                    ),
                    if (widget.kind == CollectionKind.playlist && isOwner)
                      IconButton(
                        tooltip: 'Delete playlist',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: _delete,
                      ),
                    IconButton(
                      tooltip: 'Shuffle',
                      icon: const Icon(Icons.shuffle_rounded),
                      onPressed: tracks.isEmpty ? null : () => player.playTracks(tracks, shuffle: true),
                    ),
                    const SizedBox(width: 4),
                    FilledButton(
                      style: FilledButton.styleFrom(shape: const CircleBorder(), padding: const EdgeInsets.all(14)),
                      onPressed: tracks.isEmpty ? null : () => player.playTracks(tracks),
                      child: const Icon(Icons.play_arrow_rounded, size: 30),
                    ),
                  ]),
                ),
              ),
              if (tracks.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(icon: Icons.music_off_outlined, title: 'No songs here yet'),
                ),
              SliverList.builder(
                itemCount: tracks.length,
                itemBuilder: (_, i) => widget.kind == CollectionKind.playlist && isOwner
                    ? Dismissible(
                        key: ValueKey(tracks[i].id),
                        direction: DismissDirection.endToStart,
                        background: Container(
                            color: Colors.red.withValues(alpha: 0.3),
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 20),
                            child: const Icon(Icons.remove_circle_outline)),
                        onDismissed: (_) => context
                            .read<ApiClient>()
                            .delete('/api/playlists/${widget.id}/tracks/${tracks[i].id}/')
                            .then((_) => reload()),
                        child: TrackTile(
                          item: items[i],
                          track: tracks[i],
                          onTap: () => player.playTracks(tracks, start: i),
                          onDeleted: reload,
                        ),
                      )
                    : TrackTile(
                        item: items[i],
                        track: tracks[i],
                        onTap: () => player.playTracks(tracks, start: i),
                        onDeleted: reload,
                      ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ]),
          );
        },
      ),
    );
  }
}
