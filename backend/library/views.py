from datetime import timedelta

from django.db import IntegrityError, transaction
from django.db.models import Count, Exists, F, Max, OuterRef, Q, Sum
from django.http import Http404
from django.shortcuts import get_object_or_404
from django.utils import timezone
from rest_framework import mixins, permissions, status, viewsets
from rest_framework.decorators import action
from rest_framework.parsers import FormParser, JSONParser, MultiPartParser
from rest_framework.response import Response
from rest_framework.views import APIView

from .models import Album, Artist, Like, PlayEvent, Playlist, PlaylistTrack, Track
from .serializers import (
    AlbumSerializer,
    ArtistSerializer,
    PlayEventSerializer,
    PlaylistDetailSerializer,
    PlaylistSerializer,
    TrackSerializer,
    TrackUploadSerializer,
)
from .services import UploadError, ingest_upload
from .streaming import check_stream_token, serve_track_file


def tracks_for(user):
    qs = Track.objects.visible_to(user).select_related("artist", "album")
    if user.is_authenticated:
        qs = qs.annotate(liked=Exists(Like.objects.filter(user=user, track=OuterRef("pk"))))
    return qs


def visible_artists(user):
    visible = Track.objects.visible_to(user)
    return (Artist.objects.filter(tracks__in=visible).distinct()
            .annotate(track_count=Count("tracks", filter=Q(tracks__in=visible), distinct=True),
                      album_count=Count("albums", distinct=True)))


def visible_albums(user):
    visible = Track.objects.visible_to(user)
    return (Album.objects.filter(tracks__in=visible).distinct().select_related("artist")
            .annotate(track_count=Count("tracks", filter=Q(tracks__in=visible), distinct=True)))


def recent_tracks(user, limit=50):
    recent_ids = []
    for tid in PlayEvent.objects.filter(user=user).values_list("track_id", flat=True)[:limit * 6]:
        if tid not in recent_ids:
            recent_ids.append(tid)
        if len(recent_ids) >= limit:
            break
    tracks = {t.pk: t for t in tracks_for(user).filter(pk__in=recent_ids)}
    return [tracks[i] for i in recent_ids if i in tracks]


class IsOwnerOrStaff(permissions.BasePermission):
    def has_object_permission(self, request, view, obj):
        if request.method in permissions.SAFE_METHODS:
            return True
        return request.user.is_staff or getattr(obj, "owner_id", None) == request.user.pk


