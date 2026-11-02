from django.contrib import admin

from .models import Episode, EpisodeProgress, Podcast, Subscription


@admin.register(Podcast)
class PodcastAdmin(admin.ModelAdmin):
    list_display = ["title", "author", "last_fetched"]
    search_fields = ["title", "author", "feed_url"]


@admin.register(Episode)
class EpisodeAdmin(admin.ModelAdmin):
    list_display = ["title", "podcast", "published_at", "duration"]
    search_fields = ["title", "podcast__title"]
    list_select_related = ["podcast"]


admin.site.register(Subscription)
admin.site.register(EpisodeProgress)
