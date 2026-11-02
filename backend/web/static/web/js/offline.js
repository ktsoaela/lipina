// Downloads (server tracks / podcast episodes saved as blobs) and local files
// (music picked from this computer, playable with no account or network).
import { api } from "./api.js";
import { db, requestPersistence } from "./db.js";

const listeners = new Set();
export const progress = new Map(); // key -> 0..1
let downloadedKeys = new Set();

const notify = () => listeners.forEach((fn) => fn());
export const onOfflineChange = (fn) => { listeners.add(fn); return () => listeners.delete(fn); };

export async function refreshKeys() {
  downloadedKeys = new Set(await db.keys("downloads").catch(() => []));
  notify();
}
export const isDownloaded = (key) => downloadedKeys.has(key);

export async function download(item) {
  if (item.live || item.kind === "local" || isDownloaded(item.key) || progress.has(item.key)) return;
  await requestPersistence();
  progress.set(item.key, 0);
  notify();
  try {
    const res = await fetch(item.downloadUrl || item.url, { mode: "cors" });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const total = +res.headers.get("Content-Length") || 0;
    const reader = res.body.getReader();
    const chunks = [];
    let got = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(value);
      got += value.length;
      if (total) { progress.set(item.key, got / total); notify(); }
    }
    const blob = new Blob(chunks, { type: res.headers.get("Content-Type") || item.mime || "audio/mpeg" });
    const { url, downloadUrl, ...meta } = item; // signed URLs expire; keep metadata only
    await db.put("downloads", { key: item.key, item: { ...meta, url: "" }, blob, size: blob.size, savedAt: Date.now() });
    downloadedKeys.add(item.key);
  } catch (e) {
    const cors = e instanceof TypeError;
    throw new Error(cors && item.kind === "episode"
      ? "This podcast host doesn't allow saving from browsers. Use the Lipina mobile app to download it."
      : `Download failed: ${e.message}`);
  } finally {
    progress.delete(item.key);
    notify();
  }
}

export async function downloadAll(items, onEach) {
  let ok = 0;
  for (const it of items) {
    try { await download(it); ok++; } catch { /* keep going */ }
    onEach?.(ok);
  }
  return ok;
}

export async function removeDownload(key) {
  await db.del("downloads", key);
  downloadedKeys.delete(key);
  notify();
}

export async function listDownloads() {
  return (await db.all("downloads")).sort((a, b) => b.savedAt - a.savedAt);
}

// ------------------------------------------------------------ local files

const AUDIO_EXT = /\.(mp3|m4a|aac|flac|ogg|oga|opus|wav|webm)$/i;

function guessMeta(name) {
  let stem = name.replace(/\.[^.]+$/, "").replace(/_/g, " ").replace(/^\d+[\s._-]+/, "").trim();
  const i = stem.indexOf(" - ");
  return i > 0 ? { title: stem.slice(i + 3).trim(), subtitle: stem.slice(0, i).trim() } : { title: stem, subtitle: "On this computer" };
}

async function probeDuration(blob) {
  return new Promise((resolve) => {
    const a = new Audio();
    const url = URL.createObjectURL(blob);
    const done = (d) => { URL.revokeObjectURL(url); resolve(d); };
    a.preload = "metadata";
    a.onloadedmetadata = () => done(isFinite(a.duration) ? a.duration : 0);
    a.onerror = () => done(0);
    a.src = url;
    setTimeout(() => done(0), 4000);
  });
}

export async function importLocalFiles(files) {
  await requestPersistence();
  let added = 0;
  for (const f of files) {
    if (!AUDIO_EXT.test(f.name)) continue;
    const key = `local:${f.name}:${f.size}`;
    if (await db.get("local", key)) continue;
    const duration = await probeDuration(f);
    const item = { key, kind: "local", ...guessMeta(f.name), album: "", art: null, url: "", duration, filename: f.name };
    await db.put("local", { key, item, blob: f, addedAt: Date.now() });
    added++;
  }
  notify();
  return added;
}

export async function listLocal() {
  return (await db.all("local")).sort((a, b) => a.item.title.localeCompare(b.item.title));
}

export async function removeLocal(key) {
  await db.del("local", key);
  notify();
}

export async function uploadLocalToCloud(key, onProgress) {
  const rec = await db.get("local", key);
  const fd = new FormData();
  fd.append("file", new File([rec.blob], rec.item.filename || "track.mp3"));
  return api.upload("/api/tracks/", fd, onProgress);
}

refreshKeys();
