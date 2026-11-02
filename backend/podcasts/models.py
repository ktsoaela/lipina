from django.conf import settings
from django.db import models


class Podcast(models.Model):
    feed_url = models.URLField(max_length=1000, unique=True)
    itunes_id = models.BigIntegerField(null=True, blank=True, unique=True)
    title = models.CharField(max_length=500, db_index=True)
    author = models.CharField(max_length=500, blank=True)
    description = models.TextField(blank=True)
    image = models.URLField(max_length=1000, blank=True)
    link = models.URLField(max_length=1000, blank=True)
    categories = models.CharField(max_length=500, blank=True)
    language = models.CharField(max_length=32, blank=True)
    etag = models.CharField(max_length=255, blank=True)
    last_modified = models.CharField(max_length=255, blank=True)
    last_fetched = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["title"]

    def __str__(self):
        return self.title


class Episode(models.Model):
    podcast = models.ForeignKey(Podcast, on_delete=models.CASCADE, related_name="episodes")
    guid = models.CharField(max_length=1000)
    title = models.CharField(max_length=1000)
    description = models.TextField(blank=True)
    audio_url = models.URLField(max_length=2000)
    mime_type = models.CharField(max_length=100, blank=True)
    size = models.PositiveBigIntegerField(default=0)
    duration = models.PositiveIntegerField(default=0, help_text="Seconds")
    published_at = models.DateTimeField(null=True, blank=True, db_index=True)
    image = models.URLField(max_length=1000, blank=True)
    season = models.PositiveIntegerField(null=True, blank=True)
    number = models.PositiveIntegerField(null=True, blank=True)

    class Meta:
        ordering = ["-published_at", "-id"]
        constraints = [models.UniqueConstraint(fields=["podcast", "guid"], name="unique_episode_guid")]

    def __str__(self):
        return self.title


class Subscription(models.Model):
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="podcast_subscriptions")
    podcast = models.ForeignKey(Podcast, on_delete=models.CASCADE, related_name="subscriptions")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=["user", "podcast"], name="unique_subscription")]


class EpisodeProgress(models.Model):
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="episode_progress")
    episode = models.ForeignKey(Episode, on_delete=models.CASCADE, related_name="progress")
    position = models.PositiveIntegerField(default=0)
    completed = models.BooleanField(default=False)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-updated_at"]
        constraints = [models.UniqueConstraint(fields=["user", "episode"], name="unique_episode_progress")]
