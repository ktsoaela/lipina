import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../app.dart';
import '../models/models.dart';
import '../services/download_service.dart';
import '../services/local_music_service.dart';
import '../services/player_controller.dart';
import '../widgets/common.dart';
import '../widgets/track_tile.dart';
import 'collection_screen.dart';

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  Future<void> _newPlaylist(BuildContext context) async {
    final name = await promptText(context, 'New playlist', 'Name');
    if (name == null || name.isEmpty || !context.mounted) return;
    final created = await context.read<ApiClient>().post('/api/playlists/', {'name': name});
    if (context.mounted) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => CollectionScreen.playlist(created['id'] as int, name)));
    }
  }

  Future<void> _uploadFromPhone(BuildContext context) async {
    final api = context.read<ApiClient>();
    final picked = await FilePicker.platform.pickFiles(type: FileType.audio, allowMultiple: true);
    if (picked == null || !context.mounted) return;
    var ok = 0;
    toast(context, 'Uploading ${picked.files.length} file(s)…');
    for (final f in picked.files) {
      if (f.path == null) continue;
      try {
        await api.upload('/api/tracks/', f.path!);
        ok++;
      } catch (e) {
        if (context.mounted) toast(context, '${f.name}: $e');
      }
    }
    if (context.mounted) toast(context, 'Uploaded $ok song(s) to your library');
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 6,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Your Library', style: TextStyle(fontWeight: FontWeight.w800)),
            actions: [
              IconButton(tooltip: 'Upload to cloud library', icon: const Icon(Icons.cloud_upload_outlined),
                  onPressed: () => _uploadFromPhone(context)),
              IconButton(tooltip: 'New playlist', icon: const Icon(Icons.add), onPressed: () => _newPlaylist(context)),
            ],
            bottom: const TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [
              Tab(text: 'Playlists'),
              Tab(text: 'Songs'),
              Tab(text: 'Albums'),
              Tab(text: 'Artists'),
              Tab(text: 'Downloads'),
              Tab(text: 'On this device'),
            ]),
          ),
          body: const TabBarView(children: [_Playlists(), _Songs(), _Albums(), _Artists(), _Downloads(), _Device()]),
        ),
      );
}

class _Playlists extends StatelessWidget {
  const _Playlists();

  @override
  Widget build(BuildContext context) {
    final api = context.read<ApiClient>();
    return AsyncView<List<Playlist>>(
      load: () async => (await api.getList('/api/playlists/')).map(Playlist.new).toList(),
      builder: (context, playlists, reload) => RefreshIndicator(
        onRefresh: reload,
        child: ListView(children: [
          ListTile(
            leading: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  gradient: const LinearGradient(colors: [Color(0xFF4527A0), LipinaColors.accent])),
              child: const Icon(Icons.favorite),
            ),
            title: const Text('Liked Songs', style: TextStyle(fontWeight: FontWeight.w600)),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CollectionScreen.liked())),
          ),
          for (final p in playlists)
            ListTile(
              leading: Cover(p.coverUrl, size: 52, icon: Icons.queue_music),
              title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text('${p.trackCount} songs', style: const TextStyle(color: LipinaColors.muted)),
              trailing: p.isOwner
                  ? IconButton(
                      tooltip: 'Delete playlist',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (d) => AlertDialog(
                            title: const Text('Delete playlist?'),
                            content: Text('"${p.name}" will be deleted. Songs stay in your library.'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
                              FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Delete')),
                            ],
                          ),
                        );
                        if (ok != true || !context.mounted) return;
                        await api.delete('/api/playlists/${p.id}/');
                        await reload();
                      },
                    )
                  : null,
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CollectionScreen.playlist(p.id, p.name)))
                  .then((_) => reload()),
            ),
        ]),
      ),
    );
  }
}

class _Songs extends StatefulWidget {
  const _Songs();

  @override
  State<_Songs> createState() => _SongsState();
}

class _SongsState extends State<_Songs> {
  String _ordering = '-created_at';

  @override
  Widget build(BuildContext context) {
    final api = context.read<ApiClient>();
    final player = context.read<PlayerController>();
    return AsyncView<List<Track>>(
      key: ValueKey(_ordering),
      load: () async => (await api.getList('/api/tracks/', query: {'limit': 500, 'ordering': _ordering})).map(Track.new).toList(),
      builder: (context, tracks, reload) => RefreshIndicator(
        onRefresh: reload,
        child: ListView.builder(
          itemCount: tracks.length + 1,
          itemBuilder: (_, i) {
            if (i == 0) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                child: Row(children: [
                  Text('${tracks.length} songs', style: const TextStyle(color: LipinaColors.muted)),
                  const Spacer(),
                  DropdownButton<String>(
                    value: _ordering,
                    underline: const SizedBox(),
                    items: const [
                      DropdownMenuItem(value: '-created_at', child: Text('Recently added')),
                      DropdownMenuItem(value: 'title', child: Text('Title')),
                      DropdownMenuItem(value: 'artist__name', child: Text('Artist')),
                      DropdownMenuItem(value: '-play_count', child: Text('Most played')),
                    ],
                    onChanged: (v) => setState(() => _ordering = v!),
                  ),
                  IconButton(icon: const Icon(Icons.shuffle), onPressed: () => player.playTracks(tracks, shuffle: true)),
                ]),
              );
            }
            final t = tracks[i - 1];
            return TrackTile(
              item: PlayableItem.fromTrack(t),
              track: t,
              onTap: () => player.playTracks(tracks, start: i - 1),
              onDeleted: reload,
            );
          },
        ),
      ),
    );
  }
}

