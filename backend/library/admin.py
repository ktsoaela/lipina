from django.contrib import admin

from .models import Album, Artist, Like, PlayEvent, Playlist, PlaylistTrack, Track


@admin.register(Artist)
class ArtistAdmin(admin.ModelAdmin):
    search_fields = ["name"]
    list_display = ["name", "slug"]


@admin.register(Album)
class AlbumAdmin(admin.ModelAdmin):
    search_fields = ["title", "artist__name"]
    list_display = ["title", "artist", "year"]
    autocomplete_fields = ["artist"]


@admin.register(Track)
class TrackAdmin(admin.ModelAdmin):
    search_fields = ["title", "artist__name", "album__title"]
    list_display = ["title", "artist", "album", "owner", "is_public", "play_count", "created_at"]
    list_filter = ["is_public", "genre"]
    autocomplete_fields = ["artist", "album", "owner"]
    actions = ["publish", "unpublish"]

    @admin.action(description="Publish to shared catalog")
    def publish(self, request, queryset):
        queryset.update(is_public=True)

    @admin.action(description="Remove from shared catalog")
    def unpublish(self, request, queryset):
        queryset.update(is_public=False)


class PlaylistTrackInline(admin.TabularInline):
    model = PlaylistTrack
    autocomplete_fields = ["track"]
    extra = 0


@admin.register(Playlist)
class PlaylistAdmin(admin.ModelAdmin):
    list_display = ["name", "owner", "is_public", "updated_at"]
    search_fields = ["name", "owner__username"]
    inlines = [PlaylistTrackInline]


admin.site.register(Like)
admin.site.register(PlayEvent)
admin.site.site_header = "Lipina admin"
