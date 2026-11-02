"""Outbound HTTP helpers with SSRF protection for user/third-party supplied URLs."""
import ipaddress
import socket
from urllib.parse import urljoin, urlparse

import requests
from django.conf import settings


class UnsafeURL(ValueError):
    pass


def default_headers():
    return {"User-Agent": settings.HTTP_USER_AGENT}


def is_public_url(url: str) -> bool:
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        return False
    try:
        infos = socket.getaddrinfo(parsed.hostname, parsed.port or (443 if parsed.scheme == "https" else 80))
    except (socket.gaierror, UnicodeError):
        return False
    for info in infos:
        ip = ipaddress.ip_address(info[4][0])
        if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved or ip.is_multicast or ip.is_unspecified:
            return False
    return True


def safe_get(url, *, headers=None, timeout=(5, 15), stream=False, max_redirects=5, **kwargs):
    """GET that re-validates every redirect hop against private/internal addresses."""
    hdrs = {**default_headers(), **(headers or {})}
    for _ in range(max_redirects + 1):
        if not is_public_url(url):
            raise UnsafeURL(f"Refusing to fetch non-public URL: {url}")
        resp = requests.get(url, headers=hdrs, timeout=timeout, stream=stream, allow_redirects=False, **kwargs)
        if resp.is_redirect and resp.headers.get("Location"):
            url = urljoin(url, resp.headers["Location"])
            resp.close()
            continue
        return resp
    raise requests.TooManyRedirects(url)


def read_limited(resp, max_bytes):
    chunks, total = [], 0
    for chunk in resp.iter_content(64 * 1024):
        total += len(chunk)
        if total > max_bytes:
            raise ValueError("Response too large")
        chunks.append(chunk)
    return b"".join(chunks)
