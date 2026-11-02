from unittest import mock

from django.contrib.auth import get_user_model
from rest_framework.test import APITestCase

from config.net import is_public_url
from radio.models import Station
from radio.services import BUILTIN_STATIONS, sync_country

ROWS = [
    {"stationuuid": "u1", "name": "Ukhozi FM", "url_resolved": "https://example.com/ukhozi", "tags": "Zulu,Talk",
     "state": "KwaZulu-Natal", "clickcount": 90, "codec": "AAC", "bitrate": 64},
    {"stationuuid": "u2", "name": "Jacaranda FM", "url_resolved": "http://example.com/jaca", "tags": "pop",
     "state": "Gauteng", "clickcount": 50},
    {"stationuuid": "bad", "name": "", "url_resolved": "ftp://nope"},
]


class RadioTests(APITestCase):
    def setUp(self):
        self.client.force_authenticate(get_user_model().objects.create_user("u", password="x" * 10))

    @mock.patch("radio.services.radio_browser_get", return_value=ROWS)
    def test_sync_and_filters(self, _):
        n_builtin = len(BUILTIN_STATIONS["ZA"])
        self.assertEqual(sync_country("ZA"), (2 + n_builtin, 0, 0))
        self.assertTrue(Station.objects.get(uuid="u1").is_https)
        r = self.client.get("/api/radio/stations/", {"tag": "zulu"})
        self.assertEqual([s["name"] for s in r.data["results"]], ["Ukhozi FM"])
        self.assertEqual(len(self.client.get("/api/radio/stations/", {"https": "1"}).data["results"]), 1 + n_builtin)
        sid = Station.objects.get(uuid="u2").pk
        self.client.post(f"/api/radio/stations/{sid}/favorite/")
        favs = self.client.get("/api/radio/stations/", {"favorites": "1"}).data["results"]
        self.assertEqual([s["id"] for s in favs], [sid])
        facets = self.client.get("/api/radio/stations/facets/").data
        self.assertIn("Gauteng", [s["name"] for s in facets["states"]])

    @mock.patch("radio.services.radio_browser_get")
    def test_resync_deactivates_missing(self, get):
        get.return_value = ROWS
        sync_country("ZA")
        get.return_value = ROWS[:1]
        self.assertEqual(sync_country("ZA"), (0, 1, 1))
        self.assertFalse(Station.objects.get(uuid="u2").is_active)

    @mock.patch("radio.services.radio_browser_get", return_value=ROWS)
    def test_builtin_sabc_stations(self, _):
        sync_country("ZA")
        r2k = Station.objects.get(uuid="sabc-radio2000")
        self.assertEqual(r2k.name, "Radio 2000")
        self.assertTrue(r2k.is_active and r2k.is_custom and r2k.stream_url.startswith("https://"))
        r2k.name = "Radio 2000 (edited)"
        r2k.save()
        sync_country("ZA")  # resync neither duplicates, overwrites nor deactivates it
        r2k.refresh_from_db()
        self.assertEqual(r2k.name, "Radio 2000 (edited)")
        self.assertTrue(r2k.is_active)
        names = [s["name"] for s in self.client.get("/api/radio/stations/", {"q": "radio 2000"}).data["results"]]
        self.assertIn("Radio 2000 (edited)", names)

    def test_province_normalization(self):
        from radio.services import normalize_province

        cases = {"Kzn": "KwaZulu-Natal", "Gauteng/limpopo": "Gauteng", "Cape Town": "Western Cape",
                 "kwazulu-natal": "KwaZulu-Natal", "South Africa": "", "": ""}
        for raw, expected in cases.items():
            self.assertEqual(normalize_province(raw), expected, raw)

    def test_ssrf_guard(self):
        for url in ["http://127.0.0.1/x", "http://10.0.0.5/", "http://169.254.169.254/latest", "file:///etc/passwd"]:
            self.assertFalse(is_public_url(url), url)
