"""Podcast discovery (Apple Podcasts directory APIs) and RSS ingestion (feedparser)."""
import calendar
import hashlib
import logging
from datetime import datetime, timedelta, timezone as dt_tz

import feedparser
import requests
from django.conf import settings
from django.core.cache import cache
from django.db import transaction
from django.utils import timezone
from django.utils.html import strip_tags

from config.net import UnsafeURL, default_headers, read_limited, safe_get

from .models import Episode, Podcast

log = logging.getLogger(__name__)
MAX_FEED_BYTES = 25 * 1024 * 1024
REFRESH_AFTER = timedelta(hours=1)


class FeedError(Exception):
    pass


def _itunes(path, params):
    resp = requests.get(f"https://itunes.apple.com/{path}", params=params, headers=default_headers(), timeout=10)
    resp.raise_for_status()
    return resp.json().get("results", [])


def _itunes_row(row):
    return {
        "itunes_id": row.get("collectionId"),
        "title": row.get("collectionName") or row.get("trackName") or "",
        "author": row.get("artistName", ""),
        "image": row.get("artworkUrl600") or row.get("artworkUrl100") or "",
        "feed_url": row.get("feedUrl", ""),
        "genre": row.get("primaryGenreName", ""),
        "episode_count": row.get("trackCount"),
    }


def search_directory(term, country=None, limit=30):
    country = country or settings.PODCAST_COUNTRY
    key = "pod:search:" + hashlib.sha1(f"{country}:{term}".encode()).hexdigest()
    if (hit := cache.get(key)) is not None:
        return hit
    rows = _itunes("search", {"media": "podcast", "term": term, "country": country, "limit": limit})
    results = [_itunes_row(r) for r in rows if r.get("feedUrl")]
    cache.set(key, results, 3600)
    return results


def top_podcasts(country=None, limit=50):
    """Top chart for a country (default South Africa)."""
    country = country or settings.PODCAST_COUNTRY
    key = f"pod:top:{country}:{limit}"
    if (hit := cache.get(key)) is not None:
        return hit
    results = []
    try:
        resp = requests.get(
            f"https://rss.applemarketingtools.com/api/v2/{country}/podcasts/top/{limit}/podcasts.json",
            headers=default_headers(), timeout=10)
        resp.raise_for_status()
        ids = [r["id"] for r in resp.json().get("feed", {}).get("results", []) if r.get("id")]
        if ids:
            rows = _itunes("lookup", {"id": ",".join(ids), "entity": "podcast"})
            by_id = {str(r.get("collectionId")): _itunes_row(r) for r in rows if r.get("feedUrl")}
            results = [by_id[i] for i in ids if i in by_id]
    except (requests.RequestException, ValueError, KeyError):
        log.warning("Top podcasts chart failed; falling back to search", exc_info=True)
    if not results:
        results = search_directory("south africa", country=country, limit=limit)
    cache.set(key, results, 6 * 3600)
    return results


def lookup_itunes(itunes_id):
    rows = _itunes("lookup", {"id": itunes_id, "entity": "podcast"})
    if not rows or not rows[0].get("feedUrl"):
        raise FeedError("Podcast not found in directory")
    return _itunes_row(rows[0])


def _parse_duration(value):
    if not value:
        return 0
    try:
        parts = [int(float(p)) for p in str(value).strip().split(":")]
    except ValueError:
        return 0
    seconds = 0
    for p in parts:
        seconds = seconds * 60 + p
    return seconds


def _entry_datetime(entry):
    parsed = entry.get("published_parsed") or entry.get("updated_parsed")
    if not parsed:
        return None
    return datetime.fromtimestamp(calendar.timegm(parsed), tz=dt_tz.utc)


def _audio_enclosure(entry):
    for link in entry.get("enclosures", []) + entry.get("links", []):
        href = link.get("href") or link.get("url")
        mime = link.get("type", "")
        if href and (mime.startswith(("audio", "video")) or href.split("?")[0].endswith((".mp3", ".m4a", ".aac", ".ogg"))):
            try:
                size = int(link.get("length") or 0)
            except ValueError:
                size = 0
            return href, mime, size
    return None, None, 0


