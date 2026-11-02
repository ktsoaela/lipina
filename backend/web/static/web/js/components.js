// Reusable UI pieces: track tables, cards, item menus, playlist picker.
import { api } from "./api.js";
import { download, isDownloaded, progress, removeDownload } from "./offline.js";
import { fromTrack, player } from "./player.js";
import { $$, fmtTime, html, icon, img, menu, modal, prompt, toast } from "./ui.js";

export const navigate = (path) => window.dispatchEvent(new CustomEvent("lipina:navigate", { detail: path }));

/** Track table. `items` are player items; `tracks` (optional) the raw API tracks. */
export function trackTable(items, { album = true, numbered = true, removable = null } = {}) {
  const cur = player.current?.key;
  return html`<table class="tracks" data-tracks>
    <thead><tr><th>#</th><th>Title</th>${album ? html`<th class="col-album">Album</th>` : ""}<th class="col-dur">⏱</th><th></th></tr></thead>
    <tbody>${items.map((it, i) => html`<tr class="tr ${cur === it.key ? "playing" : ""}" data-i="${i}" data-key="${it.key}" tabindex="0">
      <td>${numbered ? i + 1 : ""}</td>
      <td><div class="tcell">${img(it.art, "")}<div style="min-width:0"><div class="tt">${it.title}</div>
        <div class="ts">${isDownloaded(it.key) || it.kind === "local" ? html`<span class="dl-dot" title="Available offline">●</span> ` : ""}${it.artistId ? html`<a href="/artist/${it.artistId}" data-link>${it.subtitle}</a>` : it.subtitle}</div></div></div></td>
      ${album ? html`<td class="col-album">${it.albumId ? html`<a href="/album/${it.albumId}" data-link>${it.album}</a>` : it.album}</td>` : ""}
      <td class="col-dur muted">${it.duration ? fmtTime(it.duration) : ""}</td>
      <td><button class="icon-btn" data-more aria-label="More">${icon("more")}</button>${removable ? html`<button class="icon-btn" data-remove title="Remove" aria-label="Remove">${icon("close")}</button>` : ""}</td>
    </tr>`)}</tbody></table>`;
}

/** Wire up a rendered track table: click/Enter to play, ⋮ menu, optional remove. */
export function bindTrackTable(root, items, { onRemove, playAll } = {}) {
  root.querySelectorAll("[data-tracks]").forEach((table) => {
    table.addEventListener("click", (e) => {
      const tr = e.target.closest("tr[data-i]");
      if (!tr || e.target.closest("a")) return;
      const i = +tr.dataset.i;
      if (e.target.closest("[data-more]")) return itemMenu(e.target.closest("[data-more]"), items[i]);
      if (e.target.closest("[data-remove]")) return onRemove?.(items[i], i);
      (playAll || ((start) => player.playItems(items, start)))(i);
    });
    table.addEventListener("keydown", (e) => {
      const tr = e.target.closest("tr[data-i]");
      if (tr && e.key === "Enter") player.playItems(items, +tr.dataset.i);
    });
    table.addEventListener("contextmenu", (e) => {
      const tr = e.target.closest("tr[data-i]");
      if (!tr) return;
      e.preventDefault();
      itemMenu(e, items[+tr.dataset.i]);
    });
  });
}

/** Refresh "playing" highlight without re-rendering. */
export function markPlaying(root = document) {
  const key = player.current?.key;
  $$("[data-key]", root).forEach((el) => el.classList.toggle("playing", el.dataset.key === key));
}

export function card({ title, sub, art, href, round = false, play = false, idx = "" }) {
  return html`<div class="card ${round ? "round" : ""}" data-idx="${idx}" ${href ? html`data-href="${href}"` : ""} tabindex="0">
    ${img(art)}${play ? html`<button class="hover-play" data-play aria-label="Play">${icon("play")}</button>` : ""}
    <div class="t">${title}</div>${sub ? html`<div class="s">${sub}</div>` : ""}</div>`;
}

export function bindCards(root) {
  root.addEventListener("click", (e) => {
    const c = e.target.closest(".card[data-href]");
    if (c && !e.target.closest("[data-play]")) navigate(c.dataset.href);
  });
  root.addEventListener("keydown", (e) => {
    const c = e.target.closest(".card[data-href]");
    if (c && e.key === "Enter") navigate(c.dataset.href);
  });
}

