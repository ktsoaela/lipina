from django.conf import settings
from django.contrib import admin
from django.urls import include, path

urlpatterns = [
    path("admin/", admin.site.urls),
    path("api/auth/", include("accounts.urls")),
    path("api/", include("library.urls")),
    path("api/radio/", include("radio.urls")),
    path("api/podcasts/", include("podcasts.urls")),
    path("api/", include("discover.urls")),
    path("api/connect/", include("connect.urls")),
    path("", include("web.urls")),
]

if settings.DEBUG:
    from django.conf.urls.static import static

    urlpatterns = static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT) + urlpatterns
