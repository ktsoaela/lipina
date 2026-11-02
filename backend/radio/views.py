import threading
from collections import Counter

from django.db.models import Exists, OuterRef, Q
from rest_framework import permissions, viewsets
from rest_framework.decorators import action
from rest_framework.response import Response

from .models import FavoriteStation, Station
from .serializers import StationSerializer
from .services import ensure_synced, fetch_now_playing, register_click, sync_country


class StationViewSet(viewsets.ReadOnlyModelViewSet):
    """South African radio. Filters: ?q= ?tag= ?state= ?https=1 ?favorites=1"""

    serializer_class = StationSerializer
    filter_backends = []  # custom filtering below

    def get_queryset(self):
        ensure_synced()
        params = self.request.query_params
        qs = Station.objects.filter(is_active=True)
        if q := params.get("q"):
            qs = qs.filter(Q(name__icontains=q) | Q(tags__icontains=q) | Q(state__icontains=q))
        if tag := params.get("tag"):
            qs = qs.filter(tags__icontains=tag.lower())
        if state := params.get("state"):
            qs = qs.filter(state__iexact=state)
        if language := params.get("language"):
            qs = qs.filter(language__icontains=language)
        if params.get("https") == "1":
            qs = qs.filter(is_https=True)
        if self.request.user.is_authenticated:
            qs = qs.annotate(is_favorite=Exists(
                FavoriteStation.objects.filter(user=self.request.user, station=OuterRef("pk"))))
            if params.get("favorites") == "1":
                qs = qs.filter(is_favorite=True)
        return qs

    @action(detail=False)
    def facets(self, request):
        """Provinces and top genres for filter chips."""
        ensure_synced()
        rows = Station.objects.filter(is_active=True).values_list("state", "tags")
        states, tags = Counter(), Counter()
        for state, tag_str in rows:
            if state:
                states[state] += 1
            for t in tag_str.split(","):
                if t:
                    tags[t] += 1
        return Response({
            "states": [{"name": n, "count": c} for n, c in states.most_common(15)],
            "tags": [{"name": n, "count": c} for n, c in tags.most_common(30)],
        })

    @action(detail=True, methods=["get"], url_path="now-playing")
    def now_playing(self, request, pk=None):
        return Response(fetch_now_playing(self.get_object()))

    @action(detail=True, methods=["post"])
    def play(self, request, pk=None):
        station = self.get_object()
        threading.Thread(target=register_click, args=(station,), daemon=True).start()
        return Response({"stream_url": station.stream_url})

    @action(detail=True, methods=["post", "delete"])
    def favorite(self, request, pk=None):
        station = self.get_object()
        if request.method == "POST":
            FavoriteStation.objects.get_or_create(user=request.user, station=station)
            return Response({"is_favorite": True})
        FavoriteStation.objects.filter(user=request.user, station=station).delete()
        return Response({"is_favorite": False})

    @action(detail=False, methods=["post"], permission_classes=[permissions.IsAdminUser])
    def sync(self, request):
        created, updated, deactivated = sync_country(request.data.get("country_code"))
        return Response({"created": created, "updated": updated, "deactivated": deactivated})
