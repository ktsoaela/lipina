from django.core.management.base import BaseCommand

from podcasts.models import Podcast
from podcasts.services import FeedError, refresh_feed


class Command(BaseCommand):
    help = "Refresh RSS feeds for podcasts that have at least one subscriber. Run hourly via cron."

    def add_arguments(self, parser):
        parser.add_argument("--all", action="store_true", help="Refresh every podcast, not just subscribed ones")

    def handle(self, *args, **opts):
        qs = Podcast.objects.all() if opts["all"] else Podcast.objects.filter(subscriptions__isnull=False).distinct()
        ok = failed = 0
        for podcast in qs.iterator():
            try:
                refresh_feed(podcast, force=True)
                ok += 1
            except FeedError as exc:
                failed += 1
                self.stderr.write(f"{podcast.title}: {exc}")
        self.stdout.write(self.style.SUCCESS(f"Refreshed {ok} podcasts ({failed} failed)"))
