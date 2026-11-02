from rest_framework import serializers

from .models import Station


class StationSerializer(serializers.ModelSerializer):
    tags = serializers.SerializerMethodField()
    is_favorite = serializers.SerializerMethodField()

    class Meta:
        model = Station
        fields = [
            "id", "uuid", "name", "stream_url", "homepage", "favicon", "tags", "country_code", "state",
            "language", "codec", "bitrate", "is_https", "votes", "clicks", "is_featured", "is_favorite",
        ]

    def get_tags(self, obj):
        return [t for t in obj.tags.split(",") if t]

    def get_is_favorite(self, obj):
        return bool(getattr(obj, "is_favorite", False))
