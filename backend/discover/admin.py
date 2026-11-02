from django.contrib import admin

from .models import Recognition


@admin.register(Recognition)
class RecognitionAdmin(admin.ModelAdmin):
    list_display = ["title", "artist", "user", "created_at"]
    search_fields = ["title", "artist"]
