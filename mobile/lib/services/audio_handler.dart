import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/models.dart';

/// Background audio engine. Owns the queue and the just_audio player and exposes
/// lock-screen / notification / Bluetooth / Android Auto controls via audio_service.
class LipinaAudioHandler extends BaseAudioHandler with SeekHandler {
  LipinaAudioHandler() {
    _player.playbackEventStream.listen((_) => _broadcast(), onError: (Object e, StackTrace st) {
      error.value = 'Playback error: $e';
      _broadcast();
    });
    _player.playingStream.listen((_) => _broadcast());
    _player.processingStateStream.listen((s) {
      if (s == ProcessingState.completed) _onCompleted();
    });
    _player.icyMetadataStream.listen((meta) {
      final title = meta?.info?.title?.trim();
      final item = current.value;
      if (item == null || !item.isLive) return;
      liveTitle.value = (title == null || title.isEmpty) ? null : title;
      mediaItem.add(_toMediaItem(item).copyWith(title: liveTitle.value ?? item.title, artist: item.title));
    });
  }

  final AndroidEqualizer equalizer = AndroidEqualizer();
  late final AudioPlayer _player = AudioPlayer(
    audioPipeline: AudioPipeline(androidAudioEffects: Platform.isAndroid ? [equalizer] : const []),
  );
  AudioPlayer get player => _player;

  final ValueNotifier<PlayableItem?> current = ValueNotifier(null);
  final ValueNotifier<List<PlayableItem>> upNext = ValueNotifier(const []);
  final ValueNotifier<String?> liveTitle = ValueNotifier(null);
  final ValueNotifier<String?> error = ValueNotifier(null);

  /// Called with (item, listenedFor, completed) whenever an item stops being current.
  void Function(PlayableItem item, Duration listened, bool completed)? onItemFinished;

  List<PlayableItem> _items = [];
  List<int> _order = [];
  int _pos = -1;
  bool _shuffle = false;
  AudioServiceRepeatMode _repeat = AudioServiceRepeatMode.none;
  DateTime? _startedAt;
  Duration _listened = Duration.zero;

  bool get shuffleEnabled => _shuffle;
  AudioServiceRepeatMode get repeatMode => _repeat;
  List<PlayableItem> get items => List.unmodifiable(_items);
  int get currentIndex => _pos < 0 || _pos >= _order.length ? -1 : _order[_pos];

  // ---------------------------------------------------------------- queue

  Future<void> setQueueItems(List<PlayableItem> items, {int start = 0, bool autoplay = true}) async {
    _finishCurrent(completed: false);
    _items = List.of(items);
    _order = List.generate(_items.length, (i) => i);
    if (_shuffle) _reshuffle(start);
    _pos = _shuffle ? 0 : start.clamp(0, max(0, _items.length - 1));
    _publishQueue();
    if (_items.isNotEmpty) await _load(autoplay: autoplay);
  }

  void playNext(PlayableItem item) {
    if (_items.isEmpty) {
      setQueueItems([item]);
      return;
    }
    _items.add(item);
    _order.insert(_pos + 1, _items.length - 1);
    _publishQueue();
  }

  void addToQueue(PlayableItem item) {
    if (_items.isEmpty) {
      setQueueItems([item]);
      return;
    }
    _items.add(item);
    _order.add(_items.length - 1);
    _publishQueue();
  }

  void removeUpcoming(int upNextIndex) {
    final orderIdx = _pos + 1 + upNextIndex;
    if (orderIdx < _order.length) {
      _order.removeAt(orderIdx);
      _publishQueue();
    }
  }

  /// Replace an item's local path once it finishes downloading.
  void updateLocalPath(String key, String? path) {
    for (final it in _items) {
      if (it.key == key) it.localPath = path;
    }
  }

  void _reshuffle(int keepFirst) {
    final rest = List.generate(_items.length, (i) => i)..remove(keepFirst);
    rest.shuffle();
    _order = [if (_items.isNotEmpty) keepFirst, ...rest];
  }

  void _publishQueue() {
    upNext.value = [for (final i in _order.skip(_pos + 1)) _items[i]];
    queue.add([for (final i in _order) _toMediaItem(_items[i])]);
  }

  MediaItem _toMediaItem(PlayableItem item) => MediaItem(
        id: item.key,
        title: item.title,
        artist: item.subtitle,
        album: item.album.isEmpty ? null : item.album,
        duration: item.isLive ? null : item.duration,
        artUri: item.artUrl == null ? null : Uri.tryParse(item.artUrl!),
        isLive: item.isLive,
        extras: {'kind': item.kind.name},
      );

