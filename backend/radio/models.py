from django.conf import settings
from django.db import models


class Station(models.Model):
    uuid = models.CharField(max_length=64, unique=True, help_text="radio-browser stationuuid or custom id")
    name = models.CharField(max_length=255, db_index=True)
    stream_url = models.URLField(max_length=1000)
    homepage = models.URLField(max_length=1000, blank=True)
    favicon = models.URLField(max_length=1000, blank=True)
    tags = models.CharField(max_length=500, blank=True)
    country_code = models.CharField(max_length=2, default="ZA", db_index=True)
    state = models.CharField(max_length=120, blank=True, help_text="Province / region")
    language = models.CharField(max_length=120, blank=True)
    codec = models.CharField(max_length=32, blank=True)
    bitrate = models.PositiveIntegerField(default=0)
    is_https = models.BooleanField(default=False)
    votes = models.PositiveIntegerField(default=0)
    clicks = models.PositiveIntegerField(default=0)
    is_active = models.BooleanField(default=True)
    is_featured = models.BooleanField(default=False)
    is_custom = models.BooleanField(default=False, help_text="Added manually; never overwritten by sync")
    last_synced = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ["-is_featured", "-clicks", "name"]

    def __str__(self):
        return self.name


class FavoriteStation(models.Model):
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="favorite_stations")
    station = models.ForeignKey(Station, on_delete=models.CASCADE, related_name="favorited_by")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]
        constraints = [models.UniqueConstraint(fields=["user", "station"], name="unique_fav_station")]
