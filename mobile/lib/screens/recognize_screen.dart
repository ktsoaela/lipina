import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/api_client.dart';
import '../app.dart';
import '../models/models.dart';
import '../services/player_controller.dart';
import '../widgets/common.dart';

/// Shazam-style song identification: records ~10 s from the mic and fingerprints it.
class RecognizeScreen extends StatefulWidget {
  const RecognizeScreen({super.key});

  @override
  State<RecognizeScreen> createState() => _RecognizeScreenState();
}

enum _Status { idle, listening, matching, done }

class _RecognizeScreenState extends State<RecognizeScreen> with SingleTickerProviderStateMixin {
  final _recorder = AudioRecorder();
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));
  _Status _status = _Status.idle;
  Map<String, dynamic>? _match;
  String? _message;
  double _level = 0;
  StreamSubscription<Amplitude>? _ampSub;
  static const _clip = Duration(seconds: 10);

  Future<void> _listen() async {
    if (!await _recorder.hasPermission()) {
      setState(() => _message = 'Microphone permission is needed to identify songs.');
      return;
    }
    final dir = await getTemporaryDirectory();
    final path = p.join(dir.path, 'lipina_clip.m4a');
    setState(() {
      _status = _Status.listening;
      _match = null;
      _message = null;
    });
    _pulse.repeat();
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc, sampleRate: 44100, numChannels: 1, bitRate: 128000),
        path: path);
    _ampSub = _recorder.onAmplitudeChanged(const Duration(milliseconds: 120)).listen((a) {
      if (mounted) setState(() => _level = ((a.current + 50) / 50).clamp(0.0, 1.0).toDouble());
    });
    await Future<void>.delayed(_clip);
    if (!mounted) return;
    final out = await _recorder.stop();
    await _ampSub?.cancel();
    _pulse.stop();
    if (out == null) {
      setState(() => _status = _Status.idle);
      return;
    }
    setState(() => _status = _Status.matching);
    try {
      final res = await context.read<ApiClient>().upload('/api/recognize/', out);
      final match = res['match'];
      setState(() {
        _status = _Status.done;
        _match = match == null ? null : Map<String, dynamic>.from(match as Map);
        _message = match == null ? (res['detail'] as String? ?? 'No match found') : null;
      });
    } catch (e) {
      setState(() {
        _status = _Status.done;
        _message = '$e';
      });
    } finally {
      final f = File(out);
      if (f.existsSync()) unawaited(f.delete());
    }
  }

  @override
  void dispose() {
    _ampSub?.cancel();
    _recorder.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final listening = _status == _Status.listening;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Identify a song'),
        actions: [
          IconButton(
            tooltip: 'History',
            icon: const Icon(Icons.history),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const _HistoryScreen())),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(24), children: [
        const SizedBox(height: 24),
        Center(
          child: GestureDetector(
            onTap: _status == _Status.listening || _status == _Status.matching ? null : _listen,
            child: AnimatedBuilder(
              animation: _pulse,
              builder: (_, child) => CustomPaint(
                painter: _RipplePainter(listening ? _pulse.value : 0, _level),
                child: child,
              ),
              child: Container(
                width: 180,
                height: 180,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(colors: [LipinaColors.accent, Color(0xFF0E8F6C)]),
                  boxShadow: [BoxShadow(color: Color(0x661ED6A0), blurRadius: 40)],
                ),
                child: _status == _Status.matching
                    ? const Padding(padding: EdgeInsets.all(64), child: CircularProgressIndicator(color: Colors.black))
                    : const Icon(Icons.graphic_eq_rounded, size: 88, color: Colors.black),
              ),
            ),
          ),
        ),
        const SizedBox(height: 32),
        Text(
          switch (_status) {
            _Status.idle => 'Tap to identify what\'s playing',
            _Status.listening => 'Listening…',
            _Status.matching => 'Finding a match…',
            _Status.done => _match == null ? 'Tap to try again' : 'Got it!',
          },
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_message!, textAlign: TextAlign.center, style: const TextStyle(color: LipinaColors.muted)),
          ),
        if (_match != null) _MatchCard(match: _match!),
      ]),
    );
  }
}

