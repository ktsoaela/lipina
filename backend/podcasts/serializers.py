from rest_framework import serializers

from .models import Episode, Podcast


class PodcastSerializer(serializers.ModelSerializer):
    is_subscribed = serializers.SerializerMethodField()
    episode_count = serializers.IntegerField(read_only=True, required=False)

    class Meta:
        model = Podcast
        fields = [
            "id", "itunes_id", "title", "author", "description", "image", "link", "categories",
            "language", "feed_url", "last_fetched", "is_subscribed", "episode_count",
        ]

    def get_is_subscribed(self, obj):
        if hasattr(obj, "is_subscribed"):
            return bool(obj.is_subscribed)
        request = self.context.get("request")
        return bool(request and request.user.is_authenticated
                    and obj.subscriptions.filter(user=request.user).exists())


class EpisodeSerializer(serializers.ModelSerializer):
    podcast_title = serializers.CharField(source="podcast.title", read_only=True)
    podcast_image = serializers.CharField(source="podcast.image", read_only=True)
    position = serializers.SerializerMethodField()
    completed = serializers.SerializerMethodField()

    class Meta:
        model = Episode
        fields = [
            "id", "podcast", "podcast_title", "podcast_image", "title", "description", "audio_url",
            "mime_type", "size", "duration", "published_at", "image", "season", "number", "position", "completed",
        ]

    def _progress(self, obj):
        return (self.context.get("progress") or {}).get(obj.pk)

    def get_position(self, obj):
        p = self._progress(obj)
        return p.position if p else 0

    def get_completed(self, obj):
        p = self._progress(obj)
        return p.completed if p else False


class ProgressSerializer(serializers.Serializer):
    position = serializers.IntegerField(min_value=0)
    completed = serializers.BooleanField(required=False, default=False)
