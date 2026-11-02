"""South African (or any country) radio via the community Radio Browser directory
(https://www.radio-browser.info), plus ICY "now playing" metadata."""
import logging
import re

import requests
from django.conf import settings
from django.core.cache import cache
from django.db import transaction
from django.utils import timezone

from config.net import UnsafeURL, safe_get

from .models import Station

log = logging.getLogger(__name__)
TIMEOUT = 10


def _headers():
    return {"User-Agent": settings.HTTP_USER_AGENT}


def radio_browser_get(path, params=None):
    last_exc = None
    for host in settings.RADIO_BROWSER_HOSTS:
        try:
            resp = requests.get(f"https://{host}{path}", params=params, headers=_headers(), timeout=TIMEOUT)
            resp.raise_for_status()
            return resp.json()
        except (requests.RequestException, ValueError) as exc:
            last_exc = exc
            log.warning("radio-browser host %s failed: %s", host, exc)
    raise RuntimeError(f"All radio-browser hosts failed: {last_exc}")


PROVINCES = ["Gauteng", "KwaZulu-Natal", "Western Cape", "Eastern Cape", "Northern Cape", "Free State",
             "Limpopo", "Mpumalanga", "North West"]
PROVINCE_ALIASES = {
    "kzn": "KwaZulu-Natal", "kwazulu natal": "KwaZulu-Natal", "durban": "KwaZulu-Natal", "pietermaritzburg": "KwaZulu-Natal",
    "johannesburg": "Gauteng", "pretoria": "Gauteng", "soweto": "Gauteng", "tshwane": "Gauteng", "joburg": "Gauteng",
    "cape town": "Western Cape", "somerset west": "Western Cape", "stellenbosch": "Western Cape", "george": "Western Cape",
    "port elizabeth": "Eastern Cape", "gqeberha": "Eastern Cape", "east london": "Eastern Cape",
    "bloemfontein": "Free State", "polokwane": "Limpopo", "nelspruit": "Mpumalanga", "mbombela": "Mpumalanga",
    "kimberley": "Northern Cape", "mahikeng": "North West", "rustenburg": "North West", "northwest": "North West",
}


def normalize_province(raw):
    """Map free-text directory regions ("Kzn", "Cape Town", "Gauteng/limpopo") onto SA provinces."""
    first = re.split(r"[/,;&]| and ", (raw or "").strip(), maxsplit=1)[0].strip().lower()
    if not first:
        return ""
    for province in PROVINCES:
        if first == province.lower() or first.replace("-", " ") == province.lower().replace("-", " "):
            return province
    return PROVINCE_ALIASES.get(first, "")


def _clean_tags(raw):
    tags = [t.strip().lower() for t in (raw or "").split(",") if t.strip()]
    return ",".join(dict.fromkeys(tags))[:500]


# Public-broadcaster stations missing from (or broken in) the radio-browser directory.
# radio-browser lists Radio 2000 with a web page instead of a stream, so the sync drops it.
# These are created once and never touched by the sync again, so admin edits stick.
_STW = "https://playerservices.streamtheworld.com/api/livestream-redirect/{}"
BUILTIN_STATIONS = {
    "ZA": [
        {"uuid": "sabc-radio2000", "name": "Radio 2000", "mount": "RADIO2000AAC.aac", "homepage": "https://www.radio2000.co.za",
         "tags": "sabc,adult contemporary,music,talk", "state": "Gauteng", "language": "english", "featured": True},
        {"uuid": "sabc-safm", "name": "SAfm", "mount": "SAFMAAC.aac", "homepage": "https://www.safm.co.za",
         "tags": "sabc,news,talk", "state": "Gauteng", "language": "english", "featured": True},
        {"uuid": "sabc-ikwekwezi", "name": "Ikwekwezi FM", "mount": "IKWEKWEZIAAC.aac", "homepage": "https://www.ikwekwezifm.co.za",
         "tags": "sabc,isindebele,music,talk", "state": "Mpumalanga", "language": "ndebele"},
        {"uuid": "sabc-ligwalagwala", "name": "Ligwalagwala FM", "mount": "LIGWALAGWALAAAC.aac", "homepage": "https://www.ligwalagwalafm.co.za",
         "tags": "sabc,siswati,music,talk", "state": "Mpumalanga", "language": "swati"},
        {"uuid": "sabc-motsweding", "name": "Motsweding FM", "mount": "MOTSWEDINGAAC.aac", "homepage": "https://www.motswedingfm.co.za",
         "tags": "sabc,setswana,music,talk", "state": "North West", "language": "tswana"},
        {"uuid": "sabc-xkfm", "name": "X-K FM", "mount": "XKFMAAC.aac", "homepage": "https://www.xkfm.co.za",
         "tags": "sabc,xun,khwe,community", "state": "Northern Cape", "language": "xun,khwe"},
        {"uuid": "sabc-trufm", "name": "Tru FM", "mount": "TRUFMAAC.aac", "homepage": "https://www.trufm.co.za",
         "tags": "sabc,youth,music", "state": "Eastern Cape", "language": "english,xhosa"},
    ],
}


