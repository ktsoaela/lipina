import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';

import '../app.dart';
import '../models/models.dart';
import '../services/download_service.dart';
import '../services/player_controller.dart';
import '../widgets/common.dart';
import '../widgets/track_tile.dart';
import 'tools_screen.dart';

class NowPlayingScreen extends StatefulWidget {
  const NowPlayingScreen({super.key});

  static Route<void> route() => PageRouteBuilder(
        pageBuilder: (_, __, ___) => const NowPlayingScreen(),
        transitionsBuilder: (_, anim, __, child) => SlideTransition(
          position: Tween(begin: const Offset(0, 1), end: Offset.zero)
              .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
          child: child,
        ),
      );

  @override
  State<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends State<NowPlayingScreen> {
  int _tab = 0; // 0 art, 1 lyrics, 2 queue

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerController>();
    final item = player.current;
    if (item == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
      return const Scaffold();
    }
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF173A33), LipinaColors.bg],
          ),
        ),
        child: SafeArea(
          child: Column(children: [
            Row(children: [
              IconButton(icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 32), onPressed: () => Navigator.pop(context)),
              Expanded(
                child: Text(
                  item.isLive ? 'Live radio' : item.isPodcast ? 'Podcast' : (item.album.isEmpty ? 'Now playing' : item.album),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, color: LipinaColors.muted),
                ),
              ),
              IconButton(icon: const Icon(Icons.more_vert), onPressed: () => showItemActions(context, item)),
            ]),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: switch (_tab) {
                  1 => _LyricsView(key: const ValueKey('lyrics'), player: player),
                  2 => _QueueView(key: const ValueKey('queue'), player: player),
                  _ => Padding(
                      key: const ValueKey('art'),
                      padding: const EdgeInsets.all(28),
                      child: Center(
                        child: Hero(
                          tag: 'np-art',
                          child: LayoutBuilder(
                            builder: (_, c) => Cover(item.artUrl,
                                size: c.biggest.shortestSide, radius: 16, icon: item.isLive ? Icons.radio : Icons.music_note),
                          ),
                        ),
                      ),
                    ),
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(player.liveTitle ?? item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    Text(player.liveTitle != null ? item.title : item.subtitle,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: LipinaColors.muted)),
                  ]),
                ),
                if (item.kind == MediaKind.track)
                  IconButton(
                    icon: Icon(player.isLiked(item) ? Icons.favorite : Icons.favorite_border,
                        color: player.isLiked(item) ? LipinaColors.accent : null),
                    onPressed: () => player.toggleLike(item).catchError((Object e) => toast(context, '$e')),
                  ),
                _DownloadButton(item: item),
              ]),
            ),
            if (player.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(player.error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
              ),
            if (!item.isLive) _SeekBar(player: player, item: item) else const _LiveBar(),
            _Transport(player: player, item: item),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                IconButton(
                  tooltip: 'Lyrics',
                  isSelected: _tab == 1,
                  icon: const Icon(Icons.lyrics_outlined),
                  selectedIcon: const Icon(Icons.lyrics, color: LipinaColors.accent),
                  onPressed: item.isLive || item.isPodcast
                      ? null
                      : () {
                          setState(() => _tab = _tab == 1 ? 0 : 1);
                          if (_tab == 1 && player.lyrics.isEmpty && player.plainLyrics.isEmpty) player.loadLyrics();
                        },
                ),
                IconButton(
                  tooltip: 'Sleep timer',
                  icon: Icon(player.sleepAt != null || player.sleepAtEndOfTrack ? Icons.bedtime : Icons.bedtime_outlined,
                      color: player.sleepAt != null || player.sleepAtEndOfTrack ? LipinaColors.accent : null),
                  onPressed: () => showSleepTimer(context),
                ),
                if (item.isPodcast || item.kind == MediaKind.device || item.kind == MediaKind.track)
                  TextButton(
                    onPressed: () => _pickSpeed(context, player),
                    child: Text('${player.speed.toStringAsFixed(player.speed % 1 == 0 ? 0 : 2)}×'),
                  ),
                IconButton(
                  tooltip: 'Equalizer & tools',
                  icon: const Icon(Icons.equalizer_rounded),
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ToolsScreen(initialTab: 3))),
                ),
                IconButton(
                  tooltip: 'Queue',
                  isSelected: _tab == 2,
                  icon: const Icon(Icons.queue_music_outlined),
                  selectedIcon: const Icon(Icons.queue_music, color: LipinaColors.accent),
                  onPressed: () => setState(() => _tab = _tab == 2 ? 0 : 2),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  void _pickSpeed(BuildContext context, PlayerController player) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (s) => SafeArea(
        child: Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
          for (final v in const [0.75, 1.0, 1.25, 1.5, 1.75, 2.0])
            ChoiceChip(
              label: Text('$v×'),
              selected: player.speed == v,
              onSelected: (_) {
                player.setSpeed(v);
                Navigator.pop(s);
              },
            ),
          const SizedBox(height: 60, width: double.infinity),
        ]),
      ),
    );
  }
}

