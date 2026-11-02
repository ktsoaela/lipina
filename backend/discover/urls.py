from django.urls import path

from . import views

urlpatterns = [
    path("recognize/", views.RecognizeView.as_view(), name="recognize"),
    path("lyrics/", views.LyricsView.as_view(), name="lyrics"),
]
