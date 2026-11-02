import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../api/api_client.dart';
import '../app.dart';
import '../models/models.dart';
import '../services/player_controller.dart';
import '../widgets/common.dart';

/// Search Apple Music (iTunes previews) and YouTube Music, play them in Lipina, or jump
/// to the Spotify / Apple Music / YouTube Music apps. No Google Play Services needed,
/// so this works the same on Huawei (HMS) phones.
class StreamingScreen extends StatefulWidget {
  const StreamingScreen({super.key, this.initialQuery = ''});
  final String initialQuery;

  @override
  State<StreamingScreen> createState() => _StreamingScreenState();
}

class _StreamingScreenState extends State<StreamingScreen> {
  late final _q = TextEditingController(text: widget.initialQuery);
  Timer? _debounce;
  Map? _config;
  List<PlayableItem> _previews = [];
  List<YouTubeVideo> _videos = [];
  String? _previewError;
  String? _videoError;
  bool _loading = false;
  int _seq = 0;

  ApiClient get _api => context.read<ApiClient>();

  @override
  void initState() {
    super.initState();
    _api.get('/api/connect/').then((c) {
      if (!mounted) return;
      setState(() => _config = c as Map);
      if (_q.text.trim().isNotEmpty) _search(_q.text);
    }).catchError((Object e) {
      if (mounted) setState(() => _config = const {});
    });
  }

  bool get _youtubeEnabled => (_config?['youtube'] as Map?)?['enabled'] == true;

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () => _search(v));
    setState(() {});
  }

  Future<void> _search(String raw) async {
    final q = raw.trim();
    final mine = ++_seq;
    if (q.isEmpty) {
      setState(() {
        _previews = [];
        _videos = [];
        _previewError = _videoError = null;
      });
      return;
    }
    setState(() => _loading = true);
    await Future.wait([
      _api.get('/api/connect/itunes/search/', query: {'q': q}).then((r) {
        if (mine != _seq || !mounted) return;
        setState(() {
          _previews = ((r as Map)['results'] as List).map((e) => PlayableItem.fromITunes(Map<String, dynamic>.from(e as Map))).toList();
          _previewError = null;
        });
      }).catchError((Object e) {
        if (mine == _seq && mounted) setState(() => _previewError = '$e');
      }),
      if (_youtubeEnabled)
        _api.get('/api/connect/youtube/search/', query: {'q': q}).then((r) {
          if (mine != _seq || !mounted) return;
          setState(() {
            _videos = ((r as Map)['results'] as List).map((e) => YouTubeVideo(Map<String, dynamic>.from(e as Map))).toList();
            _videoError = null;
          });
        }).catchError((Object e) {
          if (mine == _seq && mounted) setState(() => _videoError = '$e');
        }),
    ]);
    if (mine == _seq && mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.text.trim();
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _q,
          autofocus: widget.initialQuery.isEmpty,
          onChanged: _onChanged,
          onSubmitted: _search,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
              hintText: 'Search Apple Music & YouTube Music', prefixIcon: Icon(Icons.search), contentPadding: EdgeInsets.zero),
        ),
        bottom: _loading ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator()) : null,
      ),
      body: ListView(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            for (final s in StreamingApp.values)
              ActionChip(
                avatar: Icon(Icons.open_in_new, size: 16, color: s.color),
                label: Text('Open in ${s.label}'),
                onPressed: () => openStreamingApp(context, s, q),
              ),
          ]),
        ),
        if (q.isEmpty)
          const EmptyState(
            icon: Icons.cast_connected_rounded,
            title: 'Your streaming services',
            message: 'Search to play Apple Music previews and YouTube Music videos here, '
                'or open Spotify, Apple Music or YouTube Music to listen with your own account.',
          ),
        if (q.isNotEmpty) ...[
          const SectionHeader('Apple Music · 30-second previews'),
          if (_previewError != null) _Note(_previewError!),
          if (_previewError == null && _previews.isEmpty && !_loading) const _Note('No previews found.'),
          for (final (i, item) in _previews.indexed)
            ListTile(
              leading: Cover(item.artUrl, size: 48),
              title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${item.subtitle} · Preview', maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: IconButton(
                tooltip: 'Open in Apple Music',
                icon: const Icon(Icons.open_in_new),
                onPressed: () => _launch(context, item.extra['external_url'] as String?),
              ),
              onTap: () => context.read<PlayerController>().playItems(_previews, start: i),
            ),
          const SectionHeader('YouTube Music'),
          if (!_youtubeEnabled) const _Note('YouTube Music isn\'t set up on your Lipina server yet.'),
          if (_videoError != null) _Note(_videoError!),
          if (_youtubeEnabled && _videoError == null && _videos.isEmpty && !_loading) const _Note('No videos found.'),
          for (final (i, v) in _videos.indexed)
            ListTile(
              leading: Cover(v.art, size: 48, icon: Icons.smart_display_rounded),
              title: Text(v.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text([v.artist, if (v.duration > 0) fmtDuration(Duration(seconds: v.duration))].join(' · '),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: const Icon(Icons.play_circle_outline),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => YouTubePlayerScreen(videos: _videos, start: i))),
            ),
          const SizedBox(height: 24),
        ],
      ]),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;
  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), child: Text(text, style: const TextStyle(color: LipinaColors.muted)));
}

