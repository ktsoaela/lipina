import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import 'audio_handler.dart';
import 'connectivity_service.dart';
import 'download_service.dart';
import 'offline_store.dart';

/// UI-facing facade over the audio handler: queue building, likes, history sync,
/// podcast resume points, sleep timer, lyrics and EQ.
class PlayerController extends ChangeNotifier {
  PlayerController(this.handler, this.api, this.store, this.downloads, this.connectivity) {
    handler.current.addListener(_onCurrentChanged);
    handler.upNext.addListener(notifyListeners);
    handler.liveTitle.addListener(notifyListeners);
    handler.error.addListener(notifyListeners);
    handler.player.playingStream.listen((playing) {
      notifyListeners();
      if (!playing) _savePodcastProgress();
    });
    handler.onItemFinished = _recordPlay;
    connectivity.cameOnline.listen((_) => api.flushOutbox());
    api.flushOutbox();
    _progressTimer = Timer.periodic(const Duration(seconds: 20), (_) => _savePodcastProgress());
  }

  final LipinaAudioHandler handler;
  final ApiClient api;
  final OfflineStore store;
  final DownloadService downloads;
  final ConnectivityService connectivity;
  late final Timer _progressTimer;

  AudioPlayer get player => handler.player;
  PlayableItem? get current => handler.current.value;
  List<PlayableItem> get upNext => handler.upNext.value;
  bool get playing => player.playing;
  String? get liveTitle => handler.liveTitle.value;
  String? get error => handler.error.value;
  bool get shuffle => handler.shuffleEnabled;
  AudioServiceRepeatMode get repeat => handler.repeatMode;
  Stream<Duration> get position => player.positionStream;
  Stream<Duration?> get duration => player.durationStream;
  Stream<Duration> get buffered => player.bufferedPositionStream;
  double get speed => player.speed;

  List<LyricLine> lyrics = const [];
  String plainLyrics = '';
  bool lyricsLoading = false;

  // ------------------------------------------------------------ play APIs

  PlayableItem _withLocal(PlayableItem item) => item..localPath = downloads.localPathFor(item.key) ?? item.localPath;

  Future<void> playItems(List<PlayableItem> items, {int start = 0, bool shuffle = false}) async {
    if (items.isEmpty) return;
    if (shuffle != handler.shuffleEnabled) {
      await handler.setShuffleMode(shuffle ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none);
    }
    await handler.setQueueItems(items.map(_withLocal).toList(), start: start);
  }

  Future<void> playTracks(List<Track> tracks, {int start = 0, bool shuffle = false}) =>
      playItems(tracks.map(PlayableItem.fromTrack).toList(), start: start, shuffle: shuffle);

  Future<void> playEpisode(Episode e) => playItems([PlayableItem.fromEpisode(e)]);

  Future<void> playStation(Station s) async {
    api.post('/api/radio/stations/${s.id}/play/').ignore(); // popularity ping
    await playItems([PlayableItem.fromStation(s)]);
  }

  /// "Track radio": endless mix seeded from one track.
  Future<void> startTrackRadio(Track seed) async {
    final list = await api.get('/api/tracks/${seed.id}/radio/', cache: false) as List;
    await playTracks(list.map((e) => Track(Map<String, dynamic>.from(e as Map))).toList());
  }

  void playNext(PlayableItem item) => handler.playNext(_withLocal(item));
  void addToQueue(PlayableItem item) => handler.addToQueue(_withLocal(item));

  Future<void> toggle() => playing ? handler.pause() : handler.play();
  Future<void> next() => handler.skipToNext();
  Future<void> previous() => handler.skipToPrevious();
  Future<void> seek(Duration d) => handler.seek(d);
  Future<void> seekRelative(int seconds) => handler.seek(player.position + Duration(seconds: seconds));
  Future<void> setSpeed(double s) async {
    await handler.setSpeed(s);
    notifyListeners();
  }

  Future<void> toggleShuffle() async {
    await handler.setShuffleMode(shuffle ? AudioServiceShuffleMode.none : AudioServiceShuffleMode.all);
    notifyListeners();
  }

  Future<void> cycleRepeat() async {
    const order = [AudioServiceRepeatMode.none, AudioServiceRepeatMode.all, AudioServiceRepeatMode.one];
    await handler.setRepeatMode(order[(order.indexOf(repeat) + 1) % order.length]);
    notifyListeners();
  }

