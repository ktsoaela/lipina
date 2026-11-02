import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../app.dart';
import '../models/models.dart';
import '../services/download_service.dart';
import '../services/player_controller.dart';
import '../widgets/common.dart';
import '../widgets/track_tile.dart';

class PodcastsScreen extends StatefulWidget {
  const PodcastsScreen({super.key});

  @override
  State<PodcastsScreen> createState() => _PodcastsScreenState();
}

class _PodcastsScreenState extends State<PodcastsScreen> {
  final _q = TextEditingController();
  Timer? _debounce;
  Future<List<Podcast>>? _search;

  @override
  Widget build(BuildContext context) {
    final api = context.read<ApiClient>();
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Podcasts', style: TextStyle(fontWeight: FontWeight.w800)),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(108),
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _q,
                  decoration: const InputDecoration(
                      hintText: 'Search all podcasts', prefixIcon: Icon(Icons.search), contentPadding: EdgeInsets.zero),
                  onChanged: (v) {
                    _debounce?.cancel();
                    _debounce = Timer(const Duration(milliseconds: 400), () {
                      setState(() => _search = v.trim().isEmpty
                          ? null
                          : api.get('/api/podcasts/directory/search/', query: {'q': v.trim()})
                              .then((l) => (l as List).map((e) => Podcast(Map<String, dynamic>.from(e))).toList()));
                    });
                  },
                ),
              ),
              const TabBar(tabs: [Tab(text: 'Top in SA'), Tab(text: 'Following'), Tab(text: 'New episodes')]),
            ]),
          ),
        ),
        body: _search != null
            ? FutureBuilder<List<Podcast>>(
                future: _search,
                builder: (_, snap) => snap.hasData
                    ? _PodcastList(podcasts: snap.data!)
                    : snap.hasError
                        ? EmptyState(icon: Icons.error_outline, title: '${snap.error}')
                        : const Center(child: CircularProgressIndicator()),
              )
            : TabBarView(children: [
                AsyncView<List<Podcast>>(
                  load: () async => ((await api.get('/api/podcasts/directory/top/')) as List)
                      .map((e) => Podcast(Map<String, dynamic>.from(e)))
                      .toList(),
                  builder: (_, list, __) => _PodcastList(podcasts: list, ranked: true),
                ),
                AsyncView<List<Podcast>>(
                  load: () async => ((await api.get('/api/podcasts/shows/subscriptions/')) as List)
                      .map((e) => Podcast(Map<String, dynamic>.from(e)))
                      .toList(),
                  builder: (_, list, reload) => list.isEmpty
                      ? const EmptyState(icon: Icons.podcasts, title: 'Follow shows to see them here')
                      : RefreshIndicator(onRefresh: reload, child: _PodcastList(podcasts: list)),
                ),
                AsyncView<List<Episode>>(
                  load: () async => (await api.getList('/api/podcasts/shows/feed/', query: {'limit': 50}))
                      .map(Episode.new)
                      .toList(),
                  builder: (_, list, reload) => list.isEmpty
                      ? const EmptyState(icon: Icons.inbox_outlined, title: 'No new episodes')
                      : RefreshIndicator(onRefresh: reload, child: _EpisodeList(episodes: list, showShow: true)),
                ),
              ]),
      ),
    );
  }
}

class _PodcastList extends StatelessWidget {
  const _PodcastList({required this.podcasts, this.ranked = false});
  final List<Podcast> podcasts;
  final bool ranked;

  @override
  Widget build(BuildContext context) => ListView.builder(
        itemCount: podcasts.length,
        itemBuilder: (_, i) {
          final p = podcasts[i];
          return ListTile(
            leading: Row(mainAxisSize: MainAxisSize.min, children: [
              if (ranked) SizedBox(width: 28, child: Text('${i + 1}', style: const TextStyle(fontWeight: FontWeight.bold))),
              Cover(p.image, size: 56, icon: Icons.podcasts),
            ]),
            title: Text(p.title, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(p.author, maxLines: 1, style: const TextStyle(color: LipinaColors.muted)),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PodcastDetailScreen(podcast: p))),
          );
        },
      );
}

/// Show page. Accepts either an imported podcast (has `id`) or a directory result
/// (has `itunes_id`/`feed_url`) â€” the latter is imported on first open.
class PodcastDetailScreen extends StatefulWidget {
  const PodcastDetailScreen({super.key, required this.podcast});
  final Podcast podcast;

  @override
  State<PodcastDetailScreen> createState() => _PodcastDetailScreenState();
}

