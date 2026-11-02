from django.urls import include, path
from rest_framework.routers import DefaultRouter

from . import views

router = DefaultRouter()
router.register("tracks", views.TrackViewSet, basename="track")
router.register("artists", views.ArtistViewSet, basename="artist")
router.register("albums", views.AlbumViewSet, basename="album")
router.register("playlists", views.PlaylistViewSet, basename="playlist")

urlpatterns = [
    path("", include(router.urls)),
    path("history/", views.PlayHistoryView.as_view(), name="history"),
    path("home/", views.HomeView.as_view(), name="home"),
    path("search/", views.SearchView.as_view(), name="search"),
    path("library/snapshot/", views.LibrarySnapshotView.as_view(), name="library-snapshot"),
]
