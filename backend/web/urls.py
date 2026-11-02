from django.urls import path, re_path

from . import views

urlpatterns = [
    path("sw.js", views.service_worker, name="service-worker"),
    path("manifest.webmanifest", views.manifest, name="manifest"),
    path("healthz", views.healthz, name="healthz"),
    # Client-side routes; anything not matched by api/admin/static/media.
    re_path(r"^(?!api/|admin/|static/|media/)(?P<path>.*)$", views.app_shell, name="app"),
]