class _PodcastDetailScreenState extends State<PodcastDetailScreen> {
  late Podcast _podcast = widget.podcast;

  Future<List<Episode>> _load() async {
    final api = context.read<ApiClient>();
    if (_podcast.id == null) {
      final imported = await api.post('/api/podcasts/shows/', {
        if (_podcast.itunesId != null) 'itunes_id': _podcast.itunesId else 'feed_url': _podcast.feedUrl,
      });
      _podcast = Podcast(Map<String, dynamic>.from(imported as Map));
    }
    final list = await api.getList('/api/podcasts/shows/${_podcast.id}/episodes/', query: {'limit': 200});
    return list.map(Episode.new).toList();
  }

  Future<void> _toggleSubscribe() async {
    final api = context.read<ApiClient>();
    final next = !_podcast.isSubscribed;
    setState(() => _podcast.isSubscribed = next);
    try {
      next
          ? await api.post('/api/podcasts/shows/${_podcast.id}/subscribe/')
          : await api.delete('/api/podcasts/shows/${_podcast.id}/subscribe/');
    } catch (e) {
      if (!mounted) return;
      setState(() => _podcast.isSubscribed = !next);
      toast(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(_podcast.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
        body: AsyncView<List<Episode>>(
          load: _load,
          builder: (context, episodes, reload) => RefreshIndicator(
            onRefresh: reload,
            child: CustomScrollView(slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Cover(_podcast.image, size: 120, radius: 12, icon: Icons.podcasts),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(_podcast.title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                          const SizedBox(height: 4),
                          Text(_podcast.author, style: const TextStyle(color: LipinaColors.muted)),
                          const SizedBox(height: 12),
                          _podcast.isSubscribed
                              ? OutlinedButton.icon(
                                  onPressed: _toggleSubscribe, icon: const Icon(Icons.check), label: const Text('Following'))
                              : FilledButton.icon(
                                  onPressed: _toggleSubscribe, icon: const Icon(Icons.add), label: const Text('Follow')),
                        ]),
                      ),
                    ]),
                    if (_podcast.description.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(_podcast.description, maxLines: 4, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: LipinaColors.muted)),
                    ],
                  ]),
                ),
              ),
              SliverList.separated(
                itemCount: episodes.length,
                separatorBuilder: (_, __) => const Divider(height: 1, indent: 16),
                itemBuilder: (_, i) => _EpisodeTile(episode: episodes[i]),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ]),
          ),
        ),
      );
}

class _EpisodeList extends StatelessWidget {
  const _EpisodeList({required this.episodes, this.showShow = false});
  final List<Episode> episodes;
  final bool showShow;

  @override
  Widget build(BuildContext context) => ListView.separated(
        itemCount: episodes.length,
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 16),
        itemBuilder: (_, i) => _EpisodeTile(episode: episodes[i], showShow: showShow),
      );
}

class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile({required this.episode, this.showShow = false});
  final Episode episode;
  final bool showShow;

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerController>();
    final downloads = context.watch<DownloadService>();
    final e = episode;
    final item = PlayableItem.fromEpisode(e);
    final isCurrent = player.current?.key == item.key;
    final progress = e.duration > 0 ? (e.position / e.duration).clamp(0.0, 1.0).toDouble() : 0.0;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: showShow ? Cover(e.podcastImage, size: 48, icon: Icons.podcasts) : null,
      title: Text(e.title, maxLines: 2, overflow: TextOverflow.ellipsis,
          style: TextStyle(fontWeight: FontWeight.w600, color: isCurrent ? LipinaColors.accent : null)),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 4),
        Text(
          [
            if (showShow) e.podcastTitle,
            if (e.publishedAt != null) MaterialLocalizations.of(context).formatMediumDate(e.publishedAt!),
            if (e.duration > 0) formatDuration(Duration(seconds: e.duration)),
            if (e.completed) 'Played',
          ].join(' · '),
          style: const TextStyle(color: LipinaColors.muted, fontSize: 12),
        ),
        if (progress > 0 && !e.completed)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: LinearProgressIndicator(value: progress, minHeight: 2),
          ),
      ]),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (downloads.isDownloaded(item.key))
          const Icon(Icons.download_done_rounded, color: LipinaColors.accent, size: 20),
        IconButton(icon: const Icon(Icons.more_vert), onPressed: () => showItemActions(context, item)),
      ]),
      onTap: () => player.playEpisode(e),
    );
  }
}
