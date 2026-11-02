import io
import shutil
import struct
import tempfile
import wave

from django.contrib.auth import get_user_model
from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import override_settings
from rest_framework.test import APITestCase

from library.models import PlayEvent, Track

User = get_user_model()
MEDIA = tempfile.mkdtemp()


def wav_bytes(seconds=1, rate=8000):
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(b"".join(struct.pack("<h", (i * 50) % 3000) for i in range(rate * seconds)))
    return buf.getvalue()


@override_settings(MEDIA_ROOT=MEDIA)
class LibraryAPITests(APITestCase):
    @classmethod
    def tearDownClass(cls):
        super().tearDownClass()
        shutil.rmtree(MEDIA, ignore_errors=True)

    def setUp(self):
        self.user = User.objects.create_user("thandi", password="s3cret-pass!")
        self.other = User.objects.create_user("sipho", password="s3cret-pass!")
        self.client.force_authenticate(self.user)

    def upload(self, name="Master KG - Jerusalema.wav", data=None, **extra):
        f = SimpleUploadedFile(name, data or wav_bytes(), content_type="audio/wav")
        return self.client.post("/api/tracks/", {"file": f, **extra}, format="multipart")

    def test_register_and_login(self):
        self.client.force_authenticate(None)
        r = self.client.post("/api/auth/register/", {"username": "lerato", "password": "Very-secure-99"}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        self.assertIn("access", r.data)
        r = self.client.post("/api/auth/token/", {"username": "lerato", "password": "Very-secure-99"}, format="json")
        self.assertEqual(r.status_code, 200)
        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + r.data["access"])
        self.assertEqual(self.client.get("/api/auth/me/").data["username"], "lerato")

    def test_upload_parses_filename_and_dedupes(self):
        r = self.upload()
        self.assertEqual(r.status_code, 201, r.data)
        track = r.data["tracks"][0]
        self.assertEqual(track["title"], "Jerusalema")
        self.assertEqual(track["artist"]["name"], "Master KG")
        self.assertAlmostEqual(track["duration"], 1.0, places=1)
        self.upload()
        self.assertEqual(Track.objects.count(), 1)

    def test_reads_id3_tags_in_wav(self):
        from mutagen.id3 import TALB, TCON, TIT2, TPE1
        from mutagen.wave import WAVE

        path = f"{MEDIA}/tagged.wav"
        with open(path, "wb") as fh:
            fh.write(wav_bytes())
        audio = WAVE(path)
        audio.add_tags()
        for frame in (TIT2(text="Water"), TPE1(text="Tyla"), TALB(text="Tyla"), TCON(text="Amapiano")):
            audio.tags.add(frame)
        audio.save()
        with open(path, "rb") as fh:
            track = self.upload(name="upload.wav", data=fh.read()).data["tracks"][0]
        self.assertEqual((track["title"], track["artist"]["name"], track["album"]["title"], track["genre"]),
                         ("Water", "Tyla", "Tyla", "Amapiano"))

    def test_rejects_bad_extension(self):
        r = self.upload(name="evil.exe", data=b"MZ")
        self.assertEqual(r.status_code, 400)

    def test_private_tracks_hidden_from_others(self):
        tid = self.upload().data["tracks"][0]["id"]
        self.client.force_authenticate(self.other)
        self.assertEqual(self.client.get(f"/api/tracks/{tid}/").status_code, 404)
        self.assertEqual(self.client.get("/api/tracks/").data["count"], 0)

    def test_non_staff_cannot_publish(self):
        self.upload(is_public="true")
        self.assertFalse(Track.objects.get().is_public)

    def test_stream_requires_valid_token_and_supports_ranges(self):
        data = self.upload().data["tracks"][0]
        url = data["stream_url"].replace("http://testserver", "")
        self.client.force_authenticate(None)
        full = self.client.get(url)
        self.assertEqual(full.status_code, 200)
        size = int(full["Content-Length"])
        part = self.client.get(url, HTTP_RANGE="bytes=10-19")
        self.assertEqual(part.status_code, 206)
        self.assertEqual(part["Content-Range"], f"bytes 10-19/{size}")
        self.assertEqual(len(b"".join(part.streaming_content)), 10)
        self.assertEqual(self.client.get(url, HTTP_RANGE=f"bytes={size + 5}-").status_code, 416)
        self.assertEqual(self.client.get(url.split("?")[0] + "?t=forged").status_code, 404)

    def test_playlist_flow(self):
        t1 = self.upload("A - One.wav", wav_bytes(1)).data["tracks"][0]["id"]
        t2 = self.upload("B - Two.wav", wav_bytes(2)).data["tracks"][0]["id"]
        pid = self.client.post("/api/playlists/", {"name": "Study"}, format="json").data["id"]
        self.client.post(f"/api/playlists/{pid}/tracks/", {"track_ids": [t1, t2]}, format="json")
        self.client.post(f"/api/playlists/{pid}/reorder/", {"track_ids": [t2, t1]}, format="json")
        detail = self.client.get(f"/api/playlists/{pid}/").data
        self.assertEqual([t["id"] for t in detail["tracks"]], [t2, t1])
        self.assertEqual(detail["track_count"], 2)
        self.client.delete(f"/api/playlists/{pid}/tracks/{t1}/")
        self.assertEqual(len(self.client.get(f"/api/playlists/{pid}/").data["tracks"]), 1)
        self.client.force_authenticate(self.other)
        self.assertEqual(self.client.post(f"/api/playlists/{pid}/tracks/", {"track_ids": [t1]}, format="json").status_code, 404)

    def test_like_and_history_offline_replay(self):
        tid = self.upload().data["tracks"][0]["id"]
        self.client.post(f"/api/tracks/{tid}/like/")
        self.assertTrue(self.client.get(f"/api/tracks/{tid}/").data["liked"])
        events = [{"track": tid, "client_id": "abc", "seconds": 30}, {"track": tid, "client_id": "abc"}]
        self.client.post("/api/history/", events, format="json")
        self.client.post("/api/history/", events, format="json")  # replayed after reconnect
        self.assertEqual(PlayEvent.objects.count(), 1)
        self.assertEqual(Track.objects.get().play_count, 1)
        home = self.client.get("/api/home/").data
        self.assertEqual(home["recently_played"][0]["id"], tid)
        snap = self.client.get("/api/library/snapshot/").data
        self.assertEqual(snap["liked_track_ids"], [tid])

    def test_search(self):
        self.upload()
        r = self.client.get("/api/search/", {"q": "jerus"})
        self.assertEqual(len(r.data["tracks"]), 1)
        self.assertEqual(r.data["artists"], [])
