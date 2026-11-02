import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';

import '../app.dart';
import '../models/models.dart';
import '../services/player_controller.dart';
import '../services/tools_service.dart';
import '../widgets/common.dart';
import 'now_playing_screen.dart';

class ToolsScreen extends StatelessWidget {
  const ToolsScreen({super.key, this.initialTab = 0});
  final int initialTab;

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 4,
        initialIndex: initialTab,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Focus & tools'),
            bottom: const TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [
              Tab(icon: Icon(Icons.timer_outlined), text: 'Focus'),
              Tab(icon: Icon(Icons.waves_rounded), text: 'Sounds'),
              Tab(icon: Icon(Icons.av_timer_rounded), text: 'Metronome'),
              Tab(icon: Icon(Icons.equalizer_rounded), text: 'Equalizer'),
            ]),
          ),
          body: const TabBarView(children: [_FocusTab(), _SoundsTab(), _MetronomeTab(), _EqualizerTab()]),
        ),
      );
}

class _FocusTab extends StatelessWidget {
  const _FocusTab();

  @override
  Widget build(BuildContext context) {
    final tools = context.watch<ToolsService>();
    final player = context.watch<PlayerController>();
    final total = Duration(minutes: switch (tools.phase) {
      FocusPhase.focus => tools.focusMinutes,
      FocusPhase.shortBreak => tools.shortBreakMinutes,
      FocusPhase.longBreak => tools.longBreakMinutes,
      FocusPhase.idle => tools.focusMinutes,
    });
    final remaining = tools.phase == FocusPhase.idle ? total : tools.remaining;
    final progress = total.inSeconds == 0 ? 0.0 : 1 - remaining.inSeconds / total.inSeconds;
    final label = switch (tools.phase) {
      FocusPhase.idle => 'Ready to focus',
      FocusPhase.focus => 'Focus',
      FocusPhase.shortBreak => 'Short break',
      FocusPhase.longBreak => 'Long break',
    };
    return ListView(padding: const EdgeInsets.all(24), children: [
      Center(
        child: SizedBox(
          width: 240,
          height: 240,
          child: Stack(fit: StackFit.expand, children: [
            CircularProgressIndicator(
              value: progress,
              strokeWidth: 10,
              backgroundColor: Colors.white10,
              color: tools.phase == FocusPhase.focus || tools.phase == FocusPhase.idle ? LipinaColors.accent : LipinaColors.accent2,
            ),
            Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(formatDuration(remaining), style: const TextStyle(fontSize: 52, fontWeight: FontWeight.w200)),
                Text(label, style: const TextStyle(color: LipinaColors.muted)),
                Text('${tools.completedSessions} sessions today', style: const TextStyle(color: LipinaColors.muted, fontSize: 12)),
              ]),
            ),
          ]),
        ),
      ),
      const SizedBox(height: 24),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        if (tools.phase == FocusPhase.idle)
          FilledButton.icon(onPressed: tools.startFocus, icon: const Icon(Icons.play_arrow), label: const Text('Start focus'))
        else ...[
          FilledButton.tonalIcon(
            onPressed: tools.toggleFocusPause,
            icon: Icon(tools.focusPaused ? Icons.play_arrow : Icons.pause),
            label: Text(tools.focusPaused ? 'Resume' : 'Pause'),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(onPressed: tools.stopFocus, icon: const Icon(Icons.stop), label: const Text('End')),
        ],
      ]),
      const SizedBox(height: 24),
      _Stepper('Focus length', tools.focusMinutes, 5, 90, (v) => tools.configureFocus(focus: v)),
      _Stepper('Short break', tools.shortBreakMinutes, 1, 30, (v) => tools.configureFocus(shortBreak: v)),
      _Stepper('Long break (every 4)', tools.longBreakMinutes, 5, 60, (v) => tools.configureFocus(longBreak: v)),
      SwitchListTile(
        title: const Text('Pause music during breaks'),
        value: tools.pauseMusicOnBreak,
        onChanged: (v) => tools.configureFocus(pauseOnBreak: v),
      ),
      ListTile(
        leading: const Icon(Icons.bedtime_outlined),
        title: const Text('Sleep timer'),
        subtitle: Text(player.sleepAt != null
            ? 'Stops at ${TimeOfDay.fromDateTime(player.sleepAt!).format(context)}'
            : player.sleepAtEndOfTrack
                ? 'After this track'
                : 'Off'),
        onTap: () => showSleepTimer(context),
      ),
      const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text('Tip: pair a focus session with brown noise from the Sounds tab — it mixes with your music.',
            style: TextStyle(color: LipinaColors.muted)),
      ),
    ]);
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper(this.label, this.value, this.min, this.max, this.onChanged);
  final String label;
  final int value, min, max;
  final void Function(int) onChanged;

  @override
  Widget build(BuildContext context) => ListTile(
        title: Text(label),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(icon: const Icon(Icons.remove_circle_outline), onPressed: value > min ? () => onChanged(value - 1) : null),
          SizedBox(width: 56, child: Text('$value min', textAlign: TextAlign.center)),
          IconButton(icon: const Icon(Icons.add_circle_outline), onPressed: value < max ? () => onChanged(value + 1) : null),
        ]),
      );
}