class _DownloadButton extends StatelessWidget {
  const _DownloadButton({required this.item});
  final PlayableItem item;

  @override
  Widget build(BuildContext context) {
    if (item.isLive || item.kind == MediaKind.device || item.kind == MediaKind.preview) return const SizedBox.shrink();
    final dl = context.watch<DownloadService>();
    final p = dl.progress[item.key];
    if (p != null) {
      return Padding(
          padding: const EdgeInsets.all(12),
          child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(value: p, strokeWidth: 2)));
    }
    final done = dl.isDownloaded(item.key);
    return IconButton(
      tooltip: done ? 'Downloaded' : 'Download',
      icon: Icon(done ? Icons.download_done_rounded : Icons.download_rounded, color: done ? LipinaColors.accent : null),
      onPressed: done
          ? null
          : () => dl.download(item).catchError((Object e) {
                if (context.mounted) toast(context, 'Download failed: $e');
              }),
    );
  }
}

class _SeekBar extends StatefulWidget {
  const _SeekBar({required this.player, required this.item});
  final PlayerController player;
  final PlayableItem item;

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double? _drag;

  @override
  Widget build(BuildContext context) => StreamBuilder<Duration>(
        stream: widget.player.position,
        builder: (_, snap) {
          final total = widget.player.player.duration ?? widget.item.duration ?? Duration.zero;
          final pos = snap.data ?? Duration.zero;
          final max = total.inMilliseconds.toDouble().clamp(1.0, double.infinity).toDouble();
          final value = (_drag ?? pos.inMilliseconds.toDouble()).clamp(0.0, max).toDouble();
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(children: [
              Slider(
                value: value,
                max: max,
                onChanged: (v) => setState(() => _drag = v),
                onChangeEnd: (v) {
                  widget.player.seek(Duration(milliseconds: v.round()));
                  setState(() => _drag = null);
                },
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text(formatDuration(Duration(milliseconds: value.round())), style: const TextStyle(fontSize: 12, color: LipinaColors.muted)),
                  Text(formatDuration(total), style: const TextStyle(fontSize: 12, color: LipinaColors.muted)),
                ]),
              ),
            ]),
          );
        },
      );
}

class _LiveBar extends StatelessWidget {
  const _LiveBar();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 22),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.circle, color: Colors.redAccent, size: 10),
          SizedBox(width: 6),
          Text('LIVE', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 2)),
        ]),
      );
}

class _Transport extends StatelessWidget {
  const _Transport({required this.player, required this.item});
  final PlayerController player;
  final PlayableItem item;

  @override
  Widget build(BuildContext context) {
    final podcast = item.isPodcast;
    return StreamBuilder<PlayerState>(
      stream: player.player.playerStateStream,
      builder: (_, snap) {
        final state = snap.data?.processingState;
        final loading = state == ProcessingState.loading || state == ProcessingState.buffering;
        return Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          if (item.isLive)
            const SizedBox(width: 48)
          else if (podcast)
            IconButton(icon: const Icon(Icons.replay_10_rounded, size: 30), onPressed: () => player.seekRelative(-15))
          else
            IconButton(
              icon: Icon(Icons.shuffle_rounded, color: player.shuffle ? LipinaColors.accent : null),
              onPressed: player.toggleShuffle,
            ),
          IconButton(
              icon: const Icon(Icons.skip_previous_rounded, size: 38), onPressed: item.isLive ? null : player.previous),
          SizedBox(
            width: 72,
            height: 72,
            child: FilledButton(
              style: FilledButton.styleFrom(shape: const CircleBorder(), padding: EdgeInsets.zero),
              onPressed: player.toggle,
              child: loading
                  ? const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3, color: Colors.black))
                  : Icon(player.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 40),
            ),
          ),
          IconButton(icon: const Icon(Icons.skip_next_rounded, size: 38), onPressed: item.isLive ? null : player.next),
          if (item.isLive)
            const SizedBox(width: 48)
          else if (podcast)
            IconButton(icon: const Icon(Icons.forward_30_rounded, size: 30), onPressed: () => player.seekRelative(30))
          else
            IconButton(
              icon: Icon(player.repeat == AudioServiceRepeatMode.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                  color: player.repeat == AudioServiceRepeatMode.none ? null : LipinaColors.accent),
              onPressed: player.cycleRepeat,
            ),
        ]);
      },
    );
  }
}

