// Audio engine: queue, shuffle/repeat, Web Audio EQ + visualizer, Media Session
// (lock screen / hardware keys), offline blob playback, history + podcast sync.
import { api } from "./api.js";
import { db } from "./db.js";
import { engines } from "./streaming.js";

export const fromTrack = (t) => ({
  key: `track:${t.id}`, kind: "track", remoteId: t.id, title: t.title, subtitle: t.artist?.name || "",
  artistId: t.artist?.id, album: t.album?.title || "", albumId: t.album?.id, art: t.cover_url,
  url: t.stream_url, downloadUrl: t.download_url, duration: t.duration, liked: !!t.liked, owned: !!t.is_owner, mime: t.mime_type,
});
export const fromEpisode = (e) => ({
  key: `episode:${e.id}`, kind: "episode", remoteId: e.id, title: e.title, subtitle: e.podcast_title || "",
  podcastId: e.podcast, art: e.image || e.podcast_image, url: e.audio_url, downloadUrl: e.audio_url,
  duration: e.duration, startAt: e.completed ? 0 : e.position || 0, mime: e.mime_type,
});
export const fromStation = (s) => ({
  key: `station:${s.id}`, kind: "station", remoteId: s.id, title: s.name,
  subtitle: [s.state, ...(s.tags || []).slice(0, 2)].filter(Boolean).join(" · "), art: s.favicon || null, url: s.stream_url, live: true,
});

const EQ_FREQS = [60, 230, 910, 3600, 14000];
export const EQ_PRESETS = {
  Flat: [0, 0, 0, 0, 0], "Bass boost": [6, 4, 0, 0, 0], Amapiano: [7, 3, -1, 1, 3], Vocal: [-2, 0, 3, 4, 1],
  Treble: [0, 0, 0, 3, 6], Podcast: [-4, 0, 4, 3, -1], "Late night": [3, 1, 0, -2, -3],
};

class Player extends EventTarget {
  constructor() {
    super();
    // fx: same-origin & blob audio, routed through Web Audio (EQ + visualizer).
    // plain: cross-origin radio/podcasts that don't send CORS headers (Web Audio would mute them).
    this.fx = Object.assign(new Audio(), { preload: "auto", crossOrigin: "anonymous" });
    this.plain = Object.assign(new Audio(), { preload: "none" });
    this.audio = this.fx;
    this.items = [];
    this.order = [];
    this.pos = -1;
    this.shuffle = false;
    this.repeat = "off"; // off | all | one
    this.volume = +(localStorage.getItem("lipina.vol") ?? 1);
    this.muted = false;
    this.rate = 1;
    this.eqGains = JSON.parse(localStorage.getItem("lipina.eq") || "[0,0,0,0,0]");
    this.eqEnabled = localStorage.getItem("lipina.eqOn") === "1";
    this.lyrics = null;
    this.sleepAt = null;
    this.sleepEndOfTrack = false;
    this._objectUrl = null;
    this._listened = 0;
    this._lastTick = null;
    this.error = null;
    this.ext = null; // active streaming-service engine (Spotify / Apple Music / YouTube), if any
    for (const engine of Object.values(engines)) {
      engine.notify = (type, message) => {
        if (this.ext !== engine) return;
        if (type === "time") return this._onTime();
        if (type === "ended") return this._onEnded();
        if (type === "error") { this.error = message; return this._emit("error"); }
        this._emit();
      };
    }

    for (const a of [this.fx, this.plain]) {
      a.addEventListener("timeupdate", () => a === this.audio && this._onTime());
      a.addEventListener("play", () => a === this.audio && this._emit());
      a.addEventListener("pause", () => a === this.audio && (this._tickListen(), this._saveProgress(), this._emit()));
      a.addEventListener("ended", () => a === this.audio && this._onEnded());
      a.addEventListener("waiting", () => a === this.audio && this._emit("buffering"));
      a.addEventListener("playing", () => a === this.audio && this._emit());
      a.addEventListener("durationchange", () => a === this.audio && this._emit());
      a.addEventListener("error", () => a === this.audio && this._onError());
    }
    this._setupMediaSession();
    setInterval(() => this._saveProgress(), 20000);
    window.addEventListener("pagehide", () => { this._finish(false); this._persist(); });
    this._restore();
  }

  get current() { return this.pos >= 0 ? this.items[this.order[this.pos]] : null; }
  get playing() { return this.ext ? !this.ext.paused : !this.audio.paused; }
  get upNext() { return this.order.slice(this.pos + 1).map((i) => this.items[i]); }
  get currentTime() { return this.ext ? this.ext.currentTime : this.audio.currentTime || 0; }
  get duration() {
    if (this.ext) return this.ext.duration;
    const d = this.audio.duration;
    return isFinite(d) ? d : this.current?.duration || 0;
  }