class TrackViewSet(viewsets.ModelViewSet):
    serializer_class = TrackSerializer
    permission_classes = [permissions.IsAuthenticated, IsOwnerOrStaff]
    parser_classes = [JSONParser, MultiPartParser, FormParser]
    filterset_fields = ["genre", "artist", "album", "is_public"]
    search_fields = ["title", "artist__name", "album__title", "genre"]
    ordering_fields = ["created_at", "title", "play_count", "duration", "year", "artist__name"]
    http_method_names = ["get", "post", "patch", "delete", "head", "options"]

    def get_queryset(self):
        qs = tracks_for(self.request.user)
        scope = self.request.query_params.get("scope")
        if scope == "mine":
            qs = qs.filter(owner=self.request.user)
        elif scope == "catalog":
            qs = qs.filter(is_public=True)
        if ids := self.request.query_params.get("ids"):
            qs = qs.filter(pk__in=[int(i) for i in ids.split(",") if i.isdigit()][:500])
        return qs

    def create(self, request, *args, **kwargs):
        """Upload one or more audio files (multipart field `file`, repeatable)."""
        files = request.FILES.getlist("file")
        if not files:
            return Response({"file": ["No file uploaded."]}, status=400)
        meta = TrackUploadSerializer(data={**request.data.dict(), "file": files[0]})
        meta.is_valid(raise_exception=True)
        is_public = meta.validated_data.get("is_public", False) and request.user.is_staff
        overrides = {k: meta.validated_data.get(k) for k in ("title", "artist", "album", "genre")}
        if len(files) > 1:
            overrides = {}  # per-file tags win for batch uploads
        created, errors = [], []
        for f in files:
            try:
                track, _ = ingest_upload(request.user, f, is_public=is_public, overrides=overrides)
                created.append(track.pk)
            except UploadError as exc:
                errors.append({"file": f.name, "error": str(exc)})
        data = TrackSerializer(tracks_for(request.user).filter(pk__in=created), many=True,
                               context=self.get_serializer_context()).data
        code = status.HTTP_201_CREATED if created else status.HTTP_400_BAD_REQUEST
        return Response({"tracks": data, "errors": errors}, status=code)

    def perform_destroy(self, instance):
        storage_files = [instance.file, instance.cover]
        instance.delete()
        for f in storage_files:
            if f:
                f.delete(save=False)

    @action(detail=True, methods=["get"], permission_classes=[permissions.AllowAny],
            authentication_classes=[], url_path="stream", throttle_classes=[])
    def stream(self, request, pk=None):
        token = request.query_params.get("t", "")
        if not check_stream_token(token, int(pk)):
            raise Http404
        track = get_object_or_404(Track.objects.select_related("artist"), pk=pk)
        return serve_track_file(request, track, download=request.query_params.get("download") == "1")

    @action(detail=True, methods=["post", "delete"])
    def like(self, request, pk=None):
        track = self.get_object()
        if request.method == "POST":
            Like.objects.get_or_create(user=request.user, track=track)
            return Response({"liked": True})
        Like.objects.filter(user=request.user, track=track).delete()
        return Response({"liked": False})

    @action(detail=False, methods=["get"])
    def liked(self, request):
        qs = self.get_queryset().filter(likes__user=request.user).order_by("-likes__created_at")
        page = self.paginate_queryset(qs)
        return self.get_paginated_response(self.get_serializer(page, many=True).data)

    @action(detail=False, methods=["get"])
    def genres(self, request):
        rows = (self.get_queryset().exclude(genre="").values("genre")
                .annotate(count=Count("id")).order_by("-count")[:60])
        return Response(list(rows))

    @action(detail=True, methods=["get"])
    def radio(self, request, pk=None):
        """'Track radio': similar tracks by artist / genre / era, like an endless mix."""
        seed = self.get_object()
        qs = self.get_queryset().exclude(pk=seed.pk)
        similar = qs.filter(Q(artist=seed.artist) | Q(genre__iexact=seed.genre) if seed.genre else Q(artist=seed.artist))
        picks = list(similar.order_by("?")[:40])
        if len(picks) < 25:
            picks += list(qs.exclude(pk__in=[t.pk for t in picks]).order_by("?")[: 25 - len(picks)])
        return Response(self.get_serializer([seed] + picks, many=True).data)


class ArtistViewSet(viewsets.ReadOnlyModelViewSet):
    serializer_class = ArtistSerializer
    search_fields = ["name"]
    ordering_fields = ["name", "track_count"]

    def get_queryset(self):
        return visible_artists(self.request.user)

    @action(detail=True)
    def tracks(self, request, pk=None):
        artist = self.get_object()
        qs = tracks_for(request.user).filter(artist=artist).order_by("-play_count", "album__year", "track_number")
        return Response(TrackSerializer(qs[:500], many=True, context={"request": request}).data)

    @action(detail=True)
    def albums(self, request, pk=None):
        artist = self.get_object()
        visible = Track.objects.visible_to(request.user)
        qs = (Album.objects.filter(artist=artist, tracks__in=visible).distinct()
              .annotate(track_count=Count("tracks", distinct=True)).select_related("artist"))
        return Response(AlbumSerializer(qs, many=True, context={"request": request}).data)


class AlbumViewSet(viewsets.ReadOnlyModelViewSet):
    serializer_class = AlbumSerializer
    search_fields = ["title", "artist__name"]
    ordering_fields = ["title", "year"]
    filterset_fields = ["artist"]

    def get_queryset(self):
        return visible_albums(self.request.user)

    @action(detail=True)
    def tracks(self, request, pk=None):
        album = self.get_object()
        qs = tracks_for(request.user).filter(album=album).order_by("disc_number", "track_number", "title")
        return Response(TrackSerializer(qs, many=True, context={"request": request}).data)


