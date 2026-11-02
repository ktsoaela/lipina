"""Third-party streaming services: Spotify, Apple Music / iTunes and YouTube Music.

Playback happens in the user's browser through each service's official player
(Spotify Web Playback SDK, MusicKit JS, YouTube IFrame player), signed in with
the user's own account. The server only hands out public config, signs the
Apple Music developer token, and proxies searches that need a server-side key.
"""
import hashlib
import html
import logging
import re
import time

import requests
from django.conf import settings
from django.core.cache import cache

log = logging.getLogger(__name__)
TIMEOUT = 10


class ServiceUnavailable(Exception):
    pass


def _key(prefix, *parts):
    return f"connect:{prefix}:" + hashlib.sha1("|".join(map(str, parts)).encode()).hexdigest()


def services_config():
    return {
        "spotify": {"enabled": bool(settings.SPOTIFY_CLIENT_ID), "client_id": settings.SPOTIFY_CLIENT_ID},
        "apple_music": {"enabled": apple_music_enabled()},
        "youtube": {"enabled": bool(settings.YOUTUBE_API_KEY)},
        "itunes": {"enabled": True, "country": settings.ITUNES_COUNTRY},
    }


# ------------------------------------------------------------------ Apple Music

def apple_music_enabled():
    return bool(settings.APPLE_MUSIC_TEAM_ID and settings.APPLE_MUSIC_KEY_ID and settings.APPLE_MUSIC_PRIVATE_KEY)


def apple_music_developer_token():
    """ES256 developer token for MusicKit JS, cached and re-signed well before it expires."""
    if not apple_music_enabled():
        raise ServiceUnavailable("Apple Music isn't set up on this server.")
    cached = cache.get("connect:apple:devtoken")
    if cached:
        return cached
    import jwt  # PyJWT[crypto]

    now = int(time.time())
    ttl = 12 * 3600
    private_key = settings.APPLE_MUSIC_PRIVATE_KEY.replace("\\n", "\n")
    token = jwt.encode(
        {"iss": settings.APPLE_MUSIC_TEAM_ID, "iat": now, "exp": now + ttl * 2},
        private_key, algorithm="ES256", headers={"kid": settings.APPLE_MUSIC_KEY_ID},
    )
    cache.set("connect:apple:devtoken", token, ttl)
    return token


# ----------------------------------------------------------------------- iTunes

def itunes_search(term, limit=25):
    """Songs from the public iTunes Search API, with 30 s previews. No key needed."""
    key = _key("itunes", settings.ITUNES_COUNTRY, term.lower(), limit)
    if (hit := cache.get(key)) is not None:
        return hit
    try:
        resp = requests.get("https://itunes.apple.com/search", timeout=TIMEOUT, params={
            "term": term, "media": "music", "entity": "song", "limit": limit, "country": settings.ITUNES_COUNTRY,
        }, headers={"User-Agent": settings.HTTP_USER_AGENT})
        resp.raise_for_status()
        rows = resp.json().get("results", [])
    except (requests.RequestException, ValueError) as exc:
        log.warning("iTunes search failed: %s", exc)
        raise ServiceUnavailable("iTunes search is unavailable right now.") from exc
    results = [{
        "id": str(r["trackId"]),
        "title": r.get("trackName", ""),
        "artist": r.get("artistName", ""),
        "album": r.get("collectionName", ""),
        "art": (r.get("artworkUrl100") or "").replace("100x100bb", "600x600bb"),
        "preview_url": r.get("previewUrl", ""),
        "duration": round((r.get("trackTimeMillis") or 0) / 1000),
        "url": r.get("trackViewUrl", ""),
    } for r in rows if r.get("trackId") and r.get("previewUrl")]
    cache.set(key, results, 6 * 3600)
    return results


# ---------------------------------------------------------------------- YouTube

_ISO_DURATION = re.compile(r"P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?")
_NOISE = re.compile(r"\s*[(\[](official|lyric|audio|music|video|visuali[sz]er|hd|4k)[^)\]]*[)\]]", re.I)


def iso_seconds(value):
    m = _ISO_DURATION.fullmatch(value or "")
    if not m:
        return 0
    d, h, mi, s = (int(x or 0) for x in m.groups())
    return ((d * 24 + h) * 60 + mi) * 60 + s


def split_title(title, channel):
    """'Artist - Song (Official Video)' → ('Song', 'Artist'); otherwise the channel is the artist."""
    clean = _NOISE.sub("", title).strip()
    if " - " in clean:
        artist, song = clean.split(" - ", 1)
        return song.strip(), artist.strip()
    return clean or title, re.sub(r"\s*-\s*Topic$|VEVO$", "", channel).strip()


def youtube_search(term, limit=20):
    """Embeddable music videos via the YouTube Data API. A search costs 100 quota units, so cache hard."""
    if not settings.YOUTUBE_API_KEY:
        raise ServiceUnavailable("YouTube Music isn't set up on this server.")
    key = _key("youtube", settings.YOUTUBE_REGION, term.lower(), limit)
    if (hit := cache.get(key)) is not None:
        return hit
    base = "https://www.googleapis.com/youtube/v3"
    try:
        resp = requests.get(f"{base}/search", timeout=TIMEOUT, params={
            "key": settings.YOUTUBE_API_KEY, "part": "snippet", "type": "video", "q": term, "maxResults": limit,
            "videoCategoryId": "10", "videoEmbeddable": "true", "regionCode": settings.YOUTUBE_REGION,
        })
        resp.raise_for_status()
        items = resp.json().get("items", [])
        ids = [i["id"]["videoId"] for i in items if i.get("id", {}).get("videoId")]
        durations = {}
        if ids:
            det = requests.get(f"{base}/videos", timeout=TIMEOUT, params={
                "key": settings.YOUTUBE_API_KEY, "part": "contentDetails", "id": ",".join(ids)})
            det.raise_for_status()
            durations = {v["id"]: iso_seconds(v["contentDetails"].get("duration")) for v in det.json().get("items", [])}
    except (requests.RequestException, ValueError, KeyError) as exc:
        log.warning("YouTube search failed: %s", exc)
        raise ServiceUnavailable("YouTube search is unavailable right now.") from exc
    results = []
    for item in items:
        vid = item.get("id", {}).get("videoId")
        if not vid:
            continue
        sn = item.get("snippet", {})
        title, artist = split_title(html.unescape(sn.get("title", "")), html.unescape(sn.get("channelTitle", "")))
        thumbs = sn.get("thumbnails", {})
        art = (thumbs.get("high") or thumbs.get("medium") or thumbs.get("default") or {}).get("url", "")
        results.append({"id": vid, "title": title, "artist": artist, "art": art, "duration": durations.get(vid, 0),
                        "url": f"https://music.youtube.com/watch?v={vid}"})
    cache.set(key, results, 12 * 3600)
    return results