  _emit(type = "change") { this.dispatchEvent(new Event(type)); if (type !== "change") this.dispatchEvent(new Event("change")); }

  // ---------------------------------------------------------- Web Audio
  _ensureGraph() {
    if (this.ctx) return this.ctx.state === "suspended" && this.ctx.resume();
    const Ctx = window.AudioContext || window.webkitAudioContext;
    if (!Ctx) return;
    this.ctx = new Ctx();
    const src = this.ctx.createMediaElementSource(this.fx);
    this.filters = EQ_FREQS.map((f, i) => {
      const b = this.ctx.createBiquadFilter();
      b.type = i === 0 ? "lowshelf" : i === EQ_FREQS.length - 1 ? "highshelf" : "peaking";
      b.frequency.value = f;
      b.Q.value = 1;
      return b;
    });
    this.analyser = this.ctx.createAnalyser();
    this.analyser.fftSize = 128;
    let node = src;
    for (const f of this.filters) { node.connect(f); node = f; }
    node.connect(this.analyser);
    this.analyser.connect(this.ctx.destination);
    this._applyEq();
  }

  _applyEq() {
    this.filters?.forEach((f, i) => { f.gain.value = this.eqEnabled ? this.eqGains[i] || 0 : 0; });
  }

  setEq(gains, enabled = this.eqEnabled) {
    this.eqGains = gains.slice(0, 5);
    this.eqEnabled = enabled;
    localStorage.setItem("lipina.eq", JSON.stringify(this.eqGains));
    localStorage.setItem("lipina.eqOn", enabled ? "1" : "0");
    this._applyEq();
    this._emit("eq");
  }

  // ------------------------------------------------------------ queue
  async playItems(items, start = 0, { shuffle } = {}) {
    if (!items.length) return;
    this._finish(false);
    this.items = items.map((i) => ({ ...i }));
    if (shuffle !== undefined) this.shuffle = shuffle;
    this.order = this.items.map((_, i) => i);
    if (this.shuffle) { this._reshuffle(start); this.pos = 0; } else this.pos = Math.min(start, items.length - 1);
    await this._load(true);
  }

  playNext(item) {
    if (!this.current) return this.playItems([item]);
    this.items.push({ ...item });
    this.order.splice(this.pos + 1, 0, this.items.length - 1);
    this._emit("queue");
  }

  addToQueue(item) {
    if (!this.current) return this.playItems([item]);
    this.items.push({ ...item });
    this.order.push(this.items.length - 1);
    this._emit("queue");
  }

  removeUpNext(i) { this.order.splice(this.pos + 1 + i, 1); this._emit("queue"); }
  jumpUpNext(i) { this._finish(false); this.pos = this.pos + 1 + i; this._load(true); }

  _reshuffle(first) {
    const rest = this.items.map((_, i) => i).filter((i) => i !== first);
    for (let i = rest.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [rest[i], rest[j]] = [rest[j], rest[i]]; }
    this.order = [first, ...rest];
  }

  toggleShuffle() {
    const cur = this.order[this.pos];
    this.shuffle = !this.shuffle;
    if (this.items.length) {
      if (this.shuffle) { this._reshuffle(cur); this.pos = 0; } else { this.order = this.items.map((_, i) => i); this.pos = cur; }
    }
    this._emit("queue");
  }

  cycleRepeat() { this.repeat = { off: "all", all: "one", one: "off" }[this.repeat]; this._emit(); }

  async _resolveUrl(item) {
    if (this._objectUrl) { URL.revokeObjectURL(this._objectUrl); this._objectUrl = null; }
    const stored = item.kind === "local" ? await db.get("local", item.key) : await db.get("downloads", item.key).catch(() => null);
    if (stored?.blob) {
      this._objectUrl = URL.createObjectURL(stored.blob);
      return { url: this._objectUrl, local: true };
    }
    return { url: item.url, local: false };
  }

  async _load(autoplay) {
    const item = this.current;
    if (!item) return;
    this.error = null;
    this.lyrics = null;
    this.nowPlaying = null;
    if (item.provider) return this._loadExternal(item, autoplay);
    if (this.ext) { this.ext.stop(); this.ext = null; }
    const { url, local } = await this._resolveUrl(item);
    if (item !== this.current) return; // superseded while resolving
    const sameOrigin = local || new URL(url, location.href).origin === location.origin;
    const next = sameOrigin ? this.fx : this.plain;
    if (next !== this.audio) { this.audio.pause(); this.audio.removeAttribute("src"); this.audio.load(); }
    this.audio = next;
    this.audio.src = url;
    this.audio.volume = this.muted ? 0 : this.volume;
    this.audio.playbackRate = item.live ? 1 : this.rate;
    this.audio.preservesPitch = true;
    if (item.startAt) {
      this.audio.addEventListener("loadedmetadata", () => { this.audio.currentTime = item.startAt; }, { once: true });
    }
    this._listened = 0;
    this._lastTick = null;
    this._updateMediaSession();
    this._persist();
    this._emit("track");
    if (item.live) this._pollNowPlaying();
    if (autoplay) await this.play();
  }