  // --------------------------------------------------------------- likes

  bool isLiked(PlayableItem item) => item.extra['liked'] == true;

  Future<void> toggleLike(PlayableItem item) async {
    if (item.kind != MediaKind.track) return;
    final liked = !isLiked(item);
    item.extra['liked'] = liked;
    notifyListeners();
    try {
      liked ? await api.post('/api/tracks/${item.remoteId}/like/') : await api.delete('/api/tracks/${item.remoteId}/like/');
    } catch (_) {
      item.extra['liked'] = !liked;
      notifyListeners();
      rethrow;
    }
  }

  // ------------------------------------------------------ history & sync

  void _recordPlay(PlayableItem item, Duration listened, bool completed) {
    if (item.kind == MediaKind.episode) {
      _savePodcastProgress(item: item, completed: completed);
      return;
    }
    if (item.kind != MediaKind.track || item.remoteId == null) return;
    if (!completed && listened < const Duration(seconds: 30)) return; // skip ≠ play
    store
        .enqueue('/api/history/', {
          'track': item.remoteId,
          'seconds': listened.inSeconds,
          'played_at': DateTime.now().toUtc().toIso8601String(),
          'source': item.localPath != null ? 'offline' : 'library',
        })
        .then((_) => connectivity.online ? api.flushOutbox() : null);
  }

  void _savePodcastProgress({PlayableItem? item, bool completed = false}) {
    item ??= current;
    if (item == null || item.kind != MediaKind.episode || item.remoteId == null) return;
    final pos = completed ? (item.duration?.inSeconds ?? player.position.inSeconds) : player.position.inSeconds;
    if (pos <= 0) return;
    store
        .enqueue('/api/podcasts/episodes/${item.remoteId}/progress/', {'position': pos, 'completed': completed})
        .then((_) => connectivity.online ? api.flushOutbox() : null);
  }

  void _onCurrentChanged() {
    lyrics = const [];
    plainLyrics = '';
    notifyListeners();
  }

  Future<void> loadLyrics() async {
    final item = current;
    if (item == null || item.isLive || item.isPodcast || lyricsLoading) return;
    lyricsLoading = true;
    notifyListeners();
    try {
      final query = item.kind == MediaKind.track
          ? {'track': item.remoteId}
          : {'title': item.title, 'artist': item.subtitle, 'duration': item.duration?.inSeconds};
      final data = await api.get('/api/lyrics/', query: query) as Map;
      if (current?.key != item.key) return;
      lyrics = LyricLine.parseLrc(data['synced'] as String? ?? '');
      plainLyrics = data['plain'] as String? ?? '';
    } catch (_) {
      lyrics = const [];
      plainLyrics = '';
    } finally {
      lyricsLoading = false;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------- sleep timer

  Timer? _sleepTimer;
  DateTime? sleepAt;
  bool sleepAtEndOfTrack = false;
  StreamSubscription? _endOfTrackSub;

  void setSleepTimer(Duration? after, {bool endOfTrack = false}) {
    _sleepTimer?.cancel();
    _endOfTrackSub?.cancel();
    sleepAt = null;
    sleepAtEndOfTrack = endOfTrack;
    if (endOfTrack) {
      final key = current?.key;
      _endOfTrackSub = handler.mediaItem.listen((m) {
        if (m?.id != key) {
          handler.pause();
          sleepAtEndOfTrack = false;
          _endOfTrackSub?.cancel();
          notifyListeners();
        }
      });
    } else if (after != null) {
      sleepAt = DateTime.now().add(after);
      _sleepTimer = Timer(after, _fadeOutAndPause);
    }
    notifyListeners();
  }

  Future<void> _fadeOutAndPause() async {
    for (var v = 1.0; v > 0; v -= 0.05) {
      await player.setVolume(v);
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    await handler.pause();
    await player.setVolume(1);
    sleepAt = null;
    notifyListeners();
  }

  // ----------------------------------------------------------- equalizer

  AndroidEqualizer get equalizer => handler.equalizer;

  @override
  void dispose() {
    _progressTimer.cancel();
    _sleepTimer?.cancel();
    super.dispose();
  }
}
