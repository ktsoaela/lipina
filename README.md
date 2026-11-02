<div align="center">
  <img src="backend/web/static/web/icons/icon.svg" alt="Lipina" width="128" />

  <h1>Lipina</h1>

  <p><strong>Your music, South African radio, podcasts, and focus tools. Offline when you want it.</strong></p>

  <p>
    <img alt="Stack" src="https://img.shields.io/badge/Django_5-Flutter-0e8f6c?style=flat-square" />
  </p>
</div>

**Author:** [Khotso Tsoaela](https://github.com/ktsoaela) (`@ktsoaela`)

---

A listening app for music you already have, live South African radio, and podcasts. The same Django API serves the website and the Android app.

**Lipina** keeps your library and playlists on the device, so playback still works with no network. Song recognition, radio, and podcast search need the server.

---

## What it does

- Plays your own files, with albums, artists, playlists, and liked songs
- Tunes live South African radio, filtered by province or genre
- Follows podcasts, with resume points and episodes saved for offline
- Identifies a song from a short microphone clip
- Shows time-synced lyrics
- Focus tools: Pomodoro, sleep timer, ambient noise, metronome, and an equalizer

---

## Quick start

**Requirements:** Python 3.11+, and Flutter 3.27+ if you are building the Android app.

```bash
cd backend
python -m venv .venv
.venv\Scripts\activate          # macOS/Linux: source .venv/bin/activate
pip install -r requirements.txt
copy .env.example .env          # macOS/Linux: cp .env.example .env
```

Set `DEBUG=1` in `.env` for local work, then:

```bash
python manage.py migrate
python manage.py createsuperuser
python manage.py runserver
```

Open http://127.0.0.1:8000 for the site, or http://127.0.0.1:8000/admin for admin. `python manage.py sync_radio` fills the station list; the first visit to radio does this too.

Put secrets only in `backend/.env`. That file and `backend/db.sqlite3` stay on the machine. They are not part of the app build.

| Goal | Command |
|------|---------|
| Website | `python manage.py runserver` → http://127.0.0.1:8000 |
| Phone on the same Wi-Fi | `python manage.py runserver 0.0.0.0:8000` |
| Android emulator | point the app at `http://10.0.2.2:8000` |

### Production checklist

1. Set `DEBUG=0` and a long random `SECRET_KEY`
2. Set `ALLOWED_HOSTS` and `CSRF_TRUSTED_ORIGINS` to the real host
3. Use Postgres via `DATABASE_URL` (see Docker below)
4. Leave `DJANGO_SUPERUSER_PASSWORD` empty in any file that is committed
5. Terminate TLS at the reverse proxy

---

## Android

The installable app is an APK, built from `mobile/`. The server address is chosen on the login screen. The username and password are typed there. They are not compiled into the APK, and neither is the database.

```bash
cd mobile
flutter pub get
flutter build apk --release --dart-define=LIPINA_API=https://your-server.example
```

The file is written to `mobile/build/app/outputs/flutter-apk/app-release.apk`. Copy it to the phone and open it. The phone and the computer must be on the same network when the server is still on your machine. Change the server URL on the login screen if the address changes.

iOS notes are in [mobile/README.md](mobile/README.md).

---

## Features

| | Web | Android |
|---|---|---|
| Library: upload, tags, cover art, albums, artists, liked songs | ✓ | ✓ |
| Playlists: create, rename, reorder, public or private | ✓ | ✓ |
| Player: queue, shuffle, repeat, speed, media keys | ✓ | ✓ (background) |
| South African radio, favourites, now-playing title | ✓ | ✓ |
| Podcasts: charts, search, follow, resume, offline episodes | ✓ | ✓ |
| Identify a song (10 s clip) | ✓ | ✓ |
| Time-synced lyrics | ✓ | ✓ |
| Offline library and downloads | ✓ | ✓ |
| Focus tools and equalizer | ✓ | ✓ (equalizer on Android) |
| Spotify, Apple Music, YouTube Music, iTunes previews | ✓ | |

Optional keys live in `.env` and are documented in [backend/.env.example](backend/.env.example):

- Radio directory and lyrics need no key
- Song recognition needs `AUDD_API_TOKEN`
- Spotify, YouTube Music, and Apple Music need their own keys. iTunes previews need nothing

---

## Stack

| Layer | Technology |
|--------|------------|
| API and website | Django 5, Django REST framework, SQLite or Postgres |
| Android | Flutter |
| Playback on the phone | just_audio, audio_service |
| Deploy | Docker Compose, Gunicorn, nginx, Redis |

---

## Docker

```bash
cp backend/.env.example backend/.env
docker compose up -d --build
```

Compose overrides the database, cache, and media path so they point at the `db` and `redis` services. nginx serves cover art. Audio is handed to nginx with `X-Accel-Redirect` after Django checks a short-lived signed URL. A scheduler refreshes podcast feeds hourly and radio stations daily.

Back up the `pgdata` and `media` volumes. Put TLS in front with Caddy, Cloudflare, or certbot.

---

## API

Everything is under `/api/`, with a JWT in `Authorization: Bearer …`.

- `auth/register/` · `auth/token/` · `auth/token/refresh/` · `auth/me/` · `auth/password/`
- `tracks/` · `albums/` · `artists/` · `playlists/`
- `home/` · `search/?q=` · `history/` · `library/snapshot/`
- `radio/stations/` · `podcasts/`
- `recognize/` · `lyrics/`

---

## Tests

```bash
cd backend && python manage.py test
cd mobile && flutter test
```

---

## Security

- Audio URLs are signed and expire. Private tracks are visible only to their owner.
- Fetches of podcast feeds and radio metadata refuse private, loopback, and link-local addresses, including after a redirect.
- Login and registration are limited to 10 requests a minute. Recognition is limited to 20 an hour.
- Uploads are limited by extension and size, and repeated files are stored once per user.