  async _loadExternal(item, autoplay) {
    const engine = engines[item.provider];
    this.audio.pause();
    if (this.ext && this.ext !== engine) this.ext.stop();
    this.ext = engine;
    engine.setVolume(this.muted ? 0 : this.volume);
    this._listened = 0;
    this._lastTick = null;
    this._updateMediaSession();
    this._persist();
    this._emit("track");
    try {
      await engine.load(item, autoplay);
    } catch (e) {
      if (item === this.current) { this.error = e.message; this._emit("error"); }
    }
  }

  async play() {
    if (!this.current) return;
    if (this.ext) {
      try { await this.ext.play(); } catch (e) { this.error = e.message; this._emit("error"); }
      return;
    }
    if (this.audio === this.fx) this._ensureGraph();
    try {
      if (!this.audio.src) await this._load(false);
      await this.audio.play();
    } catch (e) {
      if (e.name === "NotAllowedError") return this._emit(); // autoplay blocked; user must tap play
      if (e.name !== "AbortError") this._onError();
    }
  }

  pause() { this.ext ? this.ext.pause() : this.audio.pause(); }
  toggle() { this.playing ? this.pause() : this.play(); }
  seek(t) {
    if (this.current?.live) return;
    t = Math.max(0, Math.min(t, this.duration || t));
    this.ext ? this.ext.seek(t) : (this.audio.currentTime = t);
  }
  seekBy(d) { this.seek(this.currentTime + d); }

  async next(auto = false) {
    if (this.pos < this.order.length - 1) { this._finish(auto); this.pos++; return this._load(true); }
    if (this.repeat === "all" && this.order.length) { this._finish(auto); this.pos = 0; return this._load(true); }
    if (auto) { this._finish(true); this.ext ? this.ext.pause() : (this.audio.currentTime = 0); this._emit(); }
  }

  async prev() {
    if (this.currentTime > 3 || this.pos <= 0) return this.seek(0);
    this._finish(false);
    this.pos--;
    return this._load(true);
  }

  setVolume(v) {
    this.volume = Math.max(0, Math.min(1, v));
    this.muted = this.volume === 0;
    this.audio.volume = this.volume;
    this.ext?.setVolume(this.volume);
    localStorage.setItem("lipina.vol", this.volume);
    this._emit("volume");
  }
  toggleMute() {
    this.muted = !this.muted;
    this.audio.volume = this.muted ? 0 : this.volume;
    this.ext?.setVolume(this.muted ? 0 : this.volume);
    this._emit("volume");
  }
  setRate(r) { this.rate = r; if (!this.current?.live && !this.ext) this.audio.playbackRate = r; this._emit(); }

  _onTime() {
    this._tickListen();
    if (this.sleepAt && Date.now() >= this.sleepAt) this._sleepNow();
    this._emit("time");
  }

  _onEnded() {
    if (this.sleepEndOfTrack) { this.sleepEndOfTrack = false; this._finish(true); return this._emit(); }
    if (this.repeat === "one") { this._finish(true); this.seek(0); return this.play(); }
    this.next(true);
  }

  _onError() {
    const item = this.current;
    if (!item) return;
    const insecure = location.protocol === "https:" && item.url?.startsWith("http:");
    this.error = insecure
      ? "This station only streams over http, which browsers block on secure sites. Try the Lipina mobile app."
      : `Couldn't play "${item.title}"${navigator.onLine ? "" : " — you're offline and it isn't downloaded"}`;
    this._emit("error");
    if (!item.live && this.pos < this.order.length - 1) setTimeout(() => this.error && this.next(), 1500);
  }

  // --------------------------------------------------------- sync & history
  _tickListen() {
    const now = performance.now();
    if (this.playing && this._lastTick != null) this._listened += (now - this._lastTick) / 1000;
    this._lastTick = this.playing ? now : null;
  }

  _finish(completed) {
    const item = this.current;
    if (!item) return;
    this._tickListen();
    if (item.kind === "episode") this._saveProgress(completed);
    if (item.kind === "track" && (completed || this._listened >= 30)) {
      api.enqueue("/api/history/", {
        track: item.remoteId, seconds: Math.round(this._listened), played_at: new Date().toISOString(),
        source: this._objectUrl ? "offline" : "library",
      }).catch(() => {});
    }
    this._listened = 0;
  }