class _SoundsTab extends StatelessWidget {
  const _SoundsTab();

  static const _sounds = {
    NoiseType.brown: (Icons.blur_on, 'Brown noise', 'Deep & warm — great for focus'),
    NoiseType.pink: (Icons.grain, 'Pink noise', 'Balanced, softer than white'),
    NoiseType.white: (Icons.blur_circular, 'White noise', 'Masks chatter and traffic'),
    NoiseType.rain: (Icons.water_drop_outlined, 'Rain', 'Steady rainfall'),
    NoiseType.ocean: (Icons.waves, 'Ocean', 'Slow rolling swells'),
  };

  @override
  Widget build(BuildContext context) {
    final tools = context.watch<ToolsService>();
    return ListView(padding: const EdgeInsets.all(16), children: [
      const Text('Ambient sounds play alongside your music or radio and work offline.',
          style: TextStyle(color: LipinaColors.muted)),
      const SizedBox(height: 12),
      GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1.3,
        children: [
          for (final e in _sounds.entries)
            Material(
              color: tools.noise == e.key ? LipinaColors.accent.withValues(alpha: 0.2) : LipinaColors.surfaceHi,
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => tools.setNoise(tools.noise == e.key ? null : e.key),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(e.value.$1, size: 32, color: tools.noise == e.key ? LipinaColors.accent : null),
                    const Spacer(),
                    Text(e.value.$2, style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text(e.value.$3, style: const TextStyle(color: LipinaColors.muted, fontSize: 12)),
                  ]),
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 16),
      Row(children: [
        const Icon(Icons.volume_down),
        Expanded(child: Slider(value: tools.noiseVolume, onChanged: tools.setNoiseVolume)),
        const Icon(Icons.volume_up),
      ]),
    ]);
  }
}

class _MetronomeTab extends StatelessWidget {
  const _MetronomeTab();

  @override
  Widget build(BuildContext context) {
    final tools = context.watch<ToolsService>();
    return ListView(padding: const EdgeInsets.all(24), children: [
      Center(child: Text('${tools.bpm}', style: const TextStyle(fontSize: 96, fontWeight: FontWeight.w200))),
      const Center(child: Text('BPM', style: TextStyle(color: LipinaColors.muted, letterSpacing: 4))),
      Slider(
        value: tools.bpm.toDouble(),
        min: 30,
        max: 260,
        divisions: 230,
        label: '${tools.bpm}',
        onChanged: (v) => tools.setMetronome(bpm: v.round()),
      ),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        IconButton(icon: const Icon(Icons.remove), onPressed: () => tools.setMetronome(bpm: tools.bpm - 1)),
        const SizedBox(width: 12),
        FilledButton.icon(
          onPressed: () => tools.setMetronome(on: !tools.metronomeOn),
          icon: Icon(tools.metronomeOn ? Icons.stop : Icons.play_arrow),
          label: Text(tools.metronomeOn ? 'Stop' : 'Start'),
        ),
        const SizedBox(width: 12),
        IconButton(icon: const Icon(Icons.add), onPressed: () => tools.setMetronome(bpm: tools.bpm + 1)),
      ]),
      const SizedBox(height: 24),
      const Text('Beats per bar', textAlign: TextAlign.center),
      const SizedBox(height: 8),
      Wrap(alignment: WrapAlignment.center, spacing: 8, children: [
        for (final b in const [2, 3, 4, 5, 6, 7])
          ChoiceChip(label: Text('$b'), selected: tools.beatsPerBar == b, onSelected: (_) => tools.setMetronome(beats: b)),
      ]),
      const SizedBox(height: 32),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(padding: const EdgeInsets.all(20)),
        icon: const Icon(Icons.touch_app),
        label: const Text('Tap tempo'),
        onPressed: () {
          final bpm = tools.tapTempo();
          if (bpm != null) tools.setMetronome(bpm: bpm);
        },
      ),
      const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text('Tap along to any song to find its BPM.', textAlign: TextAlign.center, style: TextStyle(color: LipinaColors.muted)),
      ),
    ]);
  }
}