def _int_or_none(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def refresh_feed(podcast: Podcast, *, force=False) -> Podcast:
    if not force and podcast.last_fetched and timezone.now() - podcast.last_fetched < REFRESH_AFTER:
        return podcast
    headers = {}
    if podcast.etag:
        headers["If-None-Match"] = podcast.etag
    if podcast.last_modified:
        headers["If-Modified-Since"] = podcast.last_modified
    try:
        resp = safe_get(podcast.feed_url, headers=headers, stream=True, timeout=(5, 20))
        with resp:
            if resp.status_code == 304:
                podcast.last_fetched = timezone.now()
                podcast.save(update_fields=["last_fetched"])
                return podcast
            resp.raise_for_status()
            body = read_limited(resp, MAX_FEED_BYTES)
            etag, modified = resp.headers.get("ETag", ""), resp.headers.get("Last-Modified", "")
    except (requests.RequestException, UnsafeURL, ValueError) as exc:
        raise FeedError(f"Could not fetch feed: {exc}") from exc

    parsed = feedparser.parse(body)
    if parsed.bozo and not parsed.entries:
        raise FeedError("Not a valid podcast RSS feed")
    feed = parsed.feed
    with transaction.atomic():
        podcast.title = (feed.get("title") or podcast.title or "Untitled podcast")[:500]
        podcast.author = (feed.get("author") or feed.get("itunes_author") or podcast.author)[:500]
        podcast.description = strip_tags(feed.get("summary") or feed.get("subtitle") or podcast.description)
        # feedparser exposes both <image> and <itunes:image> through feed.image
        image = feed.get("image", {}).get("href") if isinstance(feed.get("image"), dict) else ""
        podcast.image = (image or podcast.image or "")[:1000]
        podcast.link = (feed.get("link") or "")[:1000]
        podcast.language = (feed.get("language") or "")[:32]
        podcast.categories = ",".join(t.get("term", "") for t in feed.get("tags", []) if t.get("term"))[:500]
        podcast.etag, podcast.last_modified = etag[:255], modified[:255]
        podcast.last_fetched = timezone.now()
        podcast.save()

        existing = set(podcast.episodes.values_list("guid", flat=True))
        new = []
        for entry in parsed.entries[:1000]:
            url, mime, size = _audio_enclosure(entry)
            if not url:
                continue
            guid = (entry.get("id") or url)[:1000]
            if guid in existing:
                continue
            existing.add(guid)
            img = entry.get("image", {}).get("href") if isinstance(entry.get("image"), dict) else ""
            new.append(Episode(
                podcast=podcast, guid=guid, title=(entry.get("title") or "Episode")[:1000],
                description=strip_tags(entry.get("summary") or "")[:20000], audio_url=url[:2000],
                mime_type=(mime or "")[:100], size=size, duration=_parse_duration(entry.get("itunes_duration")),
                published_at=_entry_datetime(entry), image=(img or "")[:1000],
                season=_int_or_none(entry.get("itunes_season")), number=_int_or_none(entry.get("itunes_episode")),
            ))
        Episode.objects.bulk_create(new, ignore_conflicts=True)
    return podcast


def import_podcast(*, feed_url=None, itunes_id=None) -> Podcast:
    if itunes_id:
        if podcast := Podcast.objects.filter(itunes_id=itunes_id).first():
            return refresh_feed(podcast)
        info = lookup_itunes(itunes_id)
        feed_url = info["feed_url"]
    if not feed_url:
        raise FeedError("feed_url or itunes_id is required")
    podcast = Podcast.objects.filter(feed_url=feed_url).first()
    created = podcast is None
    if created:
        podcast = Podcast(feed_url=feed_url, itunes_id=itunes_id, title=feed_url)
        if itunes_id:
            podcast.author, podcast.image, podcast.title = info["author"][:500], info["image"][:1000], info["title"][:500]
        podcast.save()
    try:
        return refresh_feed(podcast, force=created)
    except FeedError:
        if created:
            podcast.delete()
        raise
