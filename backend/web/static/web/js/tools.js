// Study & practice tools, all generated with Web Audio (no assets, works offline):
// Pomodoro focus timer, ambient noise, sample-accurate metronome, chromatic tuner.
import { player } from "./player.js";

let ctx;
const audioCtx = () => (ctx ??= new (window.AudioContext || window.webkitAudioContext)());

// ------------------------------------------------------------- ambient noise

function noiseBuffer(type, seconds = 8) {
  const c = audioCtx();
  const n = c.sampleRate * seconds;
  const buf = c.createBuffer(1, n, c.sampleRate);
  const d = buf.getChannelData(0);
  let b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0, b6 = 0, brown = 0;
  for (let i = 0; i < n; i++) {
    const w = Math.random() * 2 - 1;
    let v;
    if (type === "white") v = w * 0.3;
    else if (type === "pink" || type === "rain") {
      b0 = 0.99886 * b0 + w * 0.0555179; b1 = 0.99332 * b1 + w * 0.0750759; b2 = 0.969 * b2 + w * 0.153852;
      b3 = 0.8665 * b3 + w * 0.3104856; b4 = 0.55 * b4 + w * 0.5329522; b5 = -0.7616 * b5 - w * 0.016898;
      v = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362) * 0.08; b6 = w * 0.115926;
      if (type === "rain" && Math.random() < 0.0008) v += (Math.random() - 0.5) * 0.8;
    } else {
      brown = (brown + 0.02 * w) / 1.02; v = brown * 3.2;
      if (type === "ocean") v *= 0.35 + 0.65 * Math.sin((Math.PI * i) / n) ** 2;
    }
    const edge = Math.min(i, n - i) / (c.sampleRate * 0.2);
    d[i] = edge < 1 ? v * edge : v;
  }
  return buf;
}

export const noise = {
  type: null, volume: 0.5, _src: null, _gain: null, _cache: {},
  set(type) {
    this._src?.stop();
    this._src = null;
    this.type = type;
    if (!type) return;
    const c = audioCtx();
    c.resume();
    if (!this._gain) { this._gain = c.createGain(); this._gain.connect(c.destination); }
    this._gain.gain.value = this.volume;
    const src = c.createBufferSource();
    src.buffer = this._cache[type] ??= noiseBuffer(type, type === "ocean" ? 16 : 8);
    src.loop = true;
    src.connect(this._gain);
    src.start();
    this._src = src;
  },
  setVolume(v) { this.volume = v; if (this._gain) this._gain.gain.value = v; },
};

// --------------------------------------------------------------- metronome
// Lookahead scheduler: clicks are scheduled on the audio clock, so timing never drifts.

export const metronome = {
  bpm: 100, beats: 4, on: false, onBeat: null, _next: 0, _beat: 0, _timer: null,
  start() {
    const c = audioCtx();
    c.resume();
    this.on = true;
    this._beat = 0;
    this._next = c.currentTime + 0.06;
    this._timer = setInterval(() => this._schedule(), 25);
  },
  stop() { this.on = false; clearInterval(this._timer); },
  toggle() { this.on ? this.stop() : this.start(); },
  _schedule() {
    const c = audioCtx();
    while (this._next < c.currentTime + 0.12) {
      const accent = this._beat % this.beats === 0;
      const osc = c.createOscillator();
      const g = c.createGain();
      osc.frequency.value = accent ? 1600 : 1000;
      g.gain.setValueAtTime(0.8, this._next);
      g.gain.exponentialRampToValueAtTime(0.001, this._next + 0.04);
      osc.connect(g).connect(c.destination);
      osc.start(this._next);
      osc.stop(this._next + 0.05);
      const beat = this._beat % this.beats;
      const delay = (this._next - c.currentTime) * 1000;
      setTimeout(() => this.onBeat?.(beat, accent), Math.max(0, delay));
      this._next += 60 / this.bpm;
      this._beat++;
    }
  },
  _taps: [],
  tap() {
    const now = performance.now();
    if (this._taps.length && now - this._taps.at(-1) > 2000) this._taps = [];
    this._taps.push(now);
    if (this._taps.length > 8) this._taps.shift();
    if (this._taps.length < 2) return null;
    const gaps = this._taps.slice(1).map((t, i) => t - this._taps[i]);
    return Math.round(60000 / (gaps.reduce((a, b) => a + b) / gaps.length));
  },
};

// ------------------------------------------------------------- focus timer

