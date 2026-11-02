import 'package:flutter_test/flutter_test.dart';
import 'package:lipina/models/models.dart';

void main() {
  test('parses LRC with multiple timestamps per line', () {
    final lines = LyricLine.parseLrc('[00:12.50]Hello\n[ar:Someone]\n[00:05.00][00:20.00]Chorus\n');
    expect(lines.map((l) => l.text), ['Chorus', 'Hello', 'Chorus']);
    expect(lines.first.time, const Duration(seconds: 5));
    expect(lines[1].time, const Duration(milliseconds: 12500));
  });

  test('formats durations', () {
    expect(formatDuration(const Duration(seconds: 65)), '1:05');
    expect(formatDuration(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
    expect(formatDuration(null), '--:--');
  });

  test('PlayableItem round-trips through JSON (offline downloads index)', () {
    final track = Track({
      'id': 7,
      'title': 'Jerusalema',
      'artist': {'id': 1, 'name': 'Master KG'},
      'album': {'id': 2, 'title': 'Jerusalema'},
      'duration': 342.5,
      'stream_url': 'https://x/api/tracks/7/stream/?t=abc',
      'download_url': 'https://x/api/tracks/7/stream/?t=abc&download=1',
      'liked': true,
    });
    final item = PlayableItem.fromTrack(track)..localPath = '/data/downloads/track_7.mp3';
    final back = PlayableItem.fromJson(item.toJson());
    expect(back.key, 'track:7');
    expect(back.subtitle, 'Master KG');
    expect(back.duration, const Duration(milliseconds: 342500));
    expect(back.localPath, '/data/downloads/track_7.mp3');
    expect(back.extra['liked'], true);
  });
}
