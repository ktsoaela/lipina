import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'player_controller.dart';

enum NoiseType { white, pink, brown, rain, ocean }

enum FocusPhase { idle, focus, shortBreak, longBreak }

/// Study & practice tools: synthesized ambient noise, sample-accurate metronome and
/// a Pomodoro focus timer that can pause/resume your music between phases.
/// Everything is generated on-device — no assets, works offline.
class ToolsService extends ChangeNotifier {
  ToolsService(this.music);

  final PlayerController music;
  static const _rate = 22050;

  // Side players don't grab audio focus, so they mix with music.
  final AudioPlayer _noise = AudioPlayer(handleAudioSessionActivation: false);
  final AudioPlayer _metro = AudioPlayer(handleAudioSessionActivation: false);

  NoiseType? noise;
  double noiseVolume = 0.5;
  int bpm = 100;
  int beatsPerBar = 4;
  bool metronomeOn = false;

  // ------------------------------------------------------------ WAV synth

  static Uint8List _wav(Int16List samples) {
    final data = samples.buffer.asUint8List();
    final header = ByteData(44);
    void str(int o, String s) {
      for (var i = 0; i < s.length; i++) {
        header.setUint8(o + i, s.codeUnitAt(i));
      }
    }

    str(0, 'RIFF');
    header.setUint32(4, 36 + data.length, Endian.little);
    str(8, 'WAVE');
    str(12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little); // PCM
    header.setUint16(22, 1, Endian.little); // mono
    header.setUint32(24, _rate, Endian.little);
    header.setUint32(28, _rate * 2, Endian.little);
    header.setUint16(32, 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    str(36, 'data');
    header.setUint32(40, data.length, Endian.little);
    return Uint8List.fromList([...header.buffer.asUint8List(), ...data]);
  }

  static Int16List _synthNoise(NoiseType type, {int seconds = 20}) {
    final n = _rate * seconds;
    final out = Int16List(n);
    final rnd = Random(42);
    double b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0, b6 = 0, brown = 0;
    for (var i = 0; i < n; i++) {
      final white = rnd.nextDouble() * 2 - 1;
      double v;
      switch (type) {
        case NoiseType.white:
          v = white * 0.35;
        case NoiseType.pink:
        case NoiseType.rain:
          // Paul Kellet's refined pink noise filter
          b0 = 0.99886 * b0 + white * 0.0555179;
          b1 = 0.99332 * b1 + white * 0.0750759;
          b2 = 0.96900 * b2 + white * 0.1538520;
          b3 = 0.86650 * b3 + white * 0.3104856;
          b4 = 0.55000 * b4 + white * 0.5329522;
          b5 = -0.7616 * b5 - white * 0.0168980;
          v = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362) * 0.08;
          b6 = white * 0.115926;
          if (type == NoiseType.rain && rnd.nextDouble() < 0.0009) v += (rnd.nextDouble() - 0.5) * 0.9; // droplets
        case NoiseType.brown:
        case NoiseType.ocean:
          brown = (brown + 0.02 * white) / 1.02;
          v = brown * 3.2;
          if (type == NoiseType.ocean) {
            final t = i / _rate;
            v *= 0.35 + 0.65 * pow(sin(pi * t / (seconds / 2)), 2); // two slow swells per loop
          }
      }
      // Fade loop edges to avoid clicks.
      final edge = min(i, n - i) / (_rate * 0.25);
      if (edge < 1) v *= edge;
      out[i] = (v.clamp(-1.0, 1.0) * 32767).round();
    }
    return out;
  }

