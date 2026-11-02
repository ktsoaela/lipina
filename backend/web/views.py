from django.conf import settings
from django.contrib.staticfiles import finders
from django.db import connection
from django.http import FileResponse, Http404, JsonResponse
from django.shortcuts import render
from django.views.decorators.cache import cache_control, never_cache


@never_cache
def app_shell(request, path=""):
    """Single-page app shell. All client routes (/, /library, /radio, ...) resolve here."""
    return render(request, "web/index.html", {"debug": settings.DEBUG})


@cache_control(no_cache=True)
def service_worker(request):
    # Served from the site root so its scope covers the whole app.
    path = finders.find("web/sw.js")
    if not path:
        raise Http404
    response = FileResponse(open(path, "rb"), content_type="application/javascript")
    response["Service-Worker-Allowed"] = "/"
    return response


@cache_control(max_age=86400)
def manifest(request):
    return JsonResponse({
        "name": "Lipina — Music, Radio & Podcasts",
        "short_name": "Lipina",
        "description": "Your music, South African radio, podcasts and focus tools. Works offline.",
        "start_url": "/",
        "scope": "/",
        "display": "standalone",
        "background_color": "#0b0b10",
        "theme_color": "#0b0b10",
        "orientation": "any",
        "categories": ["music", "entertainment", "education"],
        "icons": [
            {"src": "/static/web/icons/icon.svg", "sizes": "any", "type": "image/svg+xml", "purpose": "any"},
            {"src": "/static/web/icons/maskable.svg", "sizes": "any", "type": "image/svg+xml", "purpose": "maskable"},
        ],
        "share_target": {"action": "/search", "method": "GET", "params": {"text": "q"}},
    }, content_type="application/manifest+json")


def healthz(request):
    try:
        with connection.cursor() as cursor:
            cursor.execute("SELECT 1")
    except Exception:
        return JsonResponse({"status": "db-error"}, status=503)
    return JsonResponse({"status": "ok"})