class _LyricsView extends StatefulWidget {
  const _LyricsView({super.key, required this.player});
  final PlayerController player;

  @override
  State<_LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<_LyricsView> {
  final _scroll = ScrollController();
  int _active = -1;
  static const _lineHeight = 44.0;

  @override
  Widget build(BuildContext context) {
    final p = widget.player;
    if (p.lyricsLoading) return const Center(child: CircularProgressIndicator());
    if (p.lyrics.isEmpty && p.plainLyrics.isEmpty) {
      return const EmptyState(icon: Icons.lyrics_outlined, title: 'No lyrics found for this song');
    }
    if (p.lyrics.isEmpty) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Text(p.plainLyrics, style: const TextStyle(fontSize: 18, height: 1.6)),
      );
    }
    return StreamBuilder<Duration>(
      stream: p.position,
      builder: (_, snap) {
        final pos = snap.data ?? Duration.zero;
        final active = p.lyrics.lastIndexWhere((l) => l.time <= pos + const Duration(milliseconds: 250));
        if (active != _active) {
          _active = active;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scroll.hasClients && active >= 0) {
              _scroll.animateTo((active * _lineHeight - 120).clamp(0.0, _scroll.position.maxScrollExtent).toDouble(),
                  duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
            }
          });
        }
        return ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 120),
          itemExtent: _lineHeight,
          itemCount: p.lyrics.length,
          itemBuilder: (_, i) => GestureDetector(
            onTap: () => p.seek(p.lyrics[i].time),
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 200),
              style: TextStyle(
                fontSize: i == active ? 22 : 18,
                fontWeight: i == active ? FontWeight.w800 : FontWeight.w500,
                color: i == active ? Colors.white : Colors.white38,
              ),
              child: Text(p.lyrics[i].text.isEmpty ? '♪' : p.lyrics[i].text, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
        );
      },
    );
  }
}

class _QueueView extends StatelessWidget {
  const _QueueView({super.key, required this.player});
  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    final upNext = player.upNext;
    if (upNext.isEmpty) return const EmptyState(icon: Icons.queue_music, title: 'Nothing up next');
    return ListView.builder(
      itemCount: upNext.length + 1,
      itemBuilder: (_, i) => i == 0
          ? const Padding(padding: EdgeInsets.fromLTRB(16, 8, 16, 4), child: Text('Up next', style: TextStyle(fontWeight: FontWeight.bold)))
          : Dismissible(
              key: ValueKey('${upNext[i - 1].key}-$i'),
              direction: DismissDirection.endToStart,
              background: Container(color: Colors.red.withValues(alpha: 0.3), alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20), child: const Icon(Icons.delete)),
              onDismissed: (_) => player.handler.removeUpcoming(i - 1),
              child: TrackTile(item: upNext[i - 1], onTap: () => player.handler.jumpToUpNext(i - 1)),
            ),
    );
  }
}

void showSleepTimer(BuildContext context) {
  final player = context.read<PlayerController>();
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (s) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Sleep timer', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        if (player.sleepAt != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text('Stops at ${TimeOfDay.fromDateTime(player.sleepAt!).format(context)}',
                style: const TextStyle(color: LipinaColors.accent)),
          ),
        for (final m in const [5, 15, 30, 45, 60, 90])
          ListTile(
            title: Text('$m minutes'),
            onTap: () {
              player.setSleepTimer(Duration(minutes: m));
              Navigator.pop(s);
            },
          ),
        ListTile(
          title: const Text('End of current track'),
          onTap: () {
            player.setSleepTimer(null, endOfTrack: true);
            Navigator.pop(s);
          },
        ),
        if (player.sleepAt != null || player.sleepAtEndOfTrack)
          ListTile(
            leading: const Icon(Icons.close),
            title: const Text('Turn off'),
            onTap: () {
              player.setSleepTimer(null);
              Navigator.pop(s);
            },
          ),
      ]),
    ),
  );
}
