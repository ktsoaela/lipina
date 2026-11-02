"""Signed, range-aware audio streaming.

<audio> elements and native players can't attach Authorization headers, so each serialized
track carries a short-lived signed URL. In production set USE_X_ACCEL_REDIRECT=True so nginx
serves the bytes (sendfile, ranges, no Python worker held open).
"""
import os
import re
from urllib.parse import quote

from django.conf import settings
from django.core import signing
from django.http import FileResponse, Http404, HttpResponse
from django.urls import reverse

SALT = "lipina.stream"
RANGE_RE = re.compile(r"bytes=(\d*)-(\d*)")


def make_stream_token(track_id: int, user_id: int | None) -> str:
    return signing.dumps({"t": track_id, "u": user_id}, salt=SALT, compress=True)


def check_stream_token(token: str, track_id: int) -> bool:
    try:
        data = signing.loads(token, salt=SALT, max_age=settings.STREAM_URL_MAX_AGE)
    except signing.BadSignature:
        return False
    return data.get("t") == track_id


def stream_url(request, track) -> str:
    user_id = request.user.pk if request and request.user.is_authenticated else None
    path = reverse("track-stream", args=[track.pk]) + "?t=" + make_stream_token(track.pk, user_id)
    return request.build_absolute_uri(path) if request else path


class RangeFileWrapper:
    def __init__(self, filelike, offset=0, length=None, blksize=64 * 1024):
        self.filelike = filelike
        self.filelike.seek(offset)
        self.remaining = length
        self.blksize = blksize

    def __iter__(self):
        while True:
            size = self.blksize if self.remaining is None else min(self.remaining, self.blksize)
            if size <= 0:
                break
            data = self.filelike.read(size)
            if not data:
                break
            if self.remaining is not None:
                self.remaining -= len(data)
            yield data
        self.close()

    def close(self):
        if hasattr(self.filelike, "close"):
            self.filelike.close()


def serve_track_file(request, track, download=False):
    if not track.file:
        raise Http404
    name = track.file.name
    disposition_name = quote(f"{track.artist.name} - {track.title}.{name.rsplit('.', 1)[-1]}")
    disposition = f"{'attachment' if download else 'inline'}; filename*=UTF-8''{disposition_name}"

    if settings.USE_X_ACCEL_REDIRECT:
        response = HttpResponse(content_type=track.mime_type)
        response["X-Accel-Redirect"] = settings.X_ACCEL_MEDIA_PREFIX + name
        response["Content-Disposition"] = disposition
        return response

    try:
        path = track.file.path
        size = os.path.getsize(path)
    except (NotImplementedError, FileNotFoundError):
        raise Http404("Audio file missing")

    range_header = request.headers.get("Range", "")
    match = RANGE_RE.match(range_header)
    if match and (match.group(1) or match.group(2)):
        first, last = match.groups()
        if first:
            start = int(first)
            end = int(last) if last else size - 1
        else:  # suffix range: last N bytes
            start = max(size - int(last), 0)
            end = size - 1
        end = min(end, size - 1)
        if start >= size or start > end:
            response = HttpResponse(status=416)
            response["Content-Range"] = f"bytes */{size}"
            return response
        length = end - start + 1
        from django.http import StreamingHttpResponse

        response = StreamingHttpResponse(
            RangeFileWrapper(open(path, "rb"), offset=start, length=length),
            status=206,
            content_type=track.mime_type,
        )
        response["Content-Length"] = str(length)
        response["Content-Range"] = f"bytes {start}-{end}/{size}"
    else:
        response = FileResponse(open(path, "rb"), content_type=track.mime_type)
        response["Content-Length"] = str(size)
    response["Accept-Ranges"] = "bytes"
    response["Content-Disposition"] = disposition
    response["Cache-Control"] = "private, max-age=86400"
    return response
