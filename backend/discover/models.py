from django.conf import settings
from django.db import models


class Recognition(models.Model):
    """A song identified from a short microphone clip."""

    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="recognitions")
    created_at = models.DateTimeField(auto_now_add=True)
    title = models.CharField(max_length=500)
    artist = models.CharField(max_length=500)
    album = models.CharField(max_length=500, blank=True)
    release_date = models.CharField(max_length=32, blank=True)
    cover_url = models.URLField(max_length=1000, blank=True)
    links = models.JSONField(default=dict, blank=True)
    matched_track = models.ForeignKey("library.Track", null=True, blank=True, on_delete=models.SET_NULL)
    provider = models.CharField(max_length=32, default="audd")

    class Meta:
        ordering = ["-created_at"]
