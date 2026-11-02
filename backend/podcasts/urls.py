from django.urls import path
from rest_framework.routers import DefaultRouter

from . import views

router = DefaultRouter()
router.register("shows", views.PodcastViewSet, basename="podcast")
router.register("episodes", views.EpisodeViewSet, basename="episode")

urlpatterns = [
    path("directory/search/", views.DirectorySearchView.as_view(), name="podcast-directory-search"),
    path("directory/top/", views.TopChartView.as_view(), name="podcast-top"),
] + router.urls