def ensure_builtin_stations(country_code=None):
    """Create any missing built-in stations. Returns the number created."""
    country_code = (country_code or settings.RADIO_COUNTRY_CODE).upper()
    created = 0
    for spec in BUILTIN_STATIONS.get(country_code, []):
        url = _STW.format(spec["mount"])
        _, was_created = Station.objects.get_or_create(uuid=spec["uuid"], defaults={
            "name": spec["name"], "stream_url": url, "homepage": spec["homepage"], "tags": spec["tags"],
            "country_code": country_code, "state": spec["state"], "language": spec["language"],
            "codec": "AAC", "is_https": True, "is_custom": True, "is_active": True,
            "is_featured": spec.get("featured", False),
        })
        created += was_created
    return created


@transaction.atomic
def sync_country(country_code=None, limit=1500):
    """Upsert every working station for a country. Returns (created, updated, deactivated)."""
    country_code = (country_code or settings.RADIO_COUNTRY_CODE).upper()
    rows = radio_browser_get(
        f"/json/stations/bycountrycodeexact/{country_code}",
        {"hidebroken": "true", "order": "clickcount", "reverse": "true", "limit": limit},
    )
    now = timezone.now()
    seen, created, updated = set(), 0, 0
    for row in rows:
        uuid = row.get("stationuuid")
        url = (row.get("url_resolved") or row.get("url") or "").strip()
        name = (row.get("name") or "").strip()
        if not uuid or not url or not name or not url.startswith(("http://", "https://")):
            continue
        seen.add(uuid)
        defaults = {
            "name": name[:255],
            "stream_url": url[:1000],
            "homepage": (row.get("homepage") or "")[:1000],
            "favicon": (row.get("favicon") or "")[:1000] if (row.get("favicon") or "").startswith("http") else "",
            "tags": _clean_tags(row.get("tags")),
            "country_code": country_code,
            "state": normalize_province(row.get("state")) if country_code == "ZA" else (row.get("state") or "")[:120],
            "language": (row.get("language") or "")[:120],
            "codec": (row.get("codec") or "")[:32],
            "bitrate": int(row.get("bitrate") or 0),
            "is_https": url.startswith("https://"),
            "votes": int(row.get("votes") or 0),
            "clicks": int(row.get("clickcount") or 0),
            "is_active": True,
            "last_synced": now,
        }
        existing = Station.objects.filter(uuid=uuid).first()
        if existing is None:
            Station.objects.create(uuid=uuid, **defaults)
            created += 1
        elif not existing.is_custom:
            for k, v in defaults.items():
                setattr(existing, k, v)
            existing.save()
            updated += 1
    deactivated = (Station.objects.filter(country_code=country_code, is_custom=False, is_active=True)
                   .exclude(uuid__in=seen).update(is_active=False)) if seen else 0
    created += ensure_builtin_stations(country_code)
    cache.set(f"radio:synced:{country_code}", now.isoformat(), 6 * 3600)
    log.info("Radio sync %s: %s created, %s updated, %s deactivated", country_code, created, updated, deactivated)
    return created, updated, deactivated


def ensure_synced(country_code=None):
    """Lazy first-run sync so a fresh deploy has stations without a cron job."""
    country_code = (country_code or settings.RADIO_COUNTRY_CODE).upper()
    if Station.objects.filter(country_code=country_code, is_custom=False).exists():
        if cache.add(f"radio:builtins:{country_code}", 1, 3600):
            ensure_builtin_stations(country_code)
        return
    if not cache.add(f"radio:sync-lock:{country_code}", 1, 120):
        return
    try:
        sync_country(country_code)
    except Exception:
        log.exception("Initial radio sync failed")


def register_click(station):
    """Tell radio-browser a station was played (keeps its popularity data useful)."""
    if station.is_custom:
        return
    try:
        radio_browser_get(f"/json/url/{station.uuid}")
    except Exception:
        log.debug("click report failed", exc_info=True)


STREAM_TITLE_RE = re.compile(rb"StreamTitle='(.*?)';", re.S)


def fetch_now_playing(station):
    """Read one ICY metadata block from the stream. Cached briefly; never raises."""
    key = f"radio:np:{station.pk}"
    cached = cache.get(key)
    if cached is not None:
        return cached
    result = {"title": "", "artist": "", "raw": ""}
    try:
        resp = safe_get(station.stream_url, headers={"Icy-MetaData": "1"}, stream=True, timeout=(4, 6))
        with resp:
            metaint = int(resp.headers.get("icy-metaint", "0") or 0)
            if 0 < metaint <= 256 * 1024:
                raw = resp.raw
                raw.read(metaint)
                length_byte = raw.read(1)
                if length_byte:
                    meta = raw.read(length_byte[0] * 16)
                    match = STREAM_TITLE_RE.search(meta)
                    if match:
                        text = match.group(1).decode("utf-8", errors="replace").strip()
                        result["raw"] = text
                        if " - " in text:
                            result["artist"], result["title"] = [p.strip() for p in text.split(" - ", 1)]
                        else:
                            result["title"] = text
    except (requests.RequestException, UnsafeURL, ValueError, OSError):
        log.debug("now playing failed for %s", station.pk, exc_info=True)
    cache.set(key, result, 20)
    return result