String fmtDuration(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(d.inHours > 0 ? 2 : 1, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
}

class YouTubeVideo {
  YouTubeVideo(this.json);
  final Json json;
  String get id => json['id'] as String;
  String get title => json['title'] as String? ?? '';
  String get artist => json['artist'] as String? ?? '';
  String? get art => json['art'] as String?;
  int get duration => (json['duration'] as num?)?.toInt() ?? 0;
  String get url => json['url'] as String? ?? 'https://music.youtube.com/watch?v=$id';
}

// ------------------------------------------------------------ open other apps

enum StreamingApp {
  spotify('Spotify', Color(0xFF1DB954)),
  appleMusic('Apple Music', Color(0xFFFA2D48)),
  youtubeMusic('YouTube Music', Color(0xFFFF0033));

  const StreamingApp(this.label, this.color);
  final String label;
  final Color color;

  /// Universal links: they open the installed app, or the website when it isn't installed.
  Uri searchUri(String q) => switch (this) {
        StreamingApp.spotify => q.isEmpty ? Uri.parse('https://open.spotify.com/') : Uri.parse('https://open.spotify.com/search/${Uri.encodeComponent(q)}'),
        StreamingApp.appleMusic => Uri.https('music.apple.com', '/za/search', q.isEmpty ? null : {'term': q}),
        StreamingApp.youtubeMusic => Uri.https('music.youtube.com', q.isEmpty ? '/' : '/search', q.isEmpty ? null : {'q': q}),
      };
}

Future<void> openStreamingApp(BuildContext context, StreamingApp app, String q) async {
  if (app == StreamingApp.spotify) {
    // Prefer the Spotify app's own scheme; fall back to the web link.
    final native = Uri.parse(q.isEmpty ? 'spotify:' : 'spotify:search:${Uri.encodeComponent(q)}');
    try {
      if (await launchUrl(native, mode: LaunchMode.externalApplication)) return;
    } catch (_) {/* not installed */}
  }
  if (context.mounted) await _launch(context, app.searchUri(q).toString());
}

Future<void> _launch(BuildContext context, String? url) async {
  if (url == null || url.isEmpty) return;
  final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication).catchError((_) => false);
  if (!ok && context.mounted) toast(context, 'Couldn\'t open $url');
}

// -------------------------------------------------------------- YouTube player

/// Plays YouTube Music videos with YouTube's official embedded player and walks
/// through the search results as a queue.
class YouTubePlayerScreen extends StatefulWidget {
  const YouTubePlayerScreen({super.key, required this.videos, this.start = 0});
  final List<YouTubeVideo> videos;
  final int start;

  @override
  State<YouTubePlayerScreen> createState() => _YouTubePlayerScreenState();
}

class _YouTubePlayerScreenState extends State<YouTubePlayerScreen> {
  late int _index = widget.start;
  late final YoutubePlayerController _yt;
  StreamSubscription<YoutubePlayerValue>? _sub;
  PlayerState _state = PlayerState.unknown;

  YouTubeVideo get _video => widget.videos[_index];

  @override
  void initState() {
    super.initState();
    final player = context.read<PlayerController>();
    if (player.playing) player.toggle(); // one thing at a time
    _yt = YoutubePlayerController.fromVideoId(
      videoId: _video.id,
      autoPlay: true,
      params: const YoutubePlayerParams(showFullscreenButton: true, strictRelatedVideos: true, playsInline: true),
    );
    _sub = _yt.listen((v) {
      if (v.playerState == _state) return;
      final ended = v.playerState == PlayerState.ended && _state != PlayerState.ended;
      if (mounted) setState(() => _state = v.playerState);
      if (ended && _index < widget.videos.length - 1) _go(_index + 1);
    });
  }

  void _go(int i) {
    if (i < 0 || i >= widget.videos.length) return;
    setState(() => _index = i);
    _yt.loadVideoById(videoId: widget.videos[i].id);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _yt.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playing = _state == PlayerState.playing || _state == PlayerState.buffering;
    return Scaffold(
      appBar: AppBar(title: const Text('YouTube Music'), actions: [
        IconButton(
          tooltip: 'Open in YouTube Music',
          icon: const Icon(Icons.open_in_new),
          onPressed: () {
            _yt.pauseVideo();
            _launch(context, _video.url);
          },
        ),
      ]),
      body: ListView(children: [
        YoutubePlayer(controller: _yt, aspectRatio: 16 / 9),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Text(_video.title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(_video.artist, style: const TextStyle(color: LipinaColors.muted)),
        ),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          IconButton(iconSize: 36, icon: const Icon(Icons.skip_previous_rounded), onPressed: _index > 0 ? () => _go(_index - 1) : null),
          IconButton.filled(
            iconSize: 44,
            icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
            onPressed: () => playing ? _yt.pauseVideo() : _yt.playVideo(),
          ),
          IconButton(
              iconSize: 36,
              icon: const Icon(Icons.skip_next_rounded),
              onPressed: _index < widget.videos.length - 1 ? () => _go(_index + 1) : null),
        ]),
        const SectionHeader('Up next'),
        for (final (i, v) in widget.videos.indexed)
          if (i > _index)
            ListTile(
              leading: Cover(v.art, size: 44, icon: Icons.smart_display_rounded),
              title: Text(v.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(v.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => _go(i),
            ),
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('YouTube videos keep playing only while this screen is open.',
              style: TextStyle(color: LipinaColors.muted, fontSize: 12)),
        ),
      ]),
    );
  }
}
