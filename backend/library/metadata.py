"""Audio tag + cover extraction using mutagen. Works for MP3, M4A/AAC, FLAC, OGG/Opus, WAV."""
import base64
import hashlib
import logging
import mimetypes
import re
from dataclasses import dataclass, field

import mutagen
from mutagen.flac import Picture

log = logging.getLogger(__name__)

ALLOWED_EXTENSIONS = {"mp3", "m4a", "mp4", "aac", "flac", "ogg", "oga", "opus", "wav", "webm"}
MIME_OVERRIDES = {
    "m4a": "audio/mp4",
    "mp4": "audio/mp4",
    "aac": "audio/aac",
    "flac": "audio/flac",
    "ogg": "audio/ogg",
    "oga": "audio/ogg",
    "opus": "audio/ogg",
    "wav": "audio/wav",
    "webm": "audio/webm",
    "mp3": "audio/mpeg",
}


@dataclass
class AudioInfo:
    title: str = ""
    artist: str = ""
    album: str = ""
    album_artist: str = ""
    genre: str = ""
    year: int | None = None
    track_number: int | None = None
    disc_number: int | None = None
    duration: float = 0.0
    bitrate: int | None = None
    lyrics: str = ""
    cover: bytes | None = None
    cover_mime: str = "image/jpeg"
    extra: dict = field(default_factory=dict)


def _first(tags, *keys):
    if not tags:
        return ""
    for key in keys:
        try:
            value = tags.get(key)
        except (KeyError, ValueError):
            value = None
        if value:
            value = value[0] if isinstance(value, list) else value
            return str(value).strip()
    return ""


def _int_prefix(value):
    match = re.match(r"\s*(\d+)", str(value or ""))
    return int(match.group(1)) if match else None


def _extract_cover(raw):
    """Return (bytes, mime) from the non-easy mutagen object, or (None, None)."""
    tags = getattr(raw, "tags", None)
    try:
        if hasattr(raw, "pictures") and raw.pictures:  # FLAC
            pic = raw.pictures[0]
            return pic.data, pic.mime
        if tags is None:
            return None, None
        if hasattr(tags, "getall"):  # ID3
            apics = tags.getall("APIC")
            if apics:
                return apics[0].data, apics[0].mime
        if "covr" in tags:  # MP4
            cover = tags["covr"][0]
            mime = "image/png" if getattr(cover, "imageformat", 0) == 14 else "image/jpeg"
            return bytes(cover), mime
        if "metadata_block_picture" in tags:  # Ogg Vorbis/Opus
            pic = Picture(base64.b64decode(tags["metadata_block_picture"][0]))
            return pic.data, pic.mime
    except Exception:  # corrupt art should never block an upload
        log.warning("Could not extract cover art", exc_info=True)
    return None, None


def _extract_lyrics(raw):
    tags = getattr(raw, "tags", None)
    if tags is None:
        return ""
    try:
        if hasattr(tags, "getall"):
            uslt = tags.getall("USLT")
            if uslt:
                return uslt[0].text
        for key in ("\xa9lyr", "lyrics", "LYRICS", "unsyncedlyrics"):
            if key in tags:
                value = tags[key]
                return str(value[0] if isinstance(value, list) else value)
    except Exception:
        log.debug("No lyrics", exc_info=True)
    return ""


def guess_title_artist_from_filename(filename: str):
    stem = re.sub(r"\.[^.]+$", "", filename)
    stem = re.sub(r"^\d+[\s._-]+", "", stem).replace("_", " ").strip()
    if " - " in stem:
        artist, title = stem.split(" - ", 1)
        return title.strip(), artist.strip()
    return stem, ""


def read_audio_info(fileobj, filename: str) -> AudioInfo:
    info = AudioInfo()
    try:
        fileobj.seek(0)
        easy = mutagen.File(fileobj, easy=True)
        fileobj.seek(0)
        raw = mutagen.File(fileobj)
    except Exception:
        log.warning("mutagen failed to parse %s", filename, exc_info=True)
        easy = raw = None
    finally:
        fileobj.seek(0)

    if easy is None and raw is None:
        raise ValueError("Unsupported or corrupt audio file")

    if easy is not None:
        tags = easy.tags
        info.title = _first(tags, "title")
        info.artist = _first(tags, "artist")
        info.album = _first(tags, "album")
        info.album_artist = _first(tags, "albumartist")
        info.genre = _first(tags, "genre")
        info.year = _int_prefix(_first(tags, "date", "year", "originaldate"))
        info.track_number = _int_prefix(_first(tags, "tracknumber"))
        info.disc_number = _int_prefix(_first(tags, "discnumber"))
        stream = getattr(easy, "info", None)
        if stream is not None:
            info.duration = float(getattr(stream, "length", 0) or 0)
            bitrate = getattr(stream, "bitrate", None)
            info.bitrate = int(bitrate / 1000) if bitrate else None

    if raw is not None and hasattr(getattr(raw, "tags", None), "getall"):
        # ID3 inside containers that have no "easy" mapping (WAV, AIFF): read frames directly.
        frames = raw.tags
        def frame(key):
            values = frames.getall(key)
            return str(values[0].text[0]).strip() if values and getattr(values[0], "text", None) else ""
        info.title = info.title or frame("TIT2")
        info.artist = info.artist or frame("TPE1")
        info.album = info.album or frame("TALB")
        info.album_artist = info.album_artist or frame("TPE2")
        info.genre = info.genre or frame("TCON")
        info.year = info.year or _int_prefix(frame("TDRC"))
        info.track_number = info.track_number or _int_prefix(frame("TRCK"))

    if raw is not None:
        info.cover, mime = _extract_cover(raw)
        info.cover_mime = mime or "image/jpeg"
        info.lyrics = _extract_lyrics(raw)
        if not info.duration and getattr(raw, "info", None):
            info.duration = float(getattr(raw.info, "length", 0) or 0)

    guessed_title, guessed_artist = guess_title_artist_from_filename(filename)
    info.title = info.title or guessed_title or "Untitled"
    info.artist = info.artist or info.album_artist or guessed_artist or "Unknown Artist"
    if info.year and not (1000 <= info.year <= 9999):
        info.year = None
    return info


def mime_for(filename: str) -> str:
    ext = filename.rsplit(".", 1)[-1].lower() if "." in filename else ""
    return MIME_OVERRIDES.get(ext) or mimetypes.guess_type(filename)[0] or "application/octet-stream"


def sha256_of(fileobj) -> str:
    digest = hashlib.sha256()
    fileobj.seek(0)
    for chunk in iter(lambda: fileobj.read(1024 * 1024), b""):
        digest.update(chunk)
    fileobj.seek(0)
    return digest.hexdigest()