export const focus = {
  focusMin: +(localStorage.getItem("lipina.focusMin") || 25), shortMin: 5, longMin: 15, pauseMusic: true,
  phase: "idle", remaining: 0, sessions: +(sessionStorage.getItem("lipina.sessions") || 0), paused: false,
  onTick: null, _t: null, _endAt: 0,
  total() { return 60 * ({ focus: this.focusMin, short: this.shortMin, long: this.longMin, idle: this.focusMin })[this.phase]; },
  start() { this._enter("focus"); },
  stop() { clearInterval(this._t); this.phase = "idle"; this.remaining = 0; this.onTick?.(); },
  togglePause() {
    this.paused = !this.paused;
    if (!this.paused) this._endAt = Date.now() + this.remaining * 1000;
    this.onTick?.();
  },
  _enter(phase) {
    this.phase = phase;
    this.paused = false;
    this.remaining = this.total();
    this._endAt = Date.now() + this.remaining * 1000;
    if (this.pauseMusic && player.current) {
      if (phase === "focus" && !player.playing) player.play();
      if (phase !== "focus" && player.playing) player.pause();
    }
    clearInterval(this._t);
    this._t = setInterval(() => this._tick(), 250);
    this.onTick?.();
  },
  _tick() {
    if (this.paused) return;
    this.remaining = Math.max(0, Math.round((this._endAt - Date.now()) / 1000));
    if (this.remaining <= 0) {
      chime();
      notify(this.phase === "focus" ? "Focus session done — take a break" : "Break over — back to it");
      if (this.phase === "focus") {
        this.sessions++;
        sessionStorage.setItem("lipina.sessions", this.sessions);
        this._enter(this.sessions % 4 === 0 ? "long" : "short");
      } else this._enter("focus");
      return;
    }
    this.onTick?.();
  },
};

function chime() {
  const c = audioCtx();
  c.resume();
  [880, 1320].forEach((f, i) => {
    const o = c.createOscillator();
    const g = c.createGain();
    o.frequency.value = f;
    g.gain.setValueAtTime(0.3 / (i + 1), c.currentTime);
    g.gain.exponentialRampToValueAtTime(0.001, c.currentTime + 1.4);
    o.connect(g).connect(c.destination);
    o.start();
    o.stop(c.currentTime + 1.5);
  });
}

function notify(text) {
  if ("Notification" in window && Notification.permission === "granted" && document.hidden) {
    new Notification("Lipina focus", { body: text, icon: window.LIPINA.static + "icons/icon.svg" });
  }
}

// ---------------------------------------------------------------- tuner
// Autocorrelation pitch detection on the microphone signal.

const NOTES = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"];

function detectPitch(buf, rate) {
  let rms = 0;
  for (const v of buf) rms += v * v;
  if (Math.sqrt(rms / buf.length) < 0.01) return null;
  const n = buf.length;
  let best = -1, bestCorr = 0;
  const corr = new Float32Array(n / 2);
  for (let lag = 20; lag < n / 2; lag++) {
    let s = 0;
    for (let i = 0; i < n / 2; i++) s += buf[i] * buf[i + lag];
    corr[lag] = s;
    if (s > bestCorr) { bestCorr = s; best = lag; }
  }
  if (best < 0) return null;
  // parabolic interpolation around the peak
  const [a, b, c] = [corr[best - 1] || 0, corr[best], corr[best + 1] || 0];
  const shift = (a - c) / (2 * (a - 2 * b + c) || 1);
  return rate / (best + shift);
}

export const tuner = {
  running: false, onPitch: null, _stream: null, _raf: 0,
  async start() {
    const c = audioCtx();
    await c.resume();
    this._stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: false, noiseSuppression: false } });
    const src = c.createMediaStreamSource(this._stream);
    const an = c.createAnalyser();
    an.fftSize = 2048;
    src.connect(an);
    const buf = new Float32Array(an.fftSize);
    this.running = true;
    const loop = () => {
      if (!this.running) return;
      an.getFloatTimeDomainData(buf);
      const f = detectPitch(buf, c.sampleRate);
      if (f && f > 50 && f < 2000) {
        const midi = 69 + 12 * Math.log2(f / 440);
        const nearest = Math.round(midi);
        this.onPitch?.({ freq: f, note: NOTES[(nearest % 12 + 12) % 12], octave: Math.floor(nearest / 12) - 1, cents: Math.round((midi - nearest) * 100) });
      }
      this._raf = requestAnimationFrame(loop);
    };
    loop();
  },
  stop() {
    this.running = false;
    cancelAnimationFrame(this._raf);
    this._stream?.getTracks().forEach((t) => t.stop());
  },
};
