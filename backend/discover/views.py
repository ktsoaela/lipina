from django.db.models import Q
from django.shortcuts import get_object_or_404
from rest_framework import serializers
from rest_framework.parsers import MultiPartParser
from rest_framework.response import Response
from rest_framework.views import APIView

from library.models import Track
from library.serializers import TrackSerializer
from library.views import tracks_for

from .models import Recognition
from .services import RecognitionUnavailable, fetch_lyrics, recognize_clip

MAX_CLIP_BYTES = 5 * 1024 * 1024


class RecognitionSerializer(serializers.ModelSerializer):
    matched_track = serializers.SerializerMethodField()

    class Meta:
        model = Recognition
        fields = ["id", "created_at", "title", "artist", "album", "release_date", "cover_url", "links", "matched_track"]

    def get_matched_track(self, obj):
        if not obj.matched_track_id:
            return None
        track = tracks_for(self.context["request"].user).filter(pk=obj.matched_track_id).first()
        return TrackSerializer(track, context=self.context).data if track else None


class RecognizeView(APIView):
    """POST a 5–15 s audio clip (multipart `file`) recorded from the mic. Shazam-style."""

    parser_classes = [MultiPartParser]
    throttle_scope = "recognize"

    def get(self, request):
        qs = Recognition.objects.filter(user=request.user)[:50]
        return Response(RecognitionSerializer(qs, many=True, context={"request": request}).data)

    def post(self, request):
        clip = request.FILES.get("file")
        if not clip:
            return Response({"detail": "Upload an audio clip as `file`."}, status=400)
        if clip.size > MAX_CLIP_BYTES:
            return Response({"detail": "Clip too large; 15 seconds is plenty."}, status=400)
        try:
            match = recognize_clip(clip, clip.name or "clip.webm")
        except RecognitionUnavailable as exc:
            return Response({"detail": str(exc)}, status=503)
        if not match:
            return Response({"match": None, "detail": "No match. Try closer to the speaker."})

        local = (Track.objects.visible_to(request.user)
                 .filter(title__iexact=match["title"])
                 .filter(Q(artist__name__iexact=match["artist"]) | Q(artist__name__icontains=match["artist"].split(",")[0]))
                 .first())
        rec = Recognition.objects.create(
            user=request.user, matched_track=local,
            **{k: match[k] for k in ("title", "artist", "album", "release_date", "cover_url", "links")})
        data = RecognitionSerializer(rec, context={"request": request}).data
        return Response({"match": data, "timecode": match.get("timecode")})


class LyricsView(APIView):
    """GET ?track=<id>  or  ?title=&artist=[&album=&duration=]"""

    def get(self, request):
        params = request.query_params
        if track_id := params.get("track"):
            track = get_object_or_404(tracks_for(request.user), pk=track_id)
            if track.lyrics:
                is_lrc = "[0" in track.lyrics[:200]
                return Response({"plain": "" if is_lrc else track.lyrics, "synced": track.lyrics if is_lrc else "",
                                 "instrumental": False, "source": "embedded"})
            data = fetch_lyrics(track.title, track.artist.name, track.album.title if track.album else "", track.duration)
        else:
            data = fetch_lyrics(params.get("title"), params.get("artist"), params.get("album", ""), params.get("duration"))
        if not data:
            return Response({"detail": "No lyrics found"}, status=404)
        return Response(data)
