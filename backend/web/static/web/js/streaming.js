// Streaming services: Spotify, Apple Music (+ free iTunes previews) and YouTube Music.
//
// Each service plays through its own official player in this page, signed in with the
// user's own account: Spotify Web Playback SDK (Premium), MusicKit JS, YouTube IFrame player.
// The Lipina player hands playback to an "engine" here whenever the current queue item has
// `provider` set, so the player bar, queue, repeat, sleep timer and lyrics all keep working.
//
// Engine interface: load(item, autoplay) · play() · pause() · stop() · seek(sec) · setVolume(0..1)
//                   paused · currentTime · duration · notify(type, message) set by the player
//                   ("change" | "time" | "ended" | "error")
// This module must not import player.js (player.js imports it).
import { api } from "./api.js";

let configPromise = null;
export function getConfig(force = false) {
  if (force || !configPromise) {
    configPromise = api.get("/api/connect/").catch((e) => { configPromise = null; throw e; });
  }
  return configPromise;
}

const loaded = new Map();
function loadScript(src) {
  if (!loaded.has(src)) {
    loaded.set(src, new Promise((resolve, reject) => {
      const s = Object.assign(document.createElement("script"), { src, async: true });
      s.onload = resolve;
      s.onerror = () => { loaded.delete(src); reject(new Error("Couldn't load the player. Check your connection.")); };
      document.head.append(s);
    }));
  }
  return loaded.get(src);
}

/** Base for engines: holds the pending item when loaded without autoplay (e.g. queue restore). */
class Engine {
  constructor() { this.notify = () => {}; this.item = null; this.pending = false; }
  _tickStart() { clearInterval(this._tick); this._tick = setInterval(() => !this.paused && this.notify("time"), 500); }
  _tickStop() { clearInterval(this._tick); }
}

// ===================================================================== Spotify

const SP_SCOPES = "streaming user-read-email user-read-private user-read-playback-state user-modify-playback-state "
  + "playlist-read-private playlist-read-collaborative user-library-read";
const SP_STORE = "lipina.spotify";
const spRedirect = () => `${location.origin}/connect/spotify`;
const b64url = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

export const spotifyAuth = {
  get session() { try { return JSON.parse(localStorage.getItem(SP_STORE) || "null"); } catch { return null; } },
  set session(v) { v ? localStorage.setItem(SP_STORE, JSON.stringify(v)) : localStorage.removeItem(SP_STORE); },
  get connected() { return !!this.session?.refresh; },

  async login() {
    const { spotify } = await getConfig();
    if (!spotify.enabled) throw new Error("Spotify isn't set up on this server.");
    const verifier = b64url(crypto.getRandomValues(new Uint8Array(64)));
    const state = b64url(crypto.getRandomValues(new Uint8Array(16)));
    const challenge = b64url(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)));
    sessionStorage.setItem("lipina.spotify.pkce", JSON.stringify({ verifier, state }));
    const q = new URLSearchParams({
      client_id: spotify.client_id, response_type: "code", redirect_uri: spRedirect(), scope: SP_SCOPES,
      code_challenge_method: "S256", code_challenge: challenge, state,
    });
    location.assign(`https://accounts.spotify.com/authorize?${q}`);
  },

  /** Handle the redirect back from Spotify (/connect/spotify?code=…&state=…). */
  async finish(params) {
    const pkce = JSON.parse(sessionStorage.getItem("lipina.spotify.pkce") || "null");
    sessionStorage.removeItem("lipina.spotify.pkce");
    if (params.get("error")) throw new Error(params.get("error") === "access_denied" ? "Spotify sign-in was cancelled." : params.get("error"));
    if (!pkce || params.get("state") !== pkce.state) throw new Error("Spotify sign-in expired. Please try again.");
    const { spotify } = await getConfig();
    await this._token({
      grant_type: "authorization_code", code: params.get("code"), redirect_uri: spRedirect(),
      client_id: spotify.client_id, code_verifier: pkce.verifier,
    });
    const me = await spotifyApi("/me");
    this.session = { ...this.session, name: me.display_name || me.id, product: me.product };
    return this.session;
  },

  async _token(body) {
    const r = await fetch("https://accounts.spotify.com/api/token", {
      method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: new URLSearchParams(body),
    });
    const d = await r.json().catch(() => ({}));
    if (!r.ok) {
      if (body.grant_type === "refresh_token") this.logout();
      throw new Error(d.error_description || "Spotify sign-in failed");
    }
    const prev = this.session || {};
    this.session = { ...prev, access: d.access_token, refresh: d.refresh_token || prev.refresh, expires: Date.now() + (d.expires_in - 60) * 1000 };
  },

  async accessToken() {
    const s = this.session;
    if (!s?.refresh) throw new Error("Connect Spotify first.");
    if (Date.now() < s.expires) return s.access;
    this._refreshing ??= getConfig()
      .then(({ spotify }) => this._token({ grant_type: "refresh_token", refresh_token: s.refresh, client_id: spotify.client_id }))
      .finally(() => { this._refreshing = null; });
    await this._refreshing;
    return this.session.access;
  },

  logout() {
    this.session = null;
    spotifyEngine.disconnect();
  },
};

