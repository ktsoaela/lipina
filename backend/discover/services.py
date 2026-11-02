"""Song recognition (audio fingerprinting via AudD) and lyrics (LRCLIB, incl. time-synced LRC)."""
import hashlib
import logging

import requests
from django.conf import settings
from django.core.cache import cache

from config.net import default_headers

log = logging.getLogger(__name__)


class RecognitionUnavailable(Exception):
    pass


def recognize_clip(fileobj, filename="clip.webm"):
    """Return a normalized match dict, or None when nothing matched.

    AudD fingerprints the clip against a catalog of tens of millions of songs.
    Get a token at https://dashboard.audd.io and set AUDD_API_TOKEN.
    """
    token = settings.AUDD_API_TOKEN
    if not token:
        raise RecognitionUnavailable("Song recognition is not configured on this server (AUDD_API_TOKEN).")
    try:
        resp = requests.post(
            "https://api.audd.io/",
            data={"api_token": token, "return": "apple_music,spotify"},
            files={"file": (filename, fileobj)},
            headers=default_headers(),
            timeout=30,
        )
        resp.raise_for_status()
        payload = resp.json()
    except (requests.RequestException, ValueError) as exc:
        raise RecognitionUnavailable(f"Recognition service error: {exc}") from exc
    if payload.get("status") != "success":
        msg = (payload.get("error") or {}).get("error_message", "unknown error")
        raise RecognitionUnavailable(f"Recognition failed: {msg}")
    result = payload.get("result")
    if not result:
        return None

    apple = result.get("apple_music") or {}
    spotify = result.get("spotify") or {}
    cover = ""
    if apple.get("artwork", {}).get("url"):
        cover = apple["artwork"]["url"].replace("{w}", "600").replace("{h}", "600")
    elif spotify.get("album", {}).get("images"):
        cover = spotify["album"]["images"][0].get("url", "")
    links = {k: v for k, v in {
        "song_link": result.get("song_link"),
        "apple_music": apple.get("url"),
        "spotify": (spotify.get("external_urls") or {}).get("spotify"),
        "preview": (apple.get("previews") or [{}])[0].get("url") if apple.get("previews") else None,
    }.items() if v}
    return {
        "title": result.get("title", ""),
        "artist": result.get("artist", ""),
        "album": result.get("album", ""),
        "release_date": result.get("release_date", "") or "",
        "cover_url": cover,
        "links": links,
        "timecode": result.get("timecode", ""),
    }


def fetch_lyrics(title, artist, album="", duration=None):
    """Lyrics from LRCLIB (free, community-run). Returns dict with plain + synced (LRC) lyrics."""
    title, artist = (title or "").strip(), (artist or "").strip()
    if not title:
        return None
    key = "lyrics:" + hashlib.sha1(f"{artist}|{title}|{album}|{duration}".lower().encode()).hexdigest()
    if (hit := cache.get(key)) is not None:
        return hit or None
    result = None
    headers = default_headers()
    try:
        params = {"track_name": title, "artist_name": artist}
        if album:
            params["album_name"] = album
        if duration:
            params["duration"] = int(duration)
        resp = requests.get("https://lrclib.net/api/get", params=params, headers=headers, timeout=8)
        if resp.status_code == 200:
            result = resp.json()
        else:
            resp = requests.get("https://lrclib.net/api/search", params={"q": f"{artist} {title}".strip()},
                                headers=headers, timeout=8)
            if resp.ok and resp.json():
                result = resp.json()[0]
    except (requests.RequestException, ValueError):
        log.info("Lyrics lookup failed for %s - %s", artist, title, exc_info=True)
        return None  # don't cache transient failures
    data = None
    if result:
        data = {
            "plain": result.get("plainLyrics") or "",
            "synced": result.get("syncedLyrics") or "",
            "instrumental": bool(result.get("instrumental")),
            "source": "lrclib",
        }
    cache.set(key, data or {}, 7 * 24 * 3600)
    return data
