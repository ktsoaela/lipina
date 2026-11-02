import uuid

from django.conf import settings
from django.db import models
from django.db.models import Q
from django.utils.text import slugify


def audio_upload_path(instance, filename):
    ext = filename.rsplit(".", 1)[-1].lower() if "." in filename else "bin"
    return f"audio/{instance.owner_id or 'shared'}/{uuid.uuid4().hex}.{ext}"


def cover_upload_path(instance, filename):
    ext = filename.rsplit(".", 1)[-1].lower() if "." in filename else "jpg"
    return f"covers/{uuid.uuid4().hex}.{ext}"


class Artist(models.Model):
    name = models.CharField(max_length=255, unique=True)
    slug = models.SlugField(max_length=255, blank=True)
    image = models.ImageField(upload_to=cover_upload_path, blank=True)
    bio = models.TextField(blank=True)

    class Meta:
        ordering = ["name"]

    def save(self, *args, **kwargs):
        if not self.slug:
            self.slug = slugify(self.name)[:255]
        super().save(*args, **kwargs)

    def __str__(self):
        return self.name


class Album(models.Model):
    title = models.CharField(max_length=255)
    artist = models.ForeignKey(Artist, on_delete=models.CASCADE, related_name="albums")
    year = models.PositiveIntegerField(null=True, blank=True)
    cover = models.ImageField(upload_to=cover_upload_path, blank=True)

    class Meta:
        ordering = ["artist__name", "year", "title"]
        constraints = [models.UniqueConstraint(fields=["title", "artist"], name="unique_album_per_artist")]

    def __str__(self):
        return f"{self.title} — {self.artist}"


class TrackQuerySet(models.QuerySet):
    def visible_to(self, user):
        if user is None or not user.is_authenticated:
            return self.filter(is_public=True)
        return self.filter(Q(owner=user) | Q(is_public=True))


class Track(models.Model):
    owner = models.ForeignKey(
        settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="tracks", null=True, blank=True
    )
    title = models.CharField(max_length=255)
    artist = models.ForeignKey(Artist, on_delete=models.PROTECT, related_name="tracks")
    album = models.ForeignKey(Album, on_delete=models.SET_NULL, related_name="tracks", null=True, blank=True)
    genre = models.CharField(max_length=100, blank=True, db_index=True)
    year = models.PositiveIntegerField(null=True, blank=True)
    track_number = models.PositiveIntegerField(null=True, blank=True)
    disc_number = models.PositiveIntegerField(null=True, blank=True)
    duration = models.FloatField(default=0, help_text="Seconds")
    bitrate = models.PositiveIntegerField(null=True, blank=True, help_text="kbps")
    file = models.FileField(upload_to=audio_upload_path)
    mime_type = models.CharField(max_length=100, default="audio/mpeg")
    size = models.PositiveBigIntegerField(default=0)
    checksum = models.CharField(max_length=64, db_index=True, blank=True)
    cover = models.ImageField(upload_to=cover_upload_path, blank=True)
    lyrics = models.TextField(blank=True, help_text="Plain or LRC-formatted lyrics")
    is_public = models.BooleanField(default=False, help_text="Visible to every listener (catalog)")
    play_count = models.PositiveIntegerField(default=0)
    created_at = models.DateTimeField(auto_now_add=True)

    objects = TrackQuerySet.as_manager()

    class Meta:
        ordering = ["-created_at"]
        indexes = [models.Index(fields=["owner", "checksum"])]

    def __str__(self):
        return f"{self.title} — {self.artist}"

    @property
    def cover_or_album_cover(self):
        if self.cover:
            return self.cover
        if self.album_id and self.album.cover:
            return self.album.cover
        return None


class Playlist(models.Model):
    owner = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="playlists")
    name = models.CharField(max_length=200)
    description = models.TextField(blank=True)
    cover = models.ImageField(upload_to=cover_upload_path, blank=True)
    is_public = models.BooleanField(default=False)
    tracks = models.ManyToManyField(Track, through="PlaylistTrack", related_name="playlists")
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-updated_at"]

    def __str__(self):
        return self.name


class PlaylistTrack(models.Model):
    playlist = models.ForeignKey(Playlist, on_delete=models.CASCADE, related_name="entries")
    track = models.ForeignKey(Track, on_delete=models.CASCADE, related_name="playlist_entries")
    position = models.PositiveIntegerField(default=0)
    added_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["position", "added_at"]


class Like(models.Model):
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="likes")
    track = models.ForeignKey(Track, on_delete=models.CASCADE, related_name="likes")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]
        constraints = [models.UniqueConstraint(fields=["user", "track"], name="unique_like")]


class PlayEvent(models.Model):
    SOURCES = [(s, s) for s in ("library", "playlist", "album", "artist", "search", "radio", "queue", "offline")]
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="plays")
    track = models.ForeignKey(Track, on_delete=models.CASCADE, related_name="plays")
    played_at = models.DateTimeField(db_index=True)
    seconds = models.PositiveIntegerField(default=0)
    source = models.CharField(max_length=20, choices=SOURCES, default="library")
    # Idempotency key so offline clients can safely replay queued events.
    client_id = models.CharField(max_length=64, blank=True)

    class Meta:
        ordering = ["-played_at"]
        constraints = [
            models.UniqueConstraint(
                fields=["user", "client_id"], condition=~Q(client_id=""), name="unique_play_client_id"
            )
        ]