export async function spotifyApi(path, { method = "GET", body, query } = {}) {
  const url = new URL(path.startsWith("http") ? path : `https://api.spotify.com/v1${path}`);
  if (query) Object.entries(query).forEach(([k, v]) => v != null && url.searchParams.set(k, v));
  const r = await fetch(url, {
    method, body: body && JSON.stringify(body),
    headers: { Authorization: `Bearer ${await spotifyAuth.accessToken()}`, ...(body ? { "Content-Type": "application/json" } : {}) },
  });
  if (r.status === 204) return null;
  const d = await r.json().catch(() => null);
  if (!r.ok) {
    const err = new Error(d?.error?.message || `Spotify request failed (${r.status})`);
    err.status = r.status;
    throw err;
  }
  return d;
}

class SpotifyEngine extends Engine {
  constructor() {
    super();
    this.sdk = null;
    this.deviceId = null;
    this.state = null;
    this.stateAt = 0;
  }

  get paused() { return !this.state || this.state.paused; }
  get currentTime() {
    if (!this.state) return 0;
    const ms = this.state.position + (this.state.paused ? 0 : performance.now() - this.stateAt);
    return Math.min(ms, this.state.duration) / 1000;
  }
  get duration() { return (this.state?.duration || 0) / 1000 || this.item?.duration || 0; }

  async _ready() {
    if (this.deviceId) return this.deviceId;
    this._connecting ??= (async () => {
      const sdkReady = new Promise((resolve) => {
        if (window.Spotify) return resolve();
        window.onSpotifyWebPlaybackSDKReady = resolve;
      });
      await loadScript("https://sdk.scdn.co/spotify-player.js");
      await sdkReady;
      const sdk = new window.Spotify.Player({
        name: "Lipina", volume: this._volume ?? 1,
        getOAuthToken: (cb) => spotifyAuth.accessToken().then(cb, (e) => this.notify("error", e.message)),
      });
      const fail = (msg) => () => this.notify("error", msg);
      sdk.addListener("initialization_error", fail("Spotify can't play in this browser. Try Chrome, Edge or Firefox on a computer."));
      sdk.addListener("authentication_error", () => { spotifyAuth.logout(); this.notify("error", "Spotify signed you out. Connect it again under Streaming."); });
      sdk.addListener("account_error", fail("Playing full Spotify tracks needs Spotify Premium."));
      sdk.addListener("playback_error", fail("Spotify couldn't play this track."));
      sdk.addListener("player_state_changed", (st) => this._onState(st));
      const id = await new Promise((resolve, reject) => {
        sdk.addListener("ready", ({ device_id: d }) => resolve(d));
        sdk.addListener("not_ready", () => { this.deviceId = null; });
        sdk.connect().then((ok) => ok || reject(new Error("Couldn't connect to Spotify.")));
        setTimeout(() => reject(new Error("Spotify took too long to start. Check that you have Premium.")), 15000);
      });
      this.sdk = sdk;
      this.deviceId = id;
      return id;
    })().finally(() => { this._connecting = null; });
    return this._connecting;
  }

  _onState(st) {
    if (!st) return;
    const prev = this.state;
    const ourTrack = st.track_window?.current_track?.uri === this.item?.uri
      || st.track_window?.previous_tracks?.some((t) => t.uri === this.item?.uri);
    if (!ourTrack) return;
    // A single-URI play ends as: paused at position 0. Detect it by where we expected to be.
    if (prev && !prev.paused && st.paused && st.position === 0) {
      const expected = prev.position + (performance.now() - this.stateAt);
      if (expected >= prev.duration - 4000) {
        this.state = { ...st, duration: prev.duration };
        this.stateAt = performance.now();
        this._tickStop();
        return this.notify("ended");
      }
    }
    this.state = st;
    this.stateAt = performance.now();
    st.paused ? this._tickStop() : this._tickStart();
    this.notify("change");
  }