class _Albums extends StatelessWidget {
  const _Albums();

  @override
  Widget build(BuildContext context) {
    final api = context.read<ApiClient>();
    return AsyncView<List<Album>>(
      load: () async => (await api.getList('/api/albums/', query: {'limit': 500})).map(Album.new).toList(),
      builder: (context, albums, _) => GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 180, mainAxisSpacing: 16, crossAxisSpacing: 16, childAspectRatio: 0.75),
        itemCount: albums.length,
        itemBuilder: (_, i) => LayoutBuilder(
          builder: (_, c) => InkWell(
            onTap: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => CollectionScreen.album(albums[i].id, albums[i].title))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Cover(albums[i].coverUrl, size: c.maxWidth, radius: 10),
              const SizedBox(height: 6),
              Text(albums[i].title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(albums[i].artistName, maxLines: 1, style: const TextStyle(color: LipinaColors.muted, fontSize: 12)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Artists extends StatelessWidget {
  const _Artists();

  @override
  Widget build(BuildContext context) {
    final api = context.read<ApiClient>();
    return AsyncView<List<Artist>>(
      load: () async => (await api.getList('/api/artists/', query: {'limit': 500})).map(Artist.new).toList(),
      builder: (context, artists, _) => ListView.builder(
        itemCount: artists.length,
        itemBuilder: (_, i) => ListTile(
          leading: Cover(artists[i].imageUrl, size: 52, radius: 26, icon: Icons.person),
          title: Text(artists[i].name),
          subtitle: Text('${artists[i].trackCount} songs'),
          onTap: () => Navigator.push(
              context, MaterialPageRoute(builder: (_) => CollectionScreen.artist(artists[i].id, artists[i].name))),
        ),
      ),
    );
  }
}

class _Downloads extends StatelessWidget {
  const _Downloads();

  @override
  Widget build(BuildContext context) {
    final downloads = context.watch<DownloadService>();
    final player = context.read<PlayerController>();
    final items = downloads.all;
    if (items.isEmpty && downloads.progress.isEmpty) {
      return const EmptyState(
        icon: Icons.download_for_offline_outlined,
        title: 'No downloads yet',
        message: 'Tap ⋮ → Download on any song or podcast episode, or "Download all" on a playlist.',
      );
    }
    final mb = (downloads.totalBytes / (1024 * 1024)).toStringAsFixed(1);
    return ListView(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Row(children: [
          Text('${items.length} items · $mb MB', style: const TextStyle(color: LipinaColors.muted)),
          const Spacer(),
          TextButton.icon(
              icon: const Icon(Icons.play_arrow), label: const Text('Play all'), onPressed: () => player.playItems(items)),
        ]),
      ),
      if (downloads.progress.isNotEmpty)
        for (final e in downloads.progress.entries)
          ListTile(
            leading: const CircularProgressIndicator(),
            title: Text('Downloading… ${(e.value * 100).round()}%'),
            trailing: IconButton(icon: const Icon(Icons.close), onPressed: () => downloads.cancel(e.key)),
          ),
      for (final (i, item) in items.indexed)
        TrackTile(
          item: item,
          onTap: () => player.playItems(items, start: i),
          trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => downloads.remove(item.key)),
        ),
    ]);
  }
}

class _Device extends StatelessWidget {
  const _Device();

  @override
  Widget build(BuildContext context) {
    final local = context.watch<LocalMusicService>();
    final player = context.read<PlayerController>();
    final items = local.items;
    final importButton = FilledButton.icon(
      icon: const Icon(Icons.folder_open),
      label: const Text('Import music files'),
      onPressed: () async {
        final n = await local.importFiles();
        if (context.mounted) toast(context, 'Imported $n file(s)');
      },
    );
    if (items.isEmpty) {
      return EmptyState(
        icon: Icons.phone_android,
        title: 'Play music stored on this phone',
        message: 'Imported files play fully offline — no account or data needed.',
        action: importButton,
      );
    }
    return ListView(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          importButton,
          const Spacer(),
          IconButton(icon: const Icon(Icons.shuffle), onPressed: () => player.playItems(items, shuffle: true)),
        ]),
      ),
      for (final (i, item) in items.indexed)
        TrackTile(
          item: item,
          onTap: () => player.playItems(items, start: i),
          trailing: PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'queue') player.addToQueue(item);
              if (v == 'remove') await local.remove(item);
              if (v == 'upload') {
                try {
                  await local.uploadToCloud(context.read<ApiClient>(), item);
                  if (context.mounted) toast(context, 'Uploaded "${item.title}"');
                } catch (e) {
                  if (context.mounted) toast(context, 'Upload failed: $e');
                }
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'queue', child: Text('Add to queue')),
              PopupMenuItem(value: 'upload', child: Text('Upload to my cloud library')),
              PopupMenuItem(value: 'remove', child: Text('Remove from Lipina')),
            ],
          ),
        ),
    ]);
  }
}