  Future<void> _load({bool autoplay = true}) async {
    final item = _items[_order[_pos]];
    current.value = item;
    liveTitle.value = null;
    error.value = null;
    mediaItem.add(_toMediaItem(item));
    _publishQueue();
    final local = item.localPath;
    final source = (local != null && File(local).existsSync())
        ? AudioSource.file(local, tag: item.key)
        : AudioSource.uri(Uri.parse(item.url), tag: item.key);
    try {
      await _player.setAudioSource(source, initialPosition: item.startPosition);
      _startedAt = null;
      _listened = Duration.zero;
      if (autoplay) unawaited(_player.play());
    } on PlayerException catch (e) {
      error.value = 'Can\'t play "${item.title}" (${e.message ?? 'source error'})';
      if (!item.isLive && _pos < _order.length - 1) {
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await skipToNext();
      }
    } on PlayerInterruptedException {
      // a newer load replaced this one
    }
  }

  void _finishCurrent({required bool completed}) {
    final item = current.value;
    if (item == null) return;
    _accumulateListening();
    onItemFinished?.call(item, _listened, completed);
    _listened = Duration.zero;
  }

  void _accumulateListening() {
    if (_startedAt != null) {
      _listened += DateTime.now().difference(_startedAt!);
      _startedAt = _player.playing ? DateTime.now() : null;
    }
  }

  Future<void> _onCompleted() async {
    _finishCurrent(completed: true);
    if (_repeat == AudioServiceRepeatMode.one) {
      await _player.seek(Duration.zero);
      unawaited(_player.play());
    } else if (_pos < _order.length - 1) {
      _pos++;
      await _load();
    } else if (_repeat == AudioServiceRepeatMode.all && _order.isNotEmpty) {
      _pos = 0;
      await _load();
    } else {
      await _player.pause();
      await _player.seek(Duration.zero);
    }
  }

  // ---------------------------------------------------------- transport

  @override
  Future<void> play() async {
    if (current.value == null) return;
    unawaited(_player.play());
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    _finishCurrent(completed: false);
    await _player.stop();
    current.value = null;
    mediaItem.add(null);
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() async {
    if (_pos < _order.length - 1) {
      _finishCurrent(completed: false);
      _pos++;
      await _load();
    } else if (_repeat == AudioServiceRepeatMode.all && _order.isNotEmpty) {
      _finishCurrent(completed: false);
      _pos = 0;
      await _load();
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (_player.position > const Duration(seconds: 3) || _pos <= 0) {
      await _player.seek(Duration.zero);
      return;
    }
    _finishCurrent(completed: false);
    _pos--;
    await _load();
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= _order.length) return;
    _finishCurrent(completed: false);
    _pos = index;
    await _load();
  }

  /// Jump to an item in the "up next" list.
  Future<void> jumpToUpNext(int upNextIndex) => skipToQueueItem(_pos + 1 + upNextIndex);

  @override
  Future<void> fastForward() => _player.seek(_player.position + const Duration(seconds: 30));

  @override
  Future<void> rewind() => _player.seek(_player.position - const Duration(seconds: 15));

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    _repeat = repeatMode;
    _broadcast();
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    _shuffle = shuffleMode != AudioServiceShuffleMode.none;
    if (_items.isEmpty) {
      _broadcast();
      return;
    }
    final cur = currentIndex;
    if (_shuffle) {
      _reshuffle(cur);
      _pos = 0;
    } else {
      _order = List.generate(_items.length, (i) => i);
      _pos = cur;
    }
    _publishQueue();
    _broadcast();
  }

  Future<void> setVolume(double v) => _player.setVolume(v);

  // -------------------------------------------------------- state fan-out

  void _broadcast() {
    final playing = _player.playing;
    if (playing && _startedAt == null) _startedAt = DateTime.now();
    if (!playing) _accumulateListening();
    final live = current.value?.isLive ?? false;
    playbackState.add(playbackState.value.copyWith(
      controls: [
        if (!live) MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        if (live) MediaControl.stop else MediaControl.skipToNext,
      ],
      systemActions: live
          ? const {}
          : const {MediaAction.seek, MediaAction.seekForward, MediaAction.seekBackward},
      androidCompactActionIndices: live ? const [0, 1] : const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState]!,
      playing: playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: _pos < 0 ? null : _pos,
      repeatMode: _repeat,
      shuffleMode: _shuffle ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
    ));
  }
}
