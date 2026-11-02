# Lipina — music, South African radio, podcasts & focus

Lipina is a music app that works offline. You can stream your own library, tune into live South African radio, follow podcasts, identify songs Shazam-style, and use study tools. There's a web app (an installable PWA) and a Flutter app for Android and iOS. Both use the same Django API.

```
backend/   Django 5 + DRF API, web app (PWA) and admin
mobile/    Flutter app (Android/iOS), see mobile/README.md
deploy/    nginx config
docker-compose.yml   nginx · gunicorn · Postgres · Redis · scheduler
```

## Features

| | Web | Mobile |
|---|---|---|
| **Library**: upload (tags and cover art read automatically), songs, albums, artists, Liked Songs | ✓ | ✓ |
| **Playlists**: create, rename, reorder, public/private, add from anywhere | ✓ | ✓ |
| **Player**: queue, play next, shuffle, repeat, track radio, speed, media keys and lock screen | ✓ | ✓ (background) |
| **South African Radio**: about 230 live South African stations, filter by province or genre, favourites, now-playing title | ✓ | ✓ |
| **Streaming services**: connect Spotify (Premium), Apple Music or YouTube Music and play them through Lipina's player and queue; free iTunes previews with no setup | ✓ | |
| **Podcasts**: SA top chart, directory search, follow, new-episodes inbox, resume points synced across devices | ✓ | ✓ |
| **Identify a song**: 10 s mic clip → AudD fingerprint match → links, preview, or your own copy | ✓ | ✓ |
| **Lyrics**: time-synced karaoke lyrics (tap a line to seek) | ✓ | ✓ |
| **Offline-first**: download tracks, playlists and episodes; play local files; cached pages; history and progress queued and synced later | ✓ (IndexedDB + service worker) | ✓ (Hive + files) |
| **Focus & tools**: Pomodoro timer that pauses music on breaks, ambient noise (brown/pink/white/rain/ocean), sleep timer with fade-out, metronome and tap tempo | ✓ | ✓ |
| **Equalizer**: 5-band EQ with presets (including Amapiano) | ✓ | ✓ (Android) |
| **Tuner** (chromatic, mic), visualizer, keyboard shortcuts | ✓ | |

External services (all have free tiers):
- [radio-browser.info](https://www.radio-browser.info): radio directory, no key needed.
- [LRCLIB](https://lrclib.net): lyrics, no key needed.
- Apple Podcasts directory: podcast search, no key needed.
- [AudD](https://audd.io): song recognition. Needs `AUDD_API_TOKEN`.
- Streaming (optional, see `.env.example`): Spotify needs `SPOTIFY_CLIENT_ID`, YouTube Music needs `YOUTUBE_API_KEY`, Apple Music needs a MusicKit key (`APPLE_MUSIC_TEAM_ID`, `APPLE_MUSIC_KEY_ID`, `APPLE_MUSIC_PRIVATE_KEY_FILE`). iTunes previews need nothing.
- SABC stations missing from radio-browser (Radio 2000, SAfm, Ikwekwezi, Ligwalagwala, Motsweding, X-K FM, Tru FM) are built in.

## Run locally

```bash
cd backend
python -m venv .venv && .venv/Scripts/activate      # macOS/Linux: source .venv/bin/activate
pip install -r requirements.txt
set DEBUG=1                                         # macOS/Linux: export DEBUG=1
python manage.py migrate
python manage.py createsuperuser
python manage.py sync_radio                         # optional; also runs on first radio visit
python manage.py runserver
```
Open http://127.0.0.1:8000 for the web app or http://127.0.0.1:8000/admin for the admin. Staff can publish tracks to the shared catalog from the admin or the upload page.

Mobile: see [mobile/README.md](mobile/README.md). On the Android emulator, `http://10.0.2.2:8000` points at your local backend.

## Deploy (Docker)

```bash
cp backend/.env.example backend/.env      # set SECRET_KEY, ALLOWED_HOSTS, CSRF_TRUSTED_ORIGINS, AUDD_API_TOKEN …
docker compose up -d --build
```
- **nginx** serves cover art directly. Audio goes through `X-Accel-Redirect` after Django checks a short-lived signed URL, so Python workers never stream bytes and seeking with Range requests works.
- **scheduler** refreshes podcast feeds hourly and radio stations daily.
- Put TLS in front with Caddy, Cloudflare or certbot. The app trusts `X-Forwarded-Proto`.
- Back up the `pgdata` and `media` volumes.

## API overview
All under `/api/`, authenticated with a JWT (`Authorization: Bearer …`).

- `auth/register/` · `auth/token/` · `auth/token/refresh/` · `auth/me/` · `auth/password/`
- `tracks/` (multipart upload, `?scope=mine|catalog`, `?search=`, `?ordering=`) · `tracks/{id}/stream/?t=` · `tracks/{id}/like/` · `tracks/liked/` · `tracks/{id}/radio/` · `tracks/genres/`
- `albums/` · `artists/` (with `/tracks/`) · `playlists/` (+ `/tracks/`, `/tracks/{id}/`, `/reorder/`)
- `home/` · `search/?q=` · `history/` (POST one or a batch, idempotent via `client_id`) · `library/snapshot/`
- `radio/stations/` (`?q= ?state= ?tag= ?favorites=1 ?https=1`) · `/facets/` · `/{id}/now-playing/` · `/{id}/favorite/`
- `podcasts/directory/top/` · `podcasts/directory/search/?q=` · `podcasts/shows/` (POST `{itunes_id}` or `{feed_url}` imports a show) · `/episodes/` · `/subscribe/` · `shows/subscriptions/` · `shows/feed/` · `episodes/{id}/progress/` · `episodes/in-progress/`
- `connect/` (which streaming services are set up) · `connect/itunes/search/?q=` · `connect/youtube/search/?q=` · `connect/apple-music/token/`
- `recognize/` (POST multipart `file`) · `lyrics/?track=` or `?title=&artist=`

## Tests
```bash
cd backend && DEBUG=1 python manage.py test   # API, streaming/ranges, permissions, offline replay, radio/podcast ingest, SSRF guard
cd mobile && flutter test
```
CI (`.github/workflows/ci.yml`) runs the backend against Postgres, deploy checks, a web syntax check, `flutter analyze` and `flutter test`, and a Docker build.

## Security notes
- Audio URLs are signed and expire (`STREAM_URL_MAX_AGE`). Private tracks are only visible to their owner.
- Every outbound fetch of a user-supplied or directory URL (podcast feeds, radio ICY metadata) is checked against private, loopback and link-local addresses, including on each redirect.
- Rate limits are tighter on login/register (10/min) and recognition (20/hour, since AudD calls cost money).
- Uploads are limited by extension and size, and deduplicated per user by SHA-256.
