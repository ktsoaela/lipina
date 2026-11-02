from unittest import mock

from django.contrib.auth import get_user_model
from rest_framework.test import APITestCase

from podcasts.models import Episode, Podcast

FEED = b"""<?xml version="1.0"?>
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
<channel><title>South African Talks</title><itunes:author>Lindiwe</itunes:author>
<itunes:image href="https://example.com/art.jpg"/><description>Conversations</description>
<item><title>Ep 2</title><guid>g2</guid><pubDate>Tue, 02 Jan 2024 10:00:00 GMT</pubDate>
<enclosure url="https://example.com/2.mp3" type="audio/mpeg" length="1000"/><itunes:duration>1:02:03</itunes:duration></item>
<item><title>Ep 1</title><guid>g1</guid><pubDate>Mon, 01 Jan 2024 10:00:00 GMT</pubDate>
<enclosure url="https://example.com/1.mp3" type="audio/mpeg" length="1000"/><itunes:duration>300</itunes:duration></item>
</channel></rss>"""


class FakeResp:
    status_code = 200
    headers = {"ETag": "abc"}

    def __enter__(self):
        return self

    def __exit__(self, *a):
        pass

    def raise_for_status(self):
        pass

    def iter_content(self, n):
        yield FEED


class PodcastTests(APITestCase):
    def setUp(self):
        self.client.force_authenticate(get_user_model().objects.create_user("u", password="x" * 10))

    @mock.patch("podcasts.services.safe_get", return_value=FakeResp())
    def test_import_subscribe_progress(self, _):
        r = self.client.post("/api/podcasts/shows/", {"feed_url": "https://example.com/feed.xml"}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        pid = r.data["id"]
        podcast = Podcast.objects.get()
        self.assertEqual((podcast.title, podcast.author, podcast.image),
                         ("South African Talks", "Lindiwe", "https://example.com/art.jpg"))
        self.assertEqual(Episode.objects.get(guid="g2").duration, 3723)
        # re-import is idempotent
        self.client.post("/api/podcasts/shows/", {"feed_url": "https://example.com/feed.xml"}, format="json")
        self.assertEqual(Episode.objects.count(), 2)

        self.client.post(f"/api/podcasts/shows/{pid}/subscribe/")
        self.assertTrue(self.client.get("/api/podcasts/shows/subscriptions/").data[0]["is_subscribed"])
        eps = self.client.get(f"/api/podcasts/shows/{pid}/episodes/").data["results"]
        self.assertEqual([e["title"] for e in eps], ["Ep 2", "Ep 1"])

        eid = eps[1]["id"]
        self.client.put(f"/api/podcasts/episodes/{eid}/progress/", {"position": 120}, format="json")
        self.assertEqual(self.client.get(f"/api/podcasts/episodes/{eid}/").data["position"], 120)
        self.assertEqual(len(self.client.get("/api/podcasts/episodes/in-progress/").data), 1)
        r = self.client.put(f"/api/podcasts/episodes/{eid}/progress/", {"position": 290}, format="json")
        self.assertTrue(r.data["completed"])

    def test_rejects_internal_feed(self):
        r = self.client.post("/api/podcasts/shows/", {"feed_url": "http://127.0.0.1:8000/feed"}, format="json")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(Podcast.objects.count(), 0)