export function itemMenu(anchor, item) {
  const isTrack = item.kind === "track";
  const canDownload = isTrack || item.kind === "episode";
  menu(anchor, [
    { label: "Play next", icon: "queue", onClick: () => { player.playNext(item); toast("Playing next"); } },
    { label: "Add to queue", icon: "queue", onClick: () => { player.addToQueue(item); toast("Added to queue"); } },
    isTrack && { label: item.liked ? "Remove from Liked Songs" : "Like", icon: item.liked ? "heart" : "heartO", onClick: () => toggleLike(item) },
    isTrack && { label: "Add to playlist", icon: "add", onClick: () => addToPlaylist([item.remoteId]) },
    isTrack && { label: "Start track radio", icon: "radio", onClick: () => trackRadio(item.remoteId) },
    item.artistId && { label: "Go to artist", icon: "person", onClick: () => navigate(`/artist/${item.artistId}`) },
    item.albumId && { label: "Go to album", icon: "album", onClick: () => navigate(`/album/${item.albumId}`) },
    canDownload && (isDownloaded(item.key)
      ? { label: "Remove download", icon: "close", onClick: () => removeDownload(item.key).then(() => toast("Removed from downloads")) }
      : { label: progress.has(item.key) ? "Downloading…" : "Download", icon: "download", onClick: () => download(item).then(() => toast(`Saved "${item.title}" for offline`), (e) => toast(e.message)) }),
    isTrack && { label: "Share", icon: "upload", onClick: () => share(item) },
    item.externalUrl && { label: `Open in ${item.service}`, icon: "cast", onClick: () => window.open(item.externalUrl, "_blank", "noopener") },
  ]);
}

export async function toggleLike(item) {
  const next = !item.liked;
  item.liked = next;
  if (player.current?.key === item.key) player.current.liked = next;
  player.dispatchEvent(new Event("change"));
  try {
    next ? await api.post(`/api/tracks/${item.remoteId}/like/`) : await api.del(`/api/tracks/${item.remoteId}/like/`);
    toast(next ? "Added to Liked Songs" : "Removed from Liked Songs");
  } catch (e) {
    item.liked = !next;
    player.dispatchEvent(new Event("change"));
    toast(e.message);
  }
}

export async function trackRadio(trackId) {
  try {
    const list = await api.get(`/api/tracks/${trackId}/radio/`);
    player.playItems(list.map(fromTrack));
    toast("Track radio started");
  } catch (e) { toast(e.message); }
}

async function share(item) {
  const text = `${item.title} — ${item.subtitle} on Lipina`;
  const url = `${location.origin}/search?q=${encodeURIComponent(item.title)}`;
  try {
    if (navigator.share) await navigator.share({ title: item.title, text, url });
    else { await navigator.clipboard.writeText(`${text} ${url}`); toast("Link copied"); }
  } catch { /* cancelled */ }
}

export async function addToPlaylist(trackIds) {
  let playlists = [];
  try { playlists = await api.list("/api/playlists/"); } catch (e) { return toast(e.message); }
  modal(html`<h3>Add to playlist</h3>
    <div class="list-item" data-new>${icon("add")}<div class="meta"><div class="tt">New playlist</div></div></div>
    ${playlists.map((p) => html`<div class="list-item" data-id="${p.id}">${img(p.cover_url)}<div class="meta"><div class="tt">${p.name}</div><div class="ts">${p.track_count} songs</div></div></div>`)}`, {
    onMount(m, close) {
      m.addEventListener("click", async (e) => {
        const row = e.target.closest(".list-item");
        if (!row) return;
        let id = row.dataset.id, name = row.querySelector(".tt").textContent;
        close();
        try {
          if (row.dataset.new !== undefined) {
            name = await prompt("New playlist", { placeholder: "My playlist", ok: "Create" });
            if (!name) return;
            id = (await api.post("/api/playlists/", { name })).id;
            window.dispatchEvent(new Event("lipina:playlists"));
          }
          await api.post(`/api/playlists/${id}/tracks/`, { track_ids: trackIds });
          toast(`Added to ${name}`);
        } catch (err) { toast(err.message); }
      });
    },
  });
}

export function hero({ kind, title, sub, art, extra = "" }) {
  return html`<div class="hero">${img(art)}<div><div class="kind">${kind}</div><h1>${title}</h1><div class="muted">${sub}</div>${extra}</div></div>`;
}
