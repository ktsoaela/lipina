from unittest import mock

from django.contrib.auth import get_user_model
from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import override_settings
from rest_framework.test import APITestCase

from discover.models import Recognition
from library.models import Artist, Track


class FakeResp:
    def __init__(self, payload, status=200):
        self.payload, self.status_code, self.ok = payload, status, status == 200

    def raise_for_status(self):
        pass

    def json(self):
        return self.payload


AUDD = {"status": "success", "result": {
    "artist": "Master KG", "title": "Jerusalema", "album": "Jerusalema", "release_date": "2019-11-29",
    "song_link": "https://lis.tn/x", "apple_music": {"artwork": {"url": "https://img/{w}x{h}.jpg"}}}}


class DiscoverTests(APITestCase):
    def setUp(self):
        self.user = get_user_model().objects.create_user("u", password="x" * 10)
        self.client.force_authenticate(self.user)

    def clip(self):
        return SimpleUploadedFile("clip.webm", b"\x1a\x45\xdf\xa3" + b"0" * 100, content_type="audio/webm")

    @override_settings(AUDD_API_TOKEN="")
    def test_recognize_unconfigured(self):
        r = self.client.post("/api/recognize/", {"file": self.clip()}, format="multipart")
        self.assertEqual(r.status_code, 503)

    @override_settings(AUDD_API_TOKEN="t")
    @mock.patch("discover.services.requests.post", return_value=FakeResp(AUDD))
    def test_recognize_matches_library(self, _):
        track = Track.objects.create(owner=self.user, title="Jerusalema", artist=Artist.objects.create(name="Master KG"),
                                     file="audio/x.mp3")
        r = self.client.post("/api/recognize/", {"file": self.clip()}, format="multipart")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["match"]["cover_url"], "https://img/600x600.jpg")
        self.assertEqual(r.data["match"]["matched_track"]["id"], track.pk)
        self.assertEqual(Recognition.objects.count(), 1)
        self.assertEqual(len(self.client.get("/api/recognize/").data), 1)

    @override_settings(AUDD_API_TOKEN="t")
    @mock.patch("discover.services.requests.post", return_value=FakeResp({"status": "success", "result": None}))
    def test_no_match(self, _):
        r = self.client.post("/api/recognize/", {"file": self.clip()}, format="multipart")
        self.assertIsNone(r.data["match"])

    @mock.patch("discover.services.requests.get",
                return_value=FakeResp({"plainLyrics": "la la", "syncedLyrics": "[00:01.00]la la"}))
    def test_lyrics(self, _):
        r = self.client.get("/api/lyrics/", {"title": "Song", "artist": "Artist"})
        self.assertEqual(r.data["synced"], "[00:01.00]la la")