  Future<String> _cacheWav(String name, Int16List Function() synth) async {
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, name));
    if (!file.existsSync()) await file.writeAsBytes(_wav(synth())); // <100 ms; cached after first run
    return file.path;
  }

  // ----------------------------------------------------------------- noise

  Future<void> setNoise(NoiseType? type) async {
    noise = type;
    notifyListeners();
    if (type == null) {
      await _noise.stop();
      return;
    }
    final path = await _cacheWav('noise_${type.name}.wav', () => _synthNoise(type));
    await _noise.setFilePath(path);
    await _noise.setLoopMode(LoopMode.one);
    await _noise.setVolume(noiseVolume);
    unawaited(_noise.play());
  }

  Future<void> setNoiseVolume(double v) async {
    noiseVolume = v;
    await _noise.setVolume(v);
    notifyListeners();
  }

  // ------------------------------------------------------------- metronome

  static Int16List _synthBar(int bpm, int beats) {
    final beatLen = (_rate * 60 / bpm).round();
    final out = Int16List(beatLen * beats);
    final clickLen = (_rate * 0.03).round();
    for (var b = 0; b < beats; b++) {
      final freq = b == 0 ? 1600.0 : 1000.0;
      for (var i = 0; i < clickLen; i++) {
        final env = exp(-i / (clickLen / 5));
        out[b * beatLen + i] = (sin(2 * pi * freq * i / _rate) * env * 0.8 * 32767).round();
      }
    }
    return out;
  }

  /// The whole bar is rendered into one looping buffer, so timing is sample-accurate.
  Future<void> setMetronome({bool? on, int? bpm, int? beats}) async {
    this.bpm = (bpm ?? this.bpm).clamp(30, 260);
    beatsPerBar = (beats ?? beatsPerBar).clamp(1, 12);
    metronomeOn = on ?? metronomeOn;
    notifyListeners();
    if (!metronomeOn) {
      await _metro.stop();
      return;
    }
    final b = this.bpm, n = beatsPerBar;
    final path = await _cacheWav('metro_${b}_$n.wav', () => _synthBar(b, n));
    await _metro.setFilePath(path);
    await _metro.setLoopMode(LoopMode.one);
    unawaited(_metro.play());
  }

  final List<DateTime> _taps = [];
  int? tapTempo() {
    final now = DateTime.now();
    if (_taps.isNotEmpty && now.difference(_taps.last) > const Duration(seconds: 2)) _taps.clear();
    _taps.add(now);
    if (_taps.length > 8) _taps.removeAt(0);
    if (_taps.length < 2) return null;
    final gaps = [for (var i = 1; i < _taps.length; i++) _taps[i].difference(_taps[i - 1]).inMilliseconds];
    final avg = gaps.reduce((a, b) => a + b) / gaps.length;
    return (60000 / avg).round();
  }

  // ----------------------------------------------------------- focus timer

  int focusMinutes = 25, shortBreakMinutes = 5, longBreakMinutes = 15;
  bool pauseMusicOnBreak = true;
  FocusPhase phase = FocusPhase.idle;
  int completedSessions = 0;
  Duration remaining = Duration.zero;
  Timer? _focusTimer;
  bool _focusPaused = false;
  bool get focusPaused => _focusPaused;

  void configureFocus({int? focus, int? shortBreak, int? longBreak, bool? pauseOnBreak}) {
    focusMinutes = focus ?? focusMinutes;
    shortBreakMinutes = shortBreak ?? shortBreakMinutes;
    longBreakMinutes = longBreak ?? longBreakMinutes;
    pauseMusicOnBreak = pauseOnBreak ?? pauseMusicOnBreak;
    notifyListeners();
  }

  void startFocus() {
    _enterPhase(FocusPhase.focus);
  }

  void _enterPhase(FocusPhase next) {
    phase = next;
    _focusPaused = false;
    remaining = Duration(minutes: switch (next) {
      FocusPhase.focus => focusMinutes,
      FocusPhase.shortBreak => shortBreakMinutes,
      FocusPhase.longBreak => longBreakMinutes,
      FocusPhase.idle => 0,
    });
    if (pauseMusicOnBreak) {
      if (next == FocusPhase.focus && music.current != null && !music.playing) music.toggle();
      if ((next == FocusPhase.shortBreak || next == FocusPhase.longBreak) && music.playing) music.toggle();
    }
    _focusTimer?.cancel();
    if (next != FocusPhase.idle) {
      _focusTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    }
    notifyListeners();
  }

  void _tick() {
    if (_focusPaused) return;
    remaining -= const Duration(seconds: 1);
    if (remaining <= Duration.zero) {
      _chime();
      if (phase == FocusPhase.focus) {
        completedSessions++;
        _enterPhase(completedSessions % 4 == 0 ? FocusPhase.longBreak : FocusPhase.shortBreak);
      } else {
        _enterPhase(FocusPhase.focus);
      }
      return;
    }
    notifyListeners();
  }

  void toggleFocusPause() {
    _focusPaused = !_focusPaused;
    notifyListeners();
  }

  void stopFocus() {
    _focusTimer?.cancel();
    phase = FocusPhase.idle;
    remaining = Duration.zero;
    notifyListeners();
  }

  Future<void> _chime() async {
    final path = await _cacheWav('chime.wav', () {
      final n = (_rate * 1.2).round();
      final out = Int16List(n);
      for (var i = 0; i < n; i++) {
        final t = i / _rate;
        final v = (sin(2 * pi * 880 * t) + 0.5 * sin(2 * pi * 1320 * t)) * exp(-3 * t) * 0.4;
        out[i] = (v * 32767).round();
      }
      return out;
    });
    final chime = AudioPlayer(handleAudioSessionActivation: false);
    try {
      await chime.setFilePath(path);
      unawaited(chime.play());
      await chime.processingStateStream
          .firstWhere((s) => s == ProcessingState.completed)
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // best effort
    } finally {
      await chime.dispose();
    }
  }

  @override
  void dispose() {
    _focusTimer?.cancel();
    _noise.dispose();
    _metro.dispose();
    super.dispose();
  }
}
