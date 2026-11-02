import logging

from django.conf import settings
from django.core.files.base import ContentFile
from django.db import transaction

from .metadata import ALLOWED_EXTENSIONS, mime_for, read_audio_info, sha256_of
from .models import Album, Artist, Track

log = logging.getLogger(__name__)

COVER_EXT = {"image/png": "png", "image/webp": "webp", "image/gif": "gif"}


class UploadError(ValueError):
    pass


def get_or_create_artist(name: str) -> Artist:
    name = (name or "Unknown Artist").strip()[:255]
    artist = Artist.objects.filter(name__iexact=name).first()
    return artist or Artist.objects.create(name=name)


def get_or_create_album(title: str, artist: Artist, year=None) -> Album | None:
    title = (title or "").strip()[:255]
    if not title:
        return None
    album = Album.objects.filter(title__iexact=title, artist=artist).first()
    if album:
        if year and not album.year:
            album.year = year
            album.save(update_fields=["year"])
        return album
    return Album.objects.create(title=title, artist=artist, year=year)


@transaction.atomic
def ingest_upload(user, uploaded, *, is_public=False, overrides=None) -> tuple[Track, bool]:
    """Validate, tag-scan and store an uploaded audio file. Returns (track, created)."""
    filename = uploaded.name or "upload"
    ext = filename.rsplit(".", 1)[-1].lower() if "." in filename else ""
    if ext not in ALLOWED_EXTENSIONS:
        raise UploadError(f"Unsupported file type '.{ext}'. Allowed: {', '.join(sorted(ALLOWED_EXTENSIONS))}")
    if uploaded.size > settings.MAX_UPLOAD_MB * 1024 * 1024:
        raise UploadError(f"File too large (max {settings.MAX_UPLOAD_MB} MB)")

    checksum = sha256_of(uploaded)
    existing = Track.objects.filter(owner=user, checksum=checksum).first()
    if existing:
        return existing, False

    try:
        info = read_audio_info(uploaded, filename)
    except ValueError as exc:
        raise UploadError(str(exc)) from exc

    overrides = {k: v for k, v in (overrides or {}).items() if v not in (None, "")}
    artist = get_or_create_artist(overrides.get("artist") or info.artist)
    album_artist = get_or_create_artist(info.album_artist) if info.album_artist else artist
    album = get_or_create_album(overrides.get("album") or info.album, album_artist, info.year)

    track = Track(
        owner=user,
        title=(overrides.get("title") or info.title)[:255],
        artist=artist,
        album=album,
        genre=(overrides.get("genre") or info.genre)[:100],
        year=info.year,
        track_number=info.track_number,
        disc_number=info.disc_number,
        duration=info.duration,
        bitrate=info.bitrate,
        mime_type=mime_for(filename),
        size=uploaded.size,
        checksum=checksum,
        lyrics=info.lyrics or "",
        is_public=is_public,
    )
    track.file.save(filename, uploaded, save=False)
    if info.cover:
        ext = COVER_EXT.get(info.cover_mime, "jpg")
        track.cover.save(f"cover.{ext}", ContentFile(info.cover), save=False)
        if album and not album.cover:
            album.cover.save(f"album.{ext}", ContentFile(info.cover), save=True)
    track.save()
    log.info("Ingested track %s for user %s", track.pk, getattr(user, "pk", None))
    return track, True
