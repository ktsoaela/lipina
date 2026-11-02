from django.contrib import admin

from .models import FavoriteStation, Station


@admin.register(Station)
class StationAdmin(admin.ModelAdmin):
    list_display = ["name", "state", "codec", "bitrate", "is_https", "clicks", "is_featured", "is_active"]
    list_filter = ["is_active", "is_featured", "is_https", "is_custom", "state"]
    list_editable = ["is_featured", "is_active"]
    search_fields = ["name", "tags", "state"]


admin.site.register(FavoriteStation)
