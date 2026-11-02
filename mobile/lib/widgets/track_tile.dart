import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../app.dart';
import '../models/models.dart';
import '../screens/collection_screen.dart';
import '../services/download_service.dart';
import '../services/player_controller.dart';
import 'common.dart';

class TrackTile extends StatelessWidget {
  const TrackTile({super.key, required this.item, required this.onTap, this.track, this.index, this.trailing, this.onDeleted});

  final PlayableItem item;
  final Track? track;
  final VoidCallback onTap;
  final VoidCallback? onDeleted;
  final int? index;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerController>();
    final downloads = context.watch<DownloadService>();
    final isCurrent = player.current?.key == item.key;
    final dl = downloads.progress[item.key];
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: Cover(item.artUrl, size: 48, icon: item.isPodcast ? Icons.podcasts : Icons.music_note_rounded),
      title: Text(item.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: isCurrent ? LipinaColors.accent : null, fontWeight: FontWeight.w500)),
      subtitle: Row(children: [
        if (downloads.isDownloaded(item.key) || item.kind == MediaKind.device)
          const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Icon(Icons.download_done_rounded, size: 14, color: LipinaColors.accent)),
        if (dl != null)
          Padding(
              padding: const EdgeInsets.only(right: 6),
              child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(value: dl, strokeWidth: 2))),
        Expanded(
          child: Text(
            [item.subtitle, if (item.duration != null && item.duration! > Duration.zero) formatDuration(item.duration)]
                .where((s) => s.isNotEmpty)
                .join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: LipinaColors.muted),
          ),
        ),
      ]),
      trailing: trailing ??
          IconButton(icon: const Icon(Icons.more_vert), onPressed: () => showItemActions(context, item, track: track, onDeleted: onDeleted)),
    );
  }
}

Future<void> showItemActions(BuildContext context, PlayableItem item, {Track? track, VoidCallback? onDeleted}) {
  final player = context.read<PlayerController>();
  final downloads = context.read<DownloadService>();
  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          leading: Cover(item.artUrl, size: 44),
          title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(item.subtitle, maxLines: 1),
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.playlist_play_rounded),
          title: const Text('Play next'),
          onTap: () {
            player.playNext(item);
            Navigator.pop(sheet);
            toast(context, 'Playing next');
          },
        ),
        ListTile(
          leading: const Icon(Icons.queue_music_rounded),
          title: const Text('Add to queue'),
          onTap: () {
            player.addToQueue(item);
            Navigator.pop(sheet);
            toast(context, 'Added to queue');
          },
        ),
        if (item.kind == MediaKind.track) ...[
          ListTile(
            leading: Icon(player.isLiked(item) ? Icons.favorite : Icons.favorite_border),
            title: Text(player.isLiked(item) ? 'Remove from Liked Songs' : 'Like'),
            onTap: () {
              Navigator.pop(sheet);
              player.toggleLike(item).catchError((Object e) => toast(context, '$e'));
            },
          ),
          ListTile(
            leading: const Icon(Icons.playlist_add_rounded),
            title: const Text('Add to playlist'),
            onTap: () {
              Navigator.pop(sheet);
              showAddToPlaylist(context, [item.remoteId!]);
            },
          ),
          if (track != null) ...[
            ListTile(
              leading: const Icon(Icons.radio_rounded),
              title: const Text('Start track radio'),
              onTap: () {
                Navigator.pop(sheet);
                player.startTrackRadio(track).catchError((Object e) => toast(context, '$e'));
              },
            ),
            if (track.artistId != null)
              ListTile(
                leading: const Icon(Icons.person_rounded),
                title: Text('Go to ${track.artistName}'),
                onTap: () {
                  Navigator.pop(sheet);
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => CollectionScreen.artist(track.artistId!, track.artistName)));
                },
              ),
            if (track.albumId != null)
              ListTile(
                leading: const Icon(Icons.album_rounded),
                title: Text('Go to ${track.albumTitle}'),
                onTap: () {
                  Navigator.pop(sheet);
                  Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => CollectionScreen.album(track.albumId!, track.albumTitle)));
                },
              ),
          ],
        ],
        if (track != null && track.isOwner)
          ListTile(
            leading: const Icon(Icons.delete_forever_outlined, color: Colors.redAccent),
            title: const Text('Delete from library'),
            onTap: () async {
              Navigator.pop(sheet);
              final ok = await showDialog<bool>(
                context: context,
                builder: (d) => AlertDialog(
                  title: const Text('Delete song?'),
                  content: Text('"${item.title}" will be removed from your library and from any playlists.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Delete')),
                  ],
                ),
              );
              if (ok != true || !context.mounted) return;
              await context.read<ApiClient>().delete('/api/tracks/${track.id}/');
              downloads.remove(item.key);
              onDeleted?.call();
              if (context.mounted) toast(context, 'Deleted "${item.title}"');
            },
          ),
        if (item.kind == MediaKind.track || item.kind == MediaKind.episode)
          downloads.isDownloaded(item.key)
              ? ListTile(
                  leading: const Icon(Icons.delete_outline_rounded),
                  title: const Text('Remove download'),
                  onTap: () {
                    downloads.remove(item.key);
                    Navigator.pop(sheet);
                  },
                )
              : ListTile(
                  leading: const Icon(Icons.download_rounded),
                  title: const Text('Download for offline'),
                  onTap: () {
                    Navigator.pop(sheet);
                    downloads.download(item).then(
                          (_) => context.mounted ? toast(context, 'Downloaded "${item.title}"') : null,
                          onError: (Object e) => context.mounted ? toast(context, 'Download failed: $e') : null,
                        );
                  },
                ),
      ]),
    ),
  );
}

Future<void> showAddToPlaylist(BuildContext context, List<int> trackIds) async {
  final api = context.read<ApiClient>();
  await showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      builder: (_, controller) => AsyncView<List<Playlist>>(
        load: () async => (await api.getList('/api/playlists/')).map(Playlist.new).toList(),
        builder: (_, playlists, reload) => ListView(controller: controller, children: [
          ListTile(
            leading: const Icon(Icons.add_rounded),
            title: const Text('New playlist'),
            onTap: () async {
              final name = await promptText(sheet, 'New playlist', 'Playlist name');
              if (name == null || name.isEmpty) return;
              final created = await api.post('/api/playlists/', {'name': name});
              await api.post('/api/playlists/${created['id']}/tracks/', {'track_ids': trackIds});
              if (sheet.mounted) Navigator.pop(sheet);
              if (context.mounted) toast(context, 'Added to $name');
            },
          ),
          for (final p in playlists)
            ListTile(
              leading: Cover(p.coverUrl, size: 44, icon: Icons.queue_music),
              title: Text(p.name),
              subtitle: Text('${p.trackCount} tracks'),
              onTap: () async {
                await api.post('/api/playlists/${p.id}/tracks/', {'track_ids': trackIds});
                if (sheet.mounted) Navigator.pop(sheet);
                if (context.mounted) toast(context, 'Added to ${p.name}');
              },
            ),
        ]),
      ),
    ),
  );
}

Future<String?> promptText(BuildContext context, String title, String hint, {String initial = ''}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(title),
      content: TextField(controller: controller, autofocus: true, decoration: InputDecoration(hintText: hint),
          onSubmitted: (v) => Navigator.pop(d, v.trim())),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(d, controller.text.trim()), child: const Text('Save')),
      ],
    ),
  );
}
