from rest_framework.response import Response
from rest_framework.views import APIView

from .services import (ServiceUnavailable, apple_music_developer_token, itunes_search, services_config,
                       youtube_search)


class ConfigView(APIView):
    """Which streaming services this server supports, plus their public client config."""

    def get(self, request):
        return Response(services_config())


class AppleMusicTokenView(APIView):
    """MusicKit JS developer token. The user's own Apple Music sign-in happens in the browser."""

    def get(self, request):
        try:
            return Response({"token": apple_music_developer_token()})
        except ServiceUnavailable as exc:
            return Response({"detail": str(exc)}, status=503)


class _SearchView(APIView):
    throttle_scope = "connect_search"

    def search(self, q):
        raise NotImplementedError

    def get(self, request):
        q = (request.query_params.get("q") or "").strip()[:200]
        if not q:
            return Response({"results": []})
        try:
            return Response({"results": self.search(q)})
        except ServiceUnavailable as exc:
            return Response({"detail": str(exc)}, status=503)


class ITunesSearchView(_SearchView):
    def search(self, q):
        return itunes_search(q)


class YouTubeSearchView(_SearchView):
    def search(self, q):
        return youtube_search(q)
