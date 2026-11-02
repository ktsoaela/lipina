# Lipina mobile (Flutter)

The Android and iOS app for Lipina. It talks to the Django API in `../backend`.

## Features
- **Your library**: songs, albums, artists, playlists (create, rename, reorder, swipe to remove) and Liked Songs.
- **Background playback**: notification, lock-screen and Bluetooth controls through `audio_service`, with a queue, shuffle, repeat, "play next" and track radio.
- **South African Radio**: about 230 live South African stations from radio-browser.info. Filter by province or genre, keep favourites, and see the song currently playing on the station (ICY metadata).
- **Podcasts**: the top charts for South Africa, search across the whole directory, follow shows, a new-episodes inbox, resume points synced to the server, and 0.75–2× speed.
- **Identify a song (Shazam-style)**: records 10 s from the mic, matches it with AudD, and links to your own copy if you have it.
- **Lyrics**: time-synced karaoke-style lyrics from LRCLIB (tap a line to seek there).
- **Offline-first**:
  - Download songs, playlists and episodes.
  - Import music files from the phone.
  - Browse pages from cache while offline.
  - Play history and podcast progress are queued and synced once you reconnect.
- **Focus & tools**:
  - Pomodoro timer that pauses your music during breaks.
  - Ambient sounds (brown, pink and white noise, rain, ocean) synthesized on the device, mixed with your music.
  - Metronome with tap tempo, timed to the sample.
  - 5-band equalizer with presets (Android).
  - Sleep timer with fade-out.

## Setup

```bash
cd mobile
flutter create --org za.lipina --project-name lipina --platforms android,ios .   # generates the missing platform files; existing files are kept
flutter pub get
flutter test
flutter run --dart-define=LIPINA_API=http://10.0.2.2:8000     # Android emulator → your local backend
```

`flutter create` won't overwrite the `AndroidManifest.xml` and `MainActivity.kt` that are already committed. They hold the background audio service, microphone and cleartext-radio configuration.

### iOS: add to `ios/Runner/Info.plist`
```xml
<key>UIBackgroundModes</key><array><string>audio</string></array>
<key>NSMicrophoneUsageDescription</key><string>Lipina listens briefly to identify the song that's playing.</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoadsForMedia</key><true/></dict>
```

### Release builds
```bash
flutter build appbundle --release --dart-define=LIPINA_API=https://music.example.com
flutter build ipa --release --dart-define=LIPINA_API=https://music.example.com
```
Users can also change the server URL on the login screen under "Server settings".