class _RipplePainter extends CustomPainter {
  _RipplePainter(this.t, this.level);
  final double t;
  final double level;

  @override
  void paint(Canvas canvas, Size size) {
    if (t == 0) return;
    final c = size.center(Offset.zero);
    for (var i = 0; i < 3; i++) {
      final phase = (t + i / 3) % 1;
      final r = size.width / 2 + phase * (60 + 40 * level);
      canvas.drawCircle(c, r, Paint()
        ..color = LipinaColors.accent.withValues(alpha: (1 - phase) * 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3);
    }
  }

  @override
  bool shouldRepaint(_RipplePainter old) => old.t != t || old.level != level;
}

class _MatchCard extends StatelessWidget {
  const _MatchCard({required this.match});
  final Map<String, dynamic> match;

  @override
  Widget build(BuildContext context) {
    final links = Map<String, dynamic>.from(match['links'] as Map? ?? {});
    final local = match['matched_track'];
    return Card(
      margin: const EdgeInsets.only(top: 24),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Cover(match['cover_url'] as String?, size: 200, radius: 12),
          const SizedBox(height: 16),
          Text('${match['title']}', textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
          Text('${match['artist']}', style: const TextStyle(fontSize: 16, color: LipinaColors.muted)),
          if ((match['album'] as String? ?? '').isNotEmpty)
            Text('${match['album']} · ${match['release_date'] ?? ''}', style: const TextStyle(color: LipinaColors.muted)),
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
            if (local != null)
              FilledButton.icon(
                icon: const Icon(Icons.play_arrow),
                label: const Text('Play from your library'),
                onPressed: () => context.read<PlayerController>().playTracks([Track(Map<String, dynamic>.from(local as Map))]),
              ),
            if (links['preview'] != null)
              OutlinedButton.icon(
                icon: const Icon(Icons.headphones),
                label: const Text('Preview'),
                onPressed: () => context.read<PlayerController>().playItems([
                  PlayableItem(
                    key: 'preview:${match['id']}',
                    kind: MediaKind.device,
                    title: '${match['title']}',
                    subtitle: '${match['artist']} · preview',
                    artUrl: match['cover_url'] as String?,
                    url: links['preview'] as String,
                  ),
                ]),
              ),
            for (final e in links.entries.where((e) => e.key != 'preview'))
              OutlinedButton(
                onPressed: () => launchUrl(Uri.parse('${e.value}'), mode: LaunchMode.externalApplication),
                child: Text(switch (e.key) {
                  'spotify' => 'Open in Spotify',
                  'apple_music' => 'Apple Music',
                  _ => 'More links',
                }),
              ),
          ]),
        ]),
      ),
    );
  }
}

class _HistoryScreen extends StatelessWidget {
  const _HistoryScreen();

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Identified songs')),
        body: AsyncView<List>(
          load: () async => await context.read<ApiClient>().get('/api/recognize/') as List,
          builder: (context, list, _) => list.isEmpty
              ? const EmptyState(icon: Icons.graphic_eq, title: 'Nothing identified yet')
              : ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final m = Map<String, dynamic>.from(list[i] as Map);
                    return ListTile(
                      leading: Cover(m['cover_url'] as String?, size: 48),
                      title: Text('${m['title']}'),
                      subtitle: Text('${m['artist']}'),
                      trailing: Text(
                        DateTime.tryParse('${m['created_at']}') == null
                            ? ''
                            : MaterialLocalizations.of(context).formatShortDate(DateTime.parse('${m['created_at']}').toLocal()),
                        style: const TextStyle(color: LipinaColors.muted, fontSize: 12),
                      ),
                      onTap: () => showModalBottomSheet(
                        context: context,
                        isScrollControlled: true,
                        builder: (_) => SingleChildScrollView(child: _MatchCard(match: m)),
                      ),
                    );
                  },
                ),
        ),
      );
}
