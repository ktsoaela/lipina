from rest_framework import serializers

from .models import Album, Artist, Playlist, Track
from .streaming import stream_url


def abs_media(request, field):
    if not field:
        return None
    url = field.url
    return request.build_absolute_uri(url) if request else url


class ArtistMiniSerializer(serializers.ModelSerializer):
    class Meta:
        model = Artist
        fields = ["id", "name", "slug"]


class AlbumMiniSerializer(serializers.ModelSerializer):
    cover_url = serializers.SerializerMethodField()

    class Meta:
        model = Album
        fields = ["id", "title", "year", "cover_url"]

    def get_cover_url(self, obj):
        return abs_media(self.context.get("request"), obj.cover)


class TrackSerializer(serializers.ModelSerializer):
    artist = ArtistMiniSerializer(read_only=True)
    album = AlbumMiniSerializer(read_only=True)
    artist_name = serializers.CharField(write_only=True, required=False)
    album_title = serializers.CharField(write_only=True, required=False, allow_blank=True)
    cover_url = serializers.SerializerMethodField()
    stream_url = serializers.SerializerMethodField()
    download_url = serializers.SerializerMethodField()
    liked = serializers.SerializerMethodField()
    is_owner = serializers.SerializerMethodField()
    has_lyrics = serializers.SerializerMethodField()

    class Meta:
        model = Track
        fields = [
            "id", "title", "artist", "album", "artist_name", "album_title", "genre", "year",
            "track_number", "disc_number", "duration", "bitrate", "mime_type", "size",
            "cover_url", "stream_url", "download_url", "liked", "is_owner", "is_public",
            "play_count", "has_lyrics", "created_at",
        ]
        read_only_fields = [
            "duration", "bitrate", "mime_type", "size", "play_count", "created_at", "track_number",
            "disc_number",
        ]

    def get_cover_url(self, obj):
        return abs_media(self.context.get("request"), obj.cover_or_album_cover)

    def get_stream_url(self, obj):
        return stream_url(self.context.get("request"), obj)

    def get_download_url(self, obj):
        return self.get_stream_url(obj) + "&download=1"

    def get_liked(self, obj):
        return bool(getattr(obj, "liked", False))

    def get_is_owner(self, obj):
        request = self.context.get("request")
        return bool(request and request.user.is_authenticated and obj.owner_id == request.user.pk)

    def get_has_lyrics(self, obj):
        return bool(obj.lyrics)

    def validate_is_public(self, value):
        request = self.context.get("request")
        if value and not (request and request.user.is_staff):
            raise serializers.ValidationError("Only staff can publish tracks to the shared catalog.")
        return value

    def update(self, instance, validated_data):
        from .services import get_or_create_album, get_or_create_artist

        artist_name = validated_data.pop("artist_name", None)
        album_title = validated_data.pop("album_title", None)
        if artist_name:
            instance.artist = get_or_create_artist(artist_name)
        if album_title is not None:
            instance.album = get_or_create_album(album_title, instance.artist, instance.year)
        return super().update(instance, validated_data)


class TrackUploadSerializer(serializers.Serializer):
    file = serializers.FileField()
    title = serializers.CharField(required=False, allow_blank=True)
    artist = serializers.CharField(required=False, allow_blank=True)
    album = serializers.CharField(required=False, allow_blank=True)
    genre = serializers.CharField(required=False, allow_blank=True)
    is_public = serializers.BooleanField(required=False, default=False)


class ArtistSerializer(serializers.ModelSerializer):
    image_url = serializers.SerializerMethodField()
    track_count = serializers.IntegerField(read_only=True)
    album_count = serializers.IntegerField(read_only=True)

    class Meta:
        model = Artist
        fields = ["id", "name", "slug", "bio", "image_url", "track_count", "album_count"]

    def get_image_url(self, obj):
        request = self.context.get("request")
        if obj.image:
            return abs_media(request, obj.image)
        album = obj.albums.exclude(cover="").first()
        return abs_media(request, album.cover) if album else None


class AlbumSerializer(serializers.ModelSerializer):
    artist = ArtistMiniSerializer(read_only=True)
    cover_url = serializers.SerializerMethodField()
    track_count = serializers.IntegerField(read_only=True)

    class Meta:
        model = Album
        fields = ["id", "title", "artist", "year", "cover_url", "track_count"]

    def get_cover_url(self, obj):
        return abs_media(self.context.get("request"), obj.cover)


class PlaylistSerializer(serializers.ModelSerializer):
    owner = serializers.CharField(source="owner.username", read_only=True)
    cover_url = serializers.SerializerMethodField()
    track_count = serializers.IntegerField(read_only=True)
    duration = serializers.FloatField(read_only=True)
    is_owner = serializers.SerializerMethodField()

    class Meta:
        model = Playlist
        fields = [
            "id", "name", "description", "is_public", "owner", "is_owner", "cover_url",
            "track_count", "duration", "created_at", "updated_at",
        ]

    def get_cover_url(self, obj):
        request = self.context.get("request")
        if obj.cover:
            return abs_media(request, obj.cover)
        entry = obj.entries.select_related("track__album").exclude(track__cover="").first()
        return abs_media(request, entry.track.cover_or_album_cover) if entry else None

    def get_is_owner(self, obj):
        request = self.context.get("request")
        return bool(request and obj.owner_id == request.user.pk)


class PlaylistDetailSerializer(PlaylistSerializer):
    tracks = serializers.SerializerMethodField()

    class Meta(PlaylistSerializer.Meta):
        fields = PlaylistSerializer.Meta.fields + ["tracks"]

    def get_tracks(self, obj):
        tracks = self.context.get("tracks")
        return TrackSerializer(tracks, many=True, context=self.context).data


class PlayEventSerializer(serializers.Serializer):
    track = serializers.IntegerField()
    played_at = serializers.DateTimeField(required=False)
    seconds = serializers.IntegerField(required=False, min_value=0, default=0)
    source = serializers.CharField(required=False, default="library")
    client_id = serializers.CharField(required=False, allow_blank=True, max_length=64, default="")
