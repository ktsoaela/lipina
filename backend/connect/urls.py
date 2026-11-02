from django.urls import path

from . import views

urlpatterns = [
    path("", views.ConfigView.as_view(), name="connect-config"),
    path("apple-music/token/", views.AppleMusicTokenView.as_view(), name="connect-apple-token"),
    path("itunes/search/", views.ITunesSearchView.as_view(), name="connect-itunes-search"),
    path("youtube/search/", views.YouTubeSearchView.as_view(), name="connect-youtube-search"),
]