class _EqualizerTab extends StatefulWidget {
  const _EqualizerTab();

  @override
  State<_EqualizerTab> createState() => _EqualizerTabState();
}

class _EqualizerTabState extends State<_EqualizerTab> {
  static const _presets = {
    'Flat': [0.0, 0.0, 0.0, 0.0, 0.0],
    'Bass boost': [6.0, 4.0, 0.0, 0.0, 0.0],
    'Amapiano': [7.0, 3.0, -1.0, 1.0, 3.0],
    'Vocal': [-2.0, 0.0, 3.0, 4.0, 1.0],
    'Treble': [0.0, 0.0, 0.0, 3.0, 6.0],
    'Podcast': [-4.0, 0.0, 4.0, 3.0, -1.0],
  };

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) {
      return const EmptyState(
        icon: Icons.equalizer,
        title: 'Equalizer is available on Android',
        message: 'On iPhone, use Settings → Music → EQ for system-wide presets.',
      );
    }
    final eq = context.read<PlayerController>().equalizer;
    return StreamBuilder<bool>(
      stream: eq.enabledStream,
      builder: (context, enabledSnap) {
        final enabled = enabledSnap.data ?? false;
        return FutureBuilder<AndroidEqualizerParameters>(
          future: eq.parameters,
          builder: (context, snap) {
            if (!snap.hasData) {
              return const EmptyState(icon: Icons.equalizer, title: 'Start playing something to use the equalizer');
            }
            final params = snap.data!;
            return ListView(padding: const EdgeInsets.all(16), children: [
              SwitchListTile(title: const Text('Equalizer'), value: enabled, onChanged: eq.setEnabled),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final e in _presets.entries)
                  ActionChip(
                    label: Text(e.key),
                    onPressed: () async {
                      await eq.setEnabled(true);
                      for (var i = 0; i < params.bands.length; i++) {
                        final g = e.value[(i * e.value.length / params.bands.length).floor()];
                        await params.bands[i].setGain(g.clamp(params.minDecibels, params.maxDecibels).toDouble());
                      }
                    },
                  ),
              ]),
              const SizedBox(height: 16),
              SizedBox(
                height: 260,
                child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                  for (final band in params.bands)
                    StreamBuilder<double>(
                      stream: band.gainStream,
                      builder: (_, g) => Column(children: [
                        Text('${(g.data ?? band.gain).toStringAsFixed(0)} dB', style: const TextStyle(fontSize: 11)),
                        Expanded(
                          child: RotatedBox(
                            quarterTurns: 3,
                            child: Slider(
                              min: params.minDecibels,
                              max: params.maxDecibels,
                              value: (g.data ?? band.gain).clamp(params.minDecibels, params.maxDecibels).toDouble(),
                              onChanged: enabled ? band.setGain : null,
                            ),
                          ),
                        ),
                        Text(band.centerFrequency >= 1000
                            ? '${(band.centerFrequency / 1000).toStringAsFixed(1)}k'
                            : band.centerFrequency.toStringAsFixed(0),
                            style: const TextStyle(fontSize: 11, color: LipinaColors.muted)),
                      ]),
                    ),
                ]),
              ),
            ]);
          },
        );
      },
    );
  }
}
