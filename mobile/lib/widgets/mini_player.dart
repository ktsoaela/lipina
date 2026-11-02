import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app.dart';
import '../screens/now_playing_screen.dart';
import '../services/player_controller.dart';
import 'common.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerController>();
    final item = player.current;
    if (item == null) return const SizedBox.shrink();
    return GestureDetector(
      onTap: () => Navigator.of(context, rootNavigator: true).push(NowPlayingScreen.route()),
      onVerticalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) < -200) Navigator.of(context, rootNavigator: true).push(NowPlayingScreen.route());
      },
      child: Container(
        margin: const EdgeInsets.fromLTRB(8, 0, 8, 4),
        decoration: BoxDecoration(color: LipinaColors.surfaceHi, borderRadius: BorderRadius.circular(12)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 4, 6),
            child: Row(children: [
              Hero(tag: 'np-art', child: Cover(item.artUrl, size: 44, icon: item.isLive ? Icons.radio : Icons.music_note)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(player.liveTitle ?? item.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(player.liveTitle != null ? item.title : item.subtitle,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: LipinaColors.muted, fontSize: 12)),
                ]),
              ),
              if (item.isLive)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: Text('LIVE', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 11)),
                ),
              IconButton(
                icon: Icon(player.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 30),
                onPressed: player.toggle,
              ),
              if (!item.isLive) IconButton(icon: const Icon(Icons.skip_next_rounded), onPressed: player.next),
            ]),
          ),
          if (!item.isLive)
            StreamBuilder<Duration>(
              stream: player.position,
              builder: (_, snap) {
                final total = item.duration ?? player.player.duration ?? Duration.zero;
                final pos = snap.data ?? Duration.zero;
                final v = total.inMilliseconds == 0 ? 0.0 : (pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0).toDouble();
                return ClipRRect(
                  borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
                  child: LinearProgressIndicator(value: v, minHeight: 2, backgroundColor: Colors.white10),
                );
              },
            ),
        ]),
      ),
    );
  }
}
