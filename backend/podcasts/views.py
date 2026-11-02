import requests
from django.db.models import Count, Exists, OuterRef
from rest_framework import status, viewsets
from rest_framework.decorators import action
from rest_framework.response import Response
from rest_framework.views import APIView

from .models import Episode, EpisodeProgress, Podcast, Subscription
from .serializers import EpisodeSerializer, PodcastSerializer, ProgressSerializer
from .services import FeedError, import_podcast, refresh_feed, search_directory, top_podcasts


def progress_map(user, episodes):
    return {p.episode_id: p for p in EpisodeProgress.objects.filter(user=user, episode__in=episodes)}


class DirectorySearchView(APIView):
    """Search the global podcast directory (not yet imported podcasts)."""

    def get(self, request):
        q = (request.query_params.get("q") or "").strip()
        if not q:
            return Response([])
        try:
            return Response(search_directory(q, country=request.query_params.get("country")))
        except requests.RequestException:
            return Response({"detail": "Podcast directory unavailable"}, status=503)


class TopChartView(APIView):
    def get(self, request):
        try:
            return Response(top_podcasts(country=request.query_params.get("country")))
        except requests.RequestException:
            return Response({"detail": "Podcast directory unavailable"}, status=503)


class PodcastViewSet(viewsets.ReadOnlyModelViewSet):
    serializer_class = PodcastSerializer
    search_fields = ["title", "author"]

    def get_queryset(self):
        return Podcast.objects.annotate(
            is_subscribed=Exists(Subscription.objects.filter(user=self.request.user, podcast=OuterRef("pk"))),
            episode_count=Count("episodes"),
        )

    def create(self, request):
        """Import a podcast by `feed_url` or `itunes_id` (idempotent)."""
        try:
            podcast = import_podcast(feed_url=request.data.get("feed_url"), itunes_id=request.data.get("itunes_id"))
        except FeedError as exc:
            return Response({"detail": str(exc)}, status=400)
        except requests.RequestException:
            return Response({"detail": "Podcast directory unavailable"}, status=503)
        return Response(PodcastSerializer(self.get_queryset().get(pk=podcast.pk), context={"request": request}).data,
                        status=status.HTTP_201_CREATED)

    def retrieve(self, request, pk=None):
        podcast = self.get_object()
        try:
            refresh_feed(podcast)
        except FeedError:
            pass  # serve cached episodes
        return Response(self.get_serializer(self.get_queryset().get(pk=podcast.pk)).data)

    @action(detail=True)
    def episodes(self, request, pk=None):
        podcast = self.get_object()
        qs = podcast.episodes.select_related("podcast")
        page = self.paginate_queryset(qs)
        ctx = {"request": request, "progress": progress_map(request.user, page)}
        return self.get_paginated_response(EpisodeSerializer(page, many=True, context=ctx).data)

    @action(detail=True, methods=["post", "delete"])
    def subscribe(self, request, pk=None):
        podcast = self.get_object()
        if request.method == "POST":
            Subscription.objects.get_or_create(user=request.user, podcast=podcast)
            return Response({"is_subscribed": True})
        Subscription.objects.filter(user=request.user, podcast=podcast).delete()
        return Response({"is_subscribed": False})

    @action(detail=False)
    def subscriptions(self, request):
        qs = self.get_queryset().filter(subscriptions__user=request.user)
        return Response(self.get_serializer(qs, many=True).data)

    @action(detail=False)
    def feed(self, request):
        """Latest episodes across all subscriptions (the 'new episodes' inbox)."""
        podcasts = list(Podcast.objects.filter(subscriptions__user=request.user))
        for p in podcasts[:15]:  # bounded; the refresh_podcasts cron keeps the rest fresh
            try:
                refresh_feed(p)
            except FeedError:
                continue
        qs = Episode.objects.filter(podcast__in=podcasts).select_related("podcast")
        page = self.paginate_queryset(qs)
        ctx = {"request": request, "progress": progress_map(request.user, page)}
        return self.get_paginated_response(EpisodeSerializer(page, many=True, context=ctx).data)


class EpisodeViewSet(viewsets.ReadOnlyModelViewSet):
    serializer_class = EpisodeSerializer
    queryset = Episode.objects.select_related("podcast")

    def get_serializer_context(self):
        ctx = super().get_serializer_context()
        if "pk" in self.kwargs:
            ctx["progress"] = progress_map(self.request.user, Episode.objects.filter(pk=self.kwargs["pk"]))
        return ctx

    @action(detail=True, methods=["put", "post"])
    def progress(self, request, pk=None):
        episode = self.get_object()
        s = ProgressSerializer(data=request.data)
        s.is_valid(raise_exception=True)
        completed = s.validated_data["completed"] or (
            episode.duration and s.validated_data["position"] >= episode.duration - 30)
        EpisodeProgress.objects.update_or_create(
            user=request.user, episode=episode,
            defaults={"position": s.validated_data["position"], "completed": bool(completed)})
        return Response({"position": s.validated_data["position"], "completed": bool(completed)})

    @action(detail=False, url_path="in-progress")
    def in_progress(self, request):
        prog = EpisodeProgress.objects.filter(user=request.user, completed=False, position__gt=0)[:30]
        episodes = [p.episode for p in prog.select_related("episode__podcast")]
        ctx = {"request": request, "progress": {p.episode_id: p for p in prog}}
        return Response(EpisodeSerializer(episodes, many=True, context=ctx).data)