  async load(item, autoplay) {
    this.item = item;
    this.state = null;
    this.pending = !autoplay;
    if (autoplay) await this._start();
  }

  async _start(positionMs = 0) {
    this.pending = false;
    const item = this.item;
    this.sdk?.activateElement?.(); // lets mobile browsers start audio from this tap
    const device = await this._ready();
    if (item !== this.item) return;
    await spotifyApi("/me/player/play", { method: "PUT", query: { device_id: device }, body: { uris: [item.uri], position_ms: positionMs } });
  }

  async play() {
    if (this.pending || !this.state) return this._start(Math.round((this.item?.startAt || 0) * 1000));
    return this.sdk?.resume();
  }

  pause() { this.sdk?.pause(); }
  stop() { this._tickStop(); if (this.state && !this.state.paused) this.sdk?.pause(); this.item = null; this.state = null; }
  seek(t) { this.sdk?.seek(Math.round(t * 1000)); }
  setVolume(v) { this._volume = v; this.sdk?.setVolume(Math.max(v, 0.0001)); }
  disconnect() { this.stop(); this.sdk?.disconnect(); this.sdk = null; this.deviceId = null; }
}
export const spotifyEngine = new SpotifyEngine();

export const fromSpotify = (t) => ({
  key: `spotify:${t.id}`, kind: "spotify", provider: "spotify", service: "Spotify", remoteId: t.id, uri: t.uri,
  title: t.name, subtitle: (t.artists || []).map((a) => a.name).join(", "), album: t.album?.name || "",
  art: t.album?.images?.[1]?.url || t.album?.images?.[0]?.url || null, duration: (t.duration_ms || 0) / 1000,
  externalUrl: t.external_urls?.spotify,
});

// ================================================================ Apple Music

class AppleMusicEngine extends Engine {
  get paused() { return !this.mk?.isPlaying; }
  get currentTime() { return this.mk?.currentPlaybackTime || 0; }
  get duration() { return this.mk?.currentPlaybackDuration || this.item?.duration || 0; }

  /** Configure MusicKit (works without sign-in: everyone gets 30 s previews). */
  async kit() {
    if (this.mk) return this.mk;
    this._init ??= (async () => {
      const ready = new Promise((resolve) => {
        if (window.MusicKit) return resolve();
        document.addEventListener("musickitloaded", resolve, { once: true });
      });
      const { token } = await api.get("/api/connect/apple-music/token/");
      await loadScript("https://js-cdn.music.apple.com/musickit/v3/musickit.js");
      await ready;
      await window.MusicKit.configure({ developerToken: token, app: { name: "Lipina", build: "1.0" } });
      const mk = window.MusicKit.getInstance();
      const S = window.MusicKit.PlaybackStates;
      mk.addEventListener("playbackTimeDidChange", () => this.item && this.notify("time"));
      mk.addEventListener("playbackStateDidChange", ({ state }) => {
        if (!this.item) return;
        if (state === S.completed || state === S.ended) return this.notify("ended");
        this.notify("change");
      });
      mk.addEventListener("mediaPlaybackError", () => this.item && this.notify("error", "Apple Music couldn't play this song."));
      this.mk = mk;
      return mk;
    })().finally(() => { this._init = null; });
    return this._init;
  }

  get connected() { return !!this.mk?.isAuthorized || localStorage.getItem("lipina.apple") === "1"; }
  async authorize() { const mk = await this.kit(); await mk.authorize(); localStorage.setItem("lipina.apple", "1"); }
  async unauthorize() { localStorage.removeItem("lipina.apple"); await this.mk?.unauthorize(); }

  async api(path, query) {
    const mk = await this.kit();
    const storefront = mk.storefrontId || (await getConfig()).itunes.country;
    return (await mk.api.music(path.replace("{storefront}", storefront), query)).data;
  }

  async load(item, autoplay) {
    this.item = item;
    this.pending = !autoplay;
    if (autoplay) await this._start();
  }

  async _start() {
    this.pending = false;
    const item = this.item;
    const mk = await this.kit();
    if (item !== this.item) return;
    await mk.setQueue({ song: item.remoteId, startPlaying: true });
    if (item.startAt) mk.seekToTime(item.startAt);
  }