class PlaylistViewSet(viewsets.ModelViewSet):
    permission_classes = [permissions.IsAuthenticated, IsOwnerOrStaff]
    search_fields = ["name", "description"]
    http_method_names = ["get", "post", "patch", "delete", "head", "options"]
    parser_classes = [JSONParser, MultiPartParser, FormParser]

    def get_serializer_class(self):
        return PlaylistDetailSerializer if self.action == "retrieve" else PlaylistSerializer

    def get_queryset(self):
        user = self.request.user
        qs = Playlist.objects.select_related("owner").annotate(
            track_count=Count("entries", distinct=True), duration=Sum("entries__track__duration")
        )
        if self.request.query_params.get("scope") == "public":
            return qs.filter(is_public=True)
        if self.action in ("list",):
            return qs.filter(owner=user)
        return qs.filter(Q(owner=user) | Q(is_public=True))

    def get_serializer_context(self):
        ctx = super().get_serializer_context()
        if self.action == "retrieve" and "pk" in self.kwargs:
            ctx["tracks"] = list(
                tracks_for(self.request.user)
                .filter(playlist_entries__playlist_id=self.kwargs["pk"])
                .order_by("playlist_entries__position", "playlist_entries__added_at")
            )
        return ctx

    def perform_create(self, serializer):
        serializer.save(owner=self.request.user)

    def _owned(self, pk):
        playlist = get_object_or_404(Playlist, pk=pk)
        if playlist.owner_id != self.request.user.pk and not self.request.user.is_staff:
            raise Http404
        return playlist

    @action(detail=True, methods=["post"], url_path="tracks")
    def add_tracks(self, request, pk=None):
        playlist = self._owned(pk)
        ids = request.data.get("track_ids") or ([request.data["track_id"]] if "track_id" in request.data else [])
        allowed = list(Track.objects.visible_to(request.user).filter(pk__in=ids).values_list("pk", flat=True))
        start = (playlist.entries.aggregate(m=Max("position"))["m"] or 0) + 1
        existing = set(playlist.entries.values_list("track_id", flat=True))
        new = [i for i in ids if i in allowed and i not in existing]
        PlaylistTrack.objects.bulk_create(
            [PlaylistTrack(playlist=playlist, track_id=tid, position=start + n) for n, tid in enumerate(new)]
        )
        playlist.save(update_fields=["updated_at"])
        return Response({"added": new}, status=201)

    @action(detail=True, methods=["delete"], url_path=r"tracks/(?P<track_id>\d+)")
    def remove_track(self, request, pk=None, track_id=None):
        playlist = self._owned(pk)
        playlist.entries.filter(track_id=track_id).delete()
        playlist.save(update_fields=["updated_at"])
        return Response(status=204)

    @action(detail=True, methods=["post"])
    def reorder(self, request, pk=None):
        playlist = self._owned(pk)
        order = {int(tid): n for n, tid in enumerate(request.data.get("track_ids", []))}
        entries = list(playlist.entries.all())
        for entry in entries:
            entry.position = order.get(entry.track_id, len(order) + entry.position)
        PlaylistTrack.objects.bulk_update(entries, ["position"])
        playlist.save(update_fields=["updated_at"])
        return Response(status=204)


class PlayHistoryView(APIView):
    """POST a play event (or a list of them, for offline replay). GET recent unique plays."""

    def get(self, request):
        return Response(TrackSerializer(recent_tracks(request.user), many=True, context={"request": request}).data)

    def post(self, request):
        items = request.data if isinstance(request.data, list) else [request.data]
        serializer = PlayEventSerializer(data=items[:500], many=True)
        serializer.is_valid(raise_exception=True)
        visible = set(Track.objects.visible_to(request.user)
                      .filter(pk__in=[i["track"] for i in serializer.validated_data])
                      .values_list("pk", flat=True))
        recorded = 0
        for item in serializer.validated_data:
            if item["track"] not in visible:
                continue
            try:
                with transaction.atomic():
                    PlayEvent.objects.create(
                        user=request.user, track_id=item["track"],
                        played_at=item.get("played_at") or timezone.now(), seconds=item.get("seconds", 0),
                        source=item.get("source", "library")[:20], client_id=item.get("client_id", ""),
                    )
                    Track.objects.filter(pk=item["track"]).update(play_count=F("play_count") + 1)
                    recorded += 1
            except IntegrityError:
                continue  # duplicate client_id: already synced
        return Response({"recorded": recorded}, status=201)


