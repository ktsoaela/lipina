from unittest import mock

import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import override_settings
from rest_framework.test import APITestCase

from connect.services import iso_seconds, split_title


def _resp(data):
    r = mock.Mock()
    r.json.return_value = data
    r.raise_for_status.return_value = None
    return r


class ConnectTests(APITestCase):
    def setUp(self):
        cache.clear()
        self.client.force_authenticate(get_user_model().objects.create_user("u", password="x" * 10))

    @override_settings(SPOTIFY_CLIENT_ID="", YOUTUBE_API_KEY="", APPLE_MUSIC_TEAM_ID="")
    def test_config_defaults(self):
        d = self.client.get("/api/connect/").data
        self.assertFalse(d["spotify"]["enabled"])
        self.assertFalse(d["youtube"]["enabled"])
        self.assertFalse(d["apple_music"]["enabled"])
        self.assertTrue(d["itunes"]["enabled"])
        self.assertEqual(self.client.get("/api/connect/youtube/search/", {"q": "x"}).status_code, 503)
        self.assertEqual(self.client.get("/api/connect/apple-music/token/").status_code, 503)

    def test_requires_login(self):
        self.client.force_authenticate(None)
        self.assertEqual(self.client.get("/api/connect/").status_code, 401)

    @mock.patch("connect.services.requests.get")
    def test_itunes_search(self, get):
        get.return_value = _resp({"results": [
            {"trackId": 1, "trackName": "Jerusalema", "artistName": "Master KG", "collectionName": "J",
             "artworkUrl100": "https://a/100x100bb.jpg", "previewUrl": "https://p/1.m4a", "trackTimeMillis": 300500},
            {"trackId": 2, "trackName": "No preview"},
        ]})
        rows = self.client.get("/api/connect/itunes/search/", {"q": "jerusalema"}).data["results"]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["art"], "https://a/600x600bb.jpg")
        self.assertEqual(rows[0]["duration"], 300)
        self.client.get("/api/connect/itunes/search/", {"q": "Jerusalema"})
        self.assertEqual(get.call_count, 1)  # cached, case-insensitive

    @override_settings(YOUTUBE_API_KEY="k")
    @mock.patch("connect.services.requests.get")
    def test_youtube_search(self, get):
        get.side_effect = [
            _resp({"items": [{"id": {"videoId": "abc"}, "snippet": {
                "title": "Tyla - Water (Official Music Video)", "channelTitle": "TylaVEVO",
                "thumbnails": {"high": {"url": "https://i/hq.jpg"}}}}]}),
            _resp({"items": [{"id": "abc", "contentDetails": {"duration": "PT3M20S"}}]}),
        ]
        rows = self.client.get("/api/connect/youtube/search/", {"q": "tyla water"}).data["results"]
        self.assertEqual(rows, [{"id": "abc", "title": "Water", "artist": "Tyla", "art": "https://i/hq.jpg",
                                 "duration": 200, "url": "https://music.youtube.com/watch?v=abc"}])

    def test_title_helpers(self):
        self.assertEqual(split_title("Amapiano Mix", "DJ Maphorisa - Topic"), ("Amapiano Mix", "DJ Maphorisa"))
        self.assertEqual(iso_seconds("PT1H2M3S"), 3723)
        self.assertEqual(iso_seconds("bogus"), 0)

    def test_apple_music_token(self):
        key = ec.generate_private_key(ec.SECP256R1())
        pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                serialization.NoEncryption()).decode()
        with override_settings(APPLE_MUSIC_TEAM_ID="TEAM", APPLE_MUSIC_KEY_ID="KID", APPLE_MUSIC_PRIVATE_KEY=pem):
            self.assertTrue(self.client.get("/api/connect/").data["apple_music"]["enabled"])
            token = self.client.get("/api/connect/apple-music/token/").data["token"]
        self.assertEqual(jwt.get_unverified_header(token)["kid"], "KID")
        claims = jwt.decode(token, key.public_key(), algorithms=["ES256"])
        self.assertEqual(claims["iss"], "TEAM")