  async play() { return this.pending ? this._start() : this.mk?.play(); }
  pause() { this.mk?.pause(); }
  stop() { this.item = null; if (this.mk?.isPlaying) this.mk.stop(); }
  seek(t) { this.mk?.seekToTime(t); }
  setVolume(v) { if (this.mk) this.mk.volume = v; }
}
export const appleEngine = new AppleMusicEngine();

const appleArt = (a, size = 300) => a?.url?.replace("{w}", size).replace("{h}", size) || null;
export const fromAppleMusic = (s) => ({
  key: `apple:${s.id}`, kind: "apple", provider: "apple", service: "Apple Music",
  remoteId: s.attributes?.playParams?.catalogId || s.attributes?.playParams?.id || s.id,
  title: s.attributes?.name || "", subtitle: s.attributes?.artistName || "", album: s.attributes?.albumName || "",
  art: appleArt(s.attributes?.artwork), duration: (s.attributes?.durationInMillis || 0) / 1000, externalUrl: s.attributes?.url,
});
export const appleArtwork = appleArt;

// iTunes previews are plain https audio, so the normal player plays them; no engine needed.
export const fromITunes = (r) => ({
  key: `itunes:${r.id}`, kind: "itunes", service: "Apple Music", remoteId: r.id, title: r.title, subtitle: r.artist,
  album: r.album, art: r.art, url: r.preview_url, duration: 30, externalUrl: r.url, preview: true,
});

// ============================================================== YouTube Music

class YouTubeEngine extends Engine {
  get paused() { const s = this.yt?.getPlayerState?.(); return s !== 1 && s !== 3; }
  get currentTime() { return this.yt?.getCurrentTime?.() || 0; }
  get duration() { return this.yt?.getDuration?.() || this.item?.duration || 0; }

  _dock() {
    let dock = document.getElementById("yt-dock");
    if (!dock) {
      dock = Object.assign(document.createElement("div"), { id: "yt-dock", className: "yt-dock", hidden: true });
      dock.innerHTML = '<div id="yt-frame"></div>';
      document.body.append(dock);
    }
    return dock;
  }

  async _player(videoId, autoplay) {
    const dock = this._dock();
    dock.hidden = false;
    if (this.yt) {
      autoplay ? this.yt.loadVideoById({ videoId, startSeconds: this.item?.startAt || 0 }) : this.yt.cueVideoById(videoId);
      return;
    }
    const apiReady = new Promise((resolve) => {
      if (window.YT?.Player) return resolve();
      const prev = window.onYouTubeIframeAPIReady;
      window.onYouTubeIframeAPIReady = () => { prev?.(); resolve(); };
    });
    await loadScript("https://www.youtube.com/iframe_api");
    await apiReady;
    await new Promise((resolve) => {
      this.yt = new window.YT.Player("yt-frame", {
        width: "100%", height: "100%", videoId,
        playerVars: { autoplay: autoplay ? 1 : 0, playsinline: 1, rel: 0, start: Math.floor(this.item?.startAt || 0), origin: location.origin },
        events: {
          onReady: () => { this.yt.setVolume(Math.round((this._volume ?? 1) * 100)); resolve(); },
          onStateChange: ({ data }) => {
            if (!this.item) return;
            if (data === 0) { this._tickStop(); return this.notify("ended"); }
            data === 1 ? this._tickStart() : this._tickStop();
            this.notify("change");
          },
          onError: ({ data }) => this.notify("error", data === 101 || data === 150
            ? "The owner of this video doesn't allow it to play outside YouTube." : "YouTube couldn't play this video."),
        },
      });
    });
  }

  async load(item, autoplay) {
    this.item = item;
    this.pending = false;
    await this._player(item.remoteId, autoplay);
  }

  play() { this.yt?.playVideo(); }
  pause() { this.yt?.pauseVideo(); }
  stop() {
    this.item = null;
    this._tickStop();
    this.yt?.stopVideo?.();
    const dock = document.getElementById("yt-dock");
    if (dock) dock.hidden = true;
  }
  seek(t) { this.yt?.seekTo(t, true); }
  setVolume(v) { this._volume = v; this.yt?.setVolume?.(Math.round(v * 100)); }
}
export const youtubeEngine = new YouTubeEngine();

export const fromYouTube = (v) => ({
  key: `youtube:${v.id}`, kind: "youtube", provider: "youtube", service: "YouTube Music", remoteId: v.id,
  title: v.title, subtitle: v.artist, album: "", art: v.art, duration: v.duration, externalUrl: v.url,
});

export const engines = { spotify: spotifyEngine, apple: appleEngine, youtube: youtubeEngine };