class HomeView(APIView):
    def get(self, request):
        user = request.user
        ctx = {"request": request}
        base = tracks_for(user)
        since = timezone.now() - timedelta(days=30)
        top_ids = (PlayEvent.objects.filter(user=user, played_at__gte=since).values("track")
                   .annotate(n=Count("id")).order_by("-n").values_list("track", flat=True)[:20])
        top_ids = list(top_ids)
        top = sorted(base.filter(pk__in=top_ids), key=lambda t: top_ids.index(t.pk))
        fav_genres = list(base.filter(pk__in=top_ids).exclude(genre="").values_list("genre", flat=True).distinct()[:3])
        mix = base.filter(genre__in=fav_genres).exclude(pk__in=top_ids).order_by("?")[:20] if fav_genres else base.order_by("?")[:20]
        playlists = Playlist.objects.filter(owner=user).annotate(
            track_count=Count("entries", distinct=True), duration=Sum("entries__track__duration"))[:12]
        albums = visible_albums(user).order_by("-id")[:12]
        hour = timezone.localtime().hour
        greeting = "Good morning" if hour < 12 else "Good afternoon" if hour < 18 else "Good evening"
        return Response({
            "greeting": greeting,
            "recently_played": TrackSerializer(recent_tracks(user, 12), many=True, context=ctx).data,
            "top_tracks": TrackSerializer(top, many=True, context=ctx).data,
            "daily_mix": TrackSerializer(mix, many=True, context=ctx).data,
            "new_uploads": TrackSerializer(base.order_by("-created_at")[:12], many=True, context=ctx).data,
            "popular": TrackSerializer(base.filter(is_public=True).order_by("-play_count")[:12], many=True, context=ctx).data,
            "playlists": PlaylistSerializer(playlists, many=True, context=ctx).data,
            "albums": AlbumSerializer(albums, many=True, context=ctx).data,
        })


class SearchView(APIView):
    def get(self, request):
        q = (request.query_params.get("q") or "").strip()
        if len(q) < 1:
            return Response({"tracks": [], "artists": [], "albums": [], "playlists": [], "stations": [], "podcasts": []})
        ctx = {"request": request}
        tracks = tracks_for(request.user).filter(
            Q(title__icontains=q) | Q(artist__name__icontains=q) | Q(album__title__icontains=q) | Q(genre__icontains=q)
        ).order_by("-play_count")[:30]
        artists = visible_artists(request.user).filter(name__icontains=q)[:10]
        albums = visible_albums(request.user).filter(
            Q(title__icontains=q) | Q(artist__name__icontains=q))[:10]
        playlists = Playlist.objects.filter(Q(owner=request.user) | Q(is_public=True), name__icontains=q).annotate(
            track_count=Count("entries", distinct=True), duration=Sum("entries__track__duration"))[:10]

        from podcasts.models import Podcast
        from podcasts.serializers import PodcastSerializer
        from radio.models import Station
        from radio.serializers import StationSerializer

        stations = Station.objects.filter(Q(name__icontains=q) | Q(tags__icontains=q), is_active=True)[:10]
        podcasts = Podcast.objects.filter(Q(title__icontains=q) | Q(author__icontains=q))[:10]
        return Response({
            "tracks": TrackSerializer(tracks, many=True, context=ctx).data,
            "artists": ArtistSerializer(artists, many=True, context=ctx).data,
            "albums": AlbumSerializer(albums, many=True, context=ctx).data,
            "playlists": PlaylistSerializer(playlists, many=True, context=ctx).data,
            "stations": StationSerializer(stations, many=True, context=ctx).data,
            "podcasts": PodcastSerializer(podcasts, many=True, context=ctx).data,
        })


class LibrarySnapshotView(APIView):
    """Compact view of the user's library so offline-first clients can reconcile local state."""

    def get(self, request):
        user = request.user
        playlists = [
            {"id": p.pk, "name": p.name, "updated_at": p.updated_at,
             "track_ids": list(p.entries.order_by("position").values_list("track_id", flat=True))}
            for p in Playlist.objects.filter(owner=user)
        ]
        return Response({
            "server_time": timezone.now(),
            "liked_track_ids": list(Like.objects.filter(user=user).values_list("track_id", flat=True)),
            "playlists": playlists,
        })
