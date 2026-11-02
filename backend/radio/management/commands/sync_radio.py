from django.core.management.base import BaseCommand

from radio.services import sync_country


class Command(BaseCommand):
    help = "Sync radio stations from radio-browser.info (default: South Africa). Run daily via cron."

    def add_arguments(self, parser):
        parser.add_argument("--country", default=None, help="ISO country code, e.g. ZA")

    def handle(self, *args, **opts):
        created, updated, deactivated = sync_country(opts["country"])
        self.stdout.write(self.style.SUCCESS(
            f"Stations: {created} created, {updated} updated, {deactivated} deactivated"))