  _saveProgress(completed = false) {
    const item = this.current;
    if (!item || item.kind !== "episode") return;
    const position = Math.round(completed ? item.duration || this.currentTime : this.currentTime);
    if (position > 0) api.enqueue(`/api/podcasts/episodes/${item.remoteId}/progress/`, { position, completed }).catch(() => {});
  }

  _persist() {
    try {
      localStorage.setItem("lipina.queue", JSON.stringify({
        items: this.items.filter((i) => i.kind !== "local").slice(0, 500), order: this.order, pos: this.pos,
        t: this.current?.live ? 0 : this.currentTime, shuffle: this.shuffle, repeat: this.repeat,
      }));
    } catch { /* quota */ }
  }

  _restore() {
    try {
      const s = JSON.parse(localStorage.getItem("lipina.queue") || "null");
      if (!s?.items?.length || s.order.length !== s.items.length) return;
      Object.assign(this, { items: s.items, order: s.order, pos: s.pos, shuffle: s.shuffle, repeat: s.repeat });
      if (this.current && s.t) this.current.startAt = s.t;
      this._load(false);
    } catch { /* ignore corrupt state */ }
  }

  // ------------------------------------------------------- radio metadata
  async _pollNowPlaying() {
    const item = this.current;
    clearTimeout(this._npTimer);
    if (!item?.live) return;
    try {
      const np = await api.get(`/api/radio/stations/${item.remoteId}/now-playing/`);
      if (item === this.current && np?.raw) { this.nowPlaying = np; this._updateMediaSession(); this._emit(); }
    } catch { /* ignore */ }
    if (item === this.current) this._npTimer = setTimeout(() => this._pollNowPlaying(), 30000);
  }

  // --------------------------------------------------------------- lyrics
  async loadLyrics() {
    const item = this.current;
    if (!item || item.live || item.kind === "episode") return (this.lyrics = { none: true });
    if (this.lyrics && !this.lyrics.none && this.lyrics.key === item.key) return this.lyrics;
    const q = item.kind === "track" ? { track: item.remoteId } : { title: item.title, artist: item.subtitle, duration: Math.round(item.duration || 0) };
    try {
      const d = await api.get("/api/lyrics/", q);
      this.lyrics = { key: item.key, plain: d.plain, synced: parseLrc(d.synced || "") };
    } catch {
      this.lyrics = { key: item.key, none: true };
    }
    this._emit("lyrics");
    return this.lyrics;
  }

  // ---------------------------------------------------------------- sleep
  setSleep(minutes, endOfTrack = false) {
    clearInterval(this._fade);
    this.sleepAt = minutes ? Date.now() + minutes * 60000 : null;
    this.sleepEndOfTrack = endOfTrack;
    this._emit();
  }

  _sleepNow() {
    this.sleepAt = null;
    if (this.ext) { this.pause(); return this._emit(); }
    const start = this.audio.volume;
    let v = start;
    clearInterval(this._fade);
    this._fade = setInterval(() => {
      v -= start / 20;
      if (v <= 0) { clearInterval(this._fade); this.pause(); this.audio.volume = this.muted ? 0 : this.volume; this._emit(); }
      else this.audio.volume = v;
    }, 400);
  }

  // -------------------------------------------------------- media session
  _setupMediaSession() {
    if (!("mediaSession" in navigator)) return;
    const ms = navigator.mediaSession;
    const set = (a, fn) => { try { ms.setActionHandler(a, fn); } catch { /* unsupported */ } };
    set("play", () => this.play());
    set("pause", () => this.pause());
    set("previoustrack", () => this.prev());
    set("nexttrack", () => this.next());
    set("seekbackward", (d) => this.seekBy(-(d.seekOffset || 15)));
    set("seekforward", (d) => this.seekBy(d.seekOffset || 30));
    set("seekto", (d) => this.seek(d.seekTime));
    set("stop", () => this.pause());
  }

  _updateMediaSession() {
    const item = this.current;
    if (!item || !("mediaSession" in navigator)) return;
    const title = this.nowPlaying?.raw || item.title;
    navigator.mediaSession.metadata = new MediaMetadata({
      title, artist: this.nowPlaying?.raw ? item.title : item.subtitle, album: item.album || (item.live ? "Live radio" : ""),
      artwork: item.art ? [{ src: item.art, sizes: "512x512" }] : [],
    });
  }
}

export function parseLrc(lrc) {
  const out = [];
  const tag = /\[(\d+):(\d+(?:\.\d+)?)\]/g;
  for (const line of lrc.split("\n")) {
    const stamps = [...line.matchAll(tag)];
    if (!stamps.length) continue;
    const text = line.slice(stamps.at(-1).index + stamps.at(-1)[0].length).trim();
    for (const m of stamps) out.push({ t: +m[1] * 60 + +m[2], text });
  }
  return out.sort((a, b) => a.t - b.t);
}

export const player = new Player();
