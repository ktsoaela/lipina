// Page views. Each view renders into `el` and may return a cleanup function.
import { api, auth } from "./api.js";
import { storageEstimate } from "./db.js";
import { bindCards, bindTrackTable, card, hero, itemMenu, markPlaying, navigate, trackTable } from "./components.js";
import {
  downloadAll, importLocalFiles, isDownloaded, listDownloads, listLocal, removeDownload, removeLocal, uploadLocalToCloud,
} from "./offline.js";
import { EQ_PRESETS, fromEpisode, fromStation, fromTrack, player } from "./player.js";
import { focus, metronome, noise, tuner } from "./tools.js";
import {
  $, $$, confirmDialog, debounce, empty, fmtLong, fmtTime, html, icon, img, menu, modal, prompt, setRangeFill, skeletonGrid, toast,
} from "./ui.js";

const set = (el, content) => { el.innerHTML = content.s ?? content; };
const errorView = (el, e, retry) => {
  set(el, empty("wave", "Couldn't load this page", e.message, html`<button class="btn" data-retry>Retry</button>`));
  el.querySelector("[data-retry]")?.addEventListener("click", retry);
};

// ------------------------------------------------------------------ auth

export function loginView(el) {
  let mode = "login";
  const draw = () => {
    set(el, html`<div class="auth"><form novalidate>
      <div style="text-align:center;color:var(--accent)">${icon("wave", "i")}</div>
      <h1>${mode === "login" ? "Welcome back" : "Join Lipina"}</h1>
      <p class="muted" style="text-align:center;margin-top:-8px">Music · South African radio · Podcasts · Focus</p>
      <div class="field"><label for="u">Username</label><input class="input" id="u" name="username" autocomplete="username" required></div>
      ${mode === "register" ? html`<div class="field"><label for="e">Email (optional)</label><input class="input" id="e" name="email" type="email" autocomplete="email"></div>` : ""}
      <div class="field"><label for="p">Password</label><input class="input" id="p" name="password" type="password" autocomplete="${mode === "login" ? "current-password" : "new-password"}" required minlength="${mode === "login" ? 1 : 8}"></div>
      <div class="error" data-err></div>
      <button class="btn primary" style="width:100%;justify-content:center;padding:14px">${mode === "login" ? "Log in" : "Create account"}</button>
      <p style="text-align:center"><a href="#" data-toggle class="muted">${mode === "login" ? "New here? Create an account" : "Have an account? Log in"}</a></p>
    </form></div>`);
    $("[data-toggle]", el).onclick = (e) => { e.preventDefault(); mode = mode === "login" ? "register" : "login"; draw(); };
    $("form", el).onsubmit = async (e) => {
      e.preventDefault();
      const f = new FormData(e.target);
      const btn = $("button.primary", el);
      btn.disabled = true;
      try {
        if (mode === "login") await auth.login(f.get("username"), f.get("password"));
        else await auth.register(f.get("username"), f.get("email") || "", f.get("password"));
        window.dispatchEvent(new Event("lipina:login"));
      } catch (err) {
        $("[data-err]", el).textContent = err.message;
        btn.disabled = false;
      }
    };
    $("#u", el).focus();
  };
  draw();
}

// ------------------------------------------------------------------ home

export async function homeView(el) {
  set(el, html`<h1>&nbsp;</h1>${skeletonGrid(6)}`);
  let d;
  try { d = await api.get("/api/home/"); } catch (e) { return errorView(el, e, () => homeView(el)); }
  const sections = [];
  const rows = {};
  const trackRow = (key, title, list) => {
    if (!list?.length) return;
    const items = list.map(fromTrack);
    rows[key] = items;
    sections.push(html`<section><div class="section-head"><h2>${title}</h2></div><div class="scroller">
      ${items.map((it, i) => card({ title: it.title, sub: it.subtitle, art: it.art, play: true, idx: `${key}:${i}` }))}</div></section>`);
  };
  trackRow("mix", "Your daily mix", d.daily_mix);
  trackRow("recent", "Recently played", d.recently_played);
  if (d.playlists?.length) {
    sections.push(html`<section><div class="section-head"><h2>Your playlists</h2><a href="/library" data-link>Show all</a></div><div class="scroller">
      ${d.playlists.map((p) => card({ title: p.name, sub: `${p.track_count} songs`, art: p.cover_url, href: `/playlist/${p.id}` }))}</div></section>`);
  }
  trackRow("top", "On repeat", d.top_tracks);
  if (d.albums?.length) {
    sections.push(html`<section><div class="section-head"><h2>Albums</h2></div><div class="scroller">
      ${d.albums.map((a) => card({ title: a.title, sub: a.artist?.name, art: a.cover_url, href: `/album/${a.id}` }))}</div></section>`);
  }
  trackRow("new", "Fresh in your library", d.new_uploads);
  trackRow("popular", "Popular on Lipina", d.popular);
  const isEmpty = !d.recently_played?.length && !d.new_uploads?.length && !d.popular?.length;

  set(el, html`<h1>${d.greeting}${auth.user?.display_name ? `, ${auth.user.display_name}` : ""}</h1>
    <div class="quick">
      <a href="/liked" data-link><span class="q-ico">${icon("heart")}</span>Liked Songs</a>
      <a href="/radio" data-link><span class="q-ico">${icon("radio")}</span>South African Radio</a>
      <a href="/recognize" data-link><span class="q-ico">${icon("wave")}</span>Identify a song</a>
      <a href="/tools" data-link><span class="q-ico">${icon("focus")}</span>Focus session</a>
      <button data-shuffle-all><span class="q-ico">${icon("shuffle")}</span>Shuffle my library</button>
      <a href="/library?tab=upload" data-link><span class="q-ico">${icon("upload")}</span>Upload music</a>
    </div>
    ${isEmpty ? empty("library", "Let's fill your library", "Upload your music, drop in files from this computer, or tune into live South African radio.",
      html`<a class="btn primary" href="/library?tab=upload" data-link>Upload music</a> <a class="btn" href="/radio" data-link>Browse radio</a>`) : ""}
    ${sections}`);
  bindCards(el);
  el.addEventListener("click", (e) => {
    const c = e.target.closest(".card[data-idx]");
    if (!c || !c.dataset.idx || c.dataset.href) return;
    const [key, i] = c.dataset.idx.split(":");
    player.playItems(rows[key], +i);
  });
  el.addEventListener("contextmenu", (e) => {
    const c = e.target.closest(".card[data-idx]");
    if (!c?.dataset.idx || c.dataset.href) return;
    e.preventDefault();
    const [key, i] = c.dataset.idx.split(":");
    itemMenu(e, rows[key][+i]);
  });
  $("[data-shuffle-all]", el).onclick = async () => {
    const list = await api.list("/api/tracks/", { limit: 300 }).catch(() => []);
    if (!list.length) return toast("Your library is empty");
    player.playItems(list.map(fromTrack), 0, { shuffle: true });
  };
}

// ---------------------------------------------------------------- search

export async function searchView(el, _params, query) {
  set(el, html`<h1>Search</h1><input class="input" type="search" placeholder="What do you want to listen to?" value="${query.get("q") || ""}" data-q autofocus>
    <div data-results style="margin-top:20px"></div>`);
  const input = $("[data-q]", el);
  const out = $("[data-results]", el);
  let ctrl;

  const browse = async () => {
    const genres = await api.get("/api/tracks/genres/").catch(() => []);
    const colors = ["#e13300", "#1e3264", "#8400e7", "#e8115b", "#148a08", "#bc5900", "#509bf5", "#477d95", "#af2896", "#0d73ec"];
    set(out, html`<h2>Browse</h2><div class="grid">
      ${[["South African Radio", "/radio"], ["Spotify, Apple Music & YouTube Music", "/streaming"], ["Top South African podcasts", "/podcasts"], ["Focus & study", "/tools"], ["Identify a song", "/recognize"]].map(([t, h], i) =>
        html`<a href="${h}" data-link class="card" style="background:${colors[i]};min-height:110px"><div class="t" style="font-size:20px">${t}</div></a>`)}
      ${genres.map((g, i) => html`<button class="card" data-genre="${g.genre}" style="background:${colors[(i + 4) % colors.length]};min-height:110px;border:0;text-align:left"><div class="t" style="font-size:20px">${g.genre}</div><div class="s" style="color:#fffc">${g.count} songs</div></button>`)}
    </div>`);
  };

  const run = async (q) => {
    history.replaceState(null, "", q ? `/search?q=${encodeURIComponent(q)}` : "/search");
    if (!q) return browse();
    ctrl?.abort();
    ctrl = new AbortController();
    let r;
    try { r = await api.get("/api/search/", { q }, { signal: ctrl.signal }); } catch (e) {
      if (e.name !== "AbortError") set(out, empty("search", "Search unavailable", e.message));
      return;
    }
    const items = r.tracks.map(fromTrack);
    const none = !items.length && !r.artists.length && !r.albums.length && !r.stations.length && !r.podcasts.length && !r.playlists.length;
    const more = html`<a class="btn ghost" href="/streaming?q=${encodeURIComponent(q)}" data-link>${icon("cast")} Search Spotify, Apple Music & YouTube Music for "${q}"</a>`;
    set(out, none ? empty("search", `No results for "${q}"`, "Not in your library? Try your streaming services.", more) : html`${more}
      ${items.length ? html`<h2>Songs</h2>${trackTable(items.slice(0, 10))}` : ""}
      ${r.artists.length ? html`<h2>Artists</h2><div class="scroller">${r.artists.map((a) => card({ title: a.name, sub: "Artist", art: a.image_url, href: `/artist/${a.id}`, round: true }))}</div>` : ""}
      ${r.albums.length ? html`<h2>Albums</h2><div class="scroller">${r.albums.map((a) => card({ title: a.title, sub: a.artist?.name, art: a.cover_url, href: `/album/${a.id}` }))}</div>` : ""}
      ${r.playlists.length ? html`<h2>Playlists</h2><div class="scroller">${r.playlists.map((p) => card({ title: p.name, sub: `By ${p.owner}`, art: p.cover_url, href: `/playlist/${p.id}` }))}</div>` : ""}
      ${r.stations.length ? html`<h2>Radio</h2><div data-stations>${r.stations.map((s, i) => stationRow(s, i))}</div>` : ""}
      ${r.podcasts.length ? html`<h2>Podcasts</h2><div class="scroller">${r.podcasts.map((p) => card({ title: p.title, sub: p.author, art: p.image, href: `/podcast/${p.id}` }))}</div>` : ""}`);
    bindTrackTable(out, items);
    bindStations(out, r.stations);
  };
  bindCards(out);
  out.addEventListener("click", (e) => {
    const g = e.target.closest("[data-genre]");
    if (g) { input.value = g.dataset.genre; run(g.dataset.genre); }
  });
  input.addEventListener("input", debounce(() => run(input.value.trim()), 300));
  run(input.value.trim());
}

// --------------------------------------------------------------- library

export async function libraryView(el, _params, query) {
  const tab = query.get("tab") || "playlists";
  const tabs = [["playlists", "Playlists"], ["songs", "Songs"], ["albums", "Albums"], ["artists", "Artists"],
    ["downloads", "Downloads"], ["local", "On this computer"], ["upload", "Upload"]];
  set(el, html`<h1>Your Library</h1><div class="tabs">${tabs.map(([k, l]) =>
    html`<a class="chip ${tab === k ? "on" : ""}" href="/library?tab=${k}" data-link>${l}</a>`)}</div><div data-body></div>`);
  const body = $("[data-body]", el);
  const loaders = { playlists: libPlaylists, songs: libSongs, albums: libAlbums, artists: libArtists, downloads: libDownloads, local: libLocal, upload: libUpload };
  try { return await loaders[tab](body); } catch (e) { errorView(body, e, () => libraryView(el, _params, query)); }
}

async function libPlaylists(el) {
  const list = await api.list("/api/playlists/");
  set(el, html`<div class="grid">
    <div class="card" data-href="/liked" tabindex="0" style="background:linear-gradient(135deg,#4527a0,#1ed6a0)"><div style="aspect-ratio:1;display:grid;place-items:center">${icon("heart", "i big")}</div><div class="t">Liked Songs</div></div>
    <button class="card" data-new style="border:2px dashed #ffffff30;background:none"><div style="aspect-ratio:1;display:grid;place-items:center;font-size:48px">+</div><div class="t">New playlist</div></button>
    ${list.map((p) => card({ title: p.name, sub: `${p.track_count} songs`, art: p.cover_url, href: `/playlist/${p.id}` }))}</div>`);
  bindCards(el);
  $("[data-new]", el).onclick = () => window.dispatchEvent(new Event("lipina:new-playlist"));
}

async function libSongs(el) {
  let ordering = "-created_at";
  const draw = async () => {
    const tracks = await api.list("/api/tracks/", { limit: 1000, ordering });
    const items = tracks.map(fromTrack);
    set(el, items.length ? html`<div class="actions">
        <button class="big-play" data-play aria-label="Play all">${icon("play")}</button>
        <button class="icon-btn" data-shuffle title="Shuffle">${icon("shuffle")}</button>
        <button class="btn ghost" data-dl>${icon("download")} Download all</button>
        <span class="spacer"></span><span class="muted small">${items.length} songs</span>
        <select class="chip" data-order>${[["-created_at", "Recently added"], ["title", "Title"], ["artist__name", "Artist"], ["-play_count", "Most played"]].map(([v, l]) =>
          html`<option value="${v}" ${v === ordering ? "selected" : ""}>${l}</option>`)}</select></div>${trackTable(items)}`
      : empty("library", "No songs yet", "Upload music to build your library.", html`<a class="btn primary" href="/library?tab=upload" data-link>Upload</a>`));
    bindTrackTable(el, items);
    if (!items.length) return;
    $("[data-play]", el).onclick = () => player.playItems(items, 0, { shuffle: false });
    $("[data-shuffle]", el).onclick = () => player.playItems(items, 0, { shuffle: true });
    $("[data-dl]", el).onclick = () => { toast(`Downloading ${items.length} songs…`); downloadAll(items).then((n) => toast(`${n} songs ready offline`)); };
    $("[data-order]", el).onchange = (e) => { ordering = e.target.value; draw(); };
  };
  await draw();
}

async function libAlbums(el) {
  const list = await api.list("/api/albums/", { limit: 1000 });
  set(el, list.length ? html`<div class="grid">${list.map((a) => card({ title: a.title, sub: [a.artist?.name, a.year].filter(Boolean).join(" · "), art: a.cover_url, href: `/album/${a.id}` }))}</div>` : empty("album", "No albums yet"));
  bindCards(el);
}

async function libArtists(el) {
  const list = await api.list("/api/artists/", { limit: 1000 });
  set(el, list.length ? html`<div class="grid">${list.map((a) => card({ title: a.name, sub: `${a.track_count} songs`, art: a.image_url, href: `/artist/${a.id}`, round: true }))}</div>` : empty("person", "No artists yet"));
  bindCards(el);
}

async function libDownloads(el) {
  const draw = async () => {
    const recs = await listDownloads();
    const items = recs.map((r) => r.item);
    const bytes = recs.reduce((s, r) => s + (r.size || 0), 0);
    const est = await storageEstimate();
    set(el, items.length ? html`<div class="actions"><button class="big-play" data-play>${icon("play")}</button>
      <span class="muted">${items.length} items · ${(bytes / 1048576).toFixed(1)} MB${est ? ` · ${(est.usage / 1073741824).toFixed(2)} of ${(est.quota / 1073741824).toFixed(1)} GB browser storage used` : ""}</span></div>
      ${trackTable(items, { removable: true })}`
      : empty("download", "No downloads yet", "Use ⋮ → Download on any song or episode, or Download all on a playlist. Downloads play with no connection."));
    bindTrackTable(el, items, { onRemove: (it) => removeDownload(it.key).then(draw) });
    $("[data-play]", el)?.addEventListener("click", () => player.playItems(items));
  };
  await draw();
}

async function libLocal(el) {
  const draw = async () => {
    const recs = await listLocal();
    const items = recs.map((r) => r.item);
    set(el, html`<div class="dropzone" data-drop>
        <p><b>Play music straight from this computer</b> — files stay in your browser and work offline. No upload needed.</p>
        <label class="btn primary">${icon("folder")} Choose files<input type="file" accept="audio/*,.flac,.m4a,.opus" multiple hidden data-files></label>
        <label class="btn">${icon("folder")} Choose a folder<input type="file" webkitdirectory multiple hidden data-files></label>
        <p class="small">…or drag & drop audio files here</p></div>
      ${items.length ? html`<div class="actions" style="margin-top:20px"><button class="big-play" data-play>${icon("play")}</button><button class="icon-btn" data-shuffle>${icon("shuffle")}</button><span class="muted">${items.length} files</span></div>${trackTable(items, { album: false, removable: true })}` : ""}`);
    bindTrackTable(el, items, { onRemove: (it) => removeLocal(it.key).then(draw) });
    $("[data-play]", el)?.addEventListener("click", () => player.playItems(items));
    $("[data-shuffle]", el)?.addEventListener("click", () => player.playItems(items, 0, { shuffle: true }));
    const add = async (files) => { const n = await importLocalFiles(files); toast(`Added ${n} file(s)`); draw(); };
    $$("[data-files]", el).forEach((inp) => inp.addEventListener("change", () => add([...inp.files])));
    dropzone($("[data-drop]", el), add);
    $$("tr[data-i]", el).forEach((tr) => {
      const btn = document.createElement("button");
      btn.className = "icon-btn";
      btn.title = "Upload to my cloud library";
      btn.innerHTML = icon("upload").s;
      btn.onclick = async (e) => {
        e.stopPropagation();
        toast("Uploading…");
        try { await uploadLocalToCloud(items[+tr.dataset.i].key); toast("Uploaded — now on all your devices"); } catch (err) { toast(err.message); }
      };
      tr.lastElementChild.prepend(btn);
    });
  };
  await draw();
}

function dropzone(zone, onFiles) {
  zone.addEventListener("dragover", (e) => { e.preventDefault(); zone.classList.add("over"); });
  zone.addEventListener("dragleave", () => zone.classList.remove("over"));
  zone.addEventListener("drop", (e) => { e.preventDefault(); zone.classList.remove("over"); onFiles([...e.dataTransfer.files]); });
}

async function libUpload(el) {
  set(el, html`<div class="dropzone" data-drop><h3>Upload to your Lipina library</h3>
    <p>MP3, M4A/AAC, FLAC, OGG/Opus, WAV. Tags and cover art are read automatically. Uploads sync to the mobile app.</p>
    <label class="btn primary">${icon("upload")} Choose files<input type="file" accept="audio/*,.flac,.m4a,.opus" multiple hidden data-files></label>
    ${auth.user?.is_staff ? html`<p><label><input type="checkbox" data-public> Publish to the shared catalog (visible to all listeners)</label></p>` : ""}
    </div><div data-log style="margin-top:16px"></div>`);
  const log = $("[data-log]", el);
  const upload = async (files) => {
    for (const f of files) {
      const row = document.createElement("div");
      row.className = "upload-row";
      row.innerHTML = html`<span>${f.name}</span><span data-s>0%</span>`.s;
      log.prepend(row);
      const fd = new FormData();
      fd.append("file", f);
      if ($("[data-public]", el)?.checked) fd.append("is_public", "true");
      try {
        const res = await api.upload("/api/tracks/", fd, (p) => { $("[data-s]", row).textContent = `${Math.round(p * 100)}%`; });
        const err = res.errors?.[0]?.error;
        $("[data-s]", row).innerHTML = err ? html`<span class="error">${err}</span>`.s : html`<span style="color:var(--accent)">✓ ${res.tracks[0]?.title}</span>`.s;
      } catch (e) {
        $("[data-s]", row).innerHTML = html`<span class="error">${e.message}</span>`.s;
      }
    }
  };
  $("[data-files]", el).addEventListener("change", (e) => upload([...e.target.files]));
  dropzone($("[data-drop]", el), upload);
}

// ------------------------------------------------- playlist/album/artist/liked

export async function collectionView(el, params, _q, kind) {
  set(el, html`<div class="hero"><div class="art skeleton"></div><div><h1>&nbsp;</h1></div></div>`);
  let meta = {}, tracks;
  try {
    if (kind === "playlist") { meta = await api.get(`/api/playlists/${params.id}/`); tracks = meta.tracks; }
    else if (kind === "album") { [meta, tracks] = await Promise.all([api.get(`/api/albums/${params.id}/`), api.get(`/api/albums/${params.id}/tracks/`)]); }
    else if (kind === "artist") { [meta, tracks] = await Promise.all([api.get(`/api/artists/${params.id}/`), api.get(`/api/artists/${params.id}/tracks/`)]); }
    else { tracks = await api.list("/api/tracks/liked/", { limit: 1000 }); meta = { name: "Liked Songs" }; }
  } catch (e) { return errorView(el, e, () => collectionView(el, params, _q, kind)); }
  const items = tracks.map(fromTrack);
  const total = items.reduce((s, i) => s + (i.duration || 0), 0);
  const title = meta.name || meta.title;
  const sub = {
    playlist: `${meta.owner} · ${items.length} songs, ${fmtLong(total)}`,
    album: `${meta.artist?.name || ""}${meta.year ? ` · ${meta.year}` : ""} · ${items.length} songs, ${fmtLong(total)}`,
    artist: `${meta.track_count} songs · ${meta.album_count} albums`,
    liked: `${items.length} songs`,
  }[kind];
  const art = kind === "playlist" ? meta.cover_url : kind === "artist" ? meta.image_url : kind === "album" ? meta.cover_url : null;
  const owner = kind === "playlist" && meta.is_owner;
  const allOffline = items.length && items.every((i) => isDownloaded(i.key));

  set(el, html`${hero({ kind: kind === "liked" ? "Playlist" : kind, title, sub, art, extra: meta.description ? html`<p class="muted">${meta.description}</p>` : "" })}
    <div class="actions">
      <button class="big-play" data-play aria-label="Play" ${items.length ? "" : "disabled"}>${icon("play")}</button>
      <button class="icon-btn ${player.shuffle ? "on" : ""}" data-shuffle title="Shuffle play">${icon("shuffle")}</button>
      <button class="icon-btn ${allOffline ? "on" : ""}" data-dl title="Download all for offline">${icon(allOffline ? "downloaded" : "download")}</button>
      ${owner ? html`<button class="icon-btn" data-more title="More">${icon("more")}</button>` : ""}
    </div>
    ${items.length ? trackTable(items, { album: kind !== "album", removable: owner }) : empty("note", kind === "liked" ? "Songs you like will appear here" : "No songs here yet", kind === "playlist" ? "Find songs with Search and use ⋮ → Add to playlist." : "")}`);

  bindTrackTable(el, items, {
    onRemove: async (it) => {
      await api.del(`/api/playlists/${params.id}/tracks/${it.remoteId}/`);
      toast("Removed from playlist");
      collectionView(el, params, _q, kind);
    },
  });
  $("[data-play]", el).onclick = () => player.playItems(items, 0, { shuffle: false });
  $("[data-shuffle]", el).onclick = () => player.playItems(items, 0, { shuffle: true });
  $("[data-dl]", el).onclick = () => {
    toast(`Downloading ${items.length} songs…`);
    downloadAll(items).then((n) => toast(`${n} songs ready offline`));
  };
  $("[data-more]", el)?.addEventListener("click", (e) => {
    menu(e.currentTarget, [
      { label: "Rename", icon: "lyrics", onClick: async () => {
        const name = await prompt("Rename playlist", { value: title });
        if (name) { await api.patch(`/api/playlists/${params.id}/`, { name }); window.dispatchEvent(new Event("lipina:playlists")); collectionView(el, params, _q, kind); }
      } },
      { label: "Edit description", icon: "lyrics", onClick: async () => {
        const description = await prompt("Description", { value: meta.description || "" });
        if (description !== null) { await api.patch(`/api/playlists/${params.id}/`, { description }); collectionView(el, params, _q, kind); }
      } },
      { label: meta.is_public ? "Make private" : "Make public", icon: "person", onClick: async () => {
        await api.patch(`/api/playlists/${params.id}/`, { is_public: !meta.is_public });
        toast(meta.is_public ? "Playlist is now private" : "Playlist is now public");
        collectionView(el, params, _q, kind);
      } },
      { label: "Delete playlist", icon: "close", onClick: async () => {
        if (!(await confirmDialog("Delete playlist?", `"${title}" will be deleted. Songs stay in your library.`))) return;
        await api.del(`/api/playlists/${params.id}/`);
        window.dispatchEvent(new Event("lipina:playlists"));
        navigate("/library");
      } },
    ]);
  });

  if (kind === "artist") {
    const albums = await api.get(`/api/artists/${params.id}/albums/`).catch(() => []);
    if (albums.length) {
      el.insertAdjacentHTML("beforeend", html`<h2>Albums</h2><div class="scroller" data-albums>${albums.map((a) => card({ title: a.title, sub: a.year, art: a.cover_url, href: `/album/${a.id}` }))}</div>`.s);
      bindCards($("[data-albums]", el));
    }
  }
}

// ------------------------------------------------------------------ radio

function stationRow(s, i) {
  const playing = player.current?.key === `station:${s.id}`;
  return html`<div class="list-item ${playing ? "playing" : ""}" data-station="${i}" data-key="station:${s.id}" tabindex="0">
    ${img(s.favicon)}<div class="meta"><div class="tt">${s.name}</div>
    <div class="ts">${[s.state, ...(s.tags || []).slice(0, 3), s.bitrate ? `${s.bitrate}kbps` : "", s.is_https ? "" : "http only"].filter(Boolean).join(" · ")}</div></div>
    <button class="icon-btn ${s.is_favorite ? "on" : ""}" data-fav aria-label="Favourite">${icon(s.is_favorite ? "heart" : "heartO")}</button></div>`;
}

function bindStations(root, stations) {
  root.addEventListener("click", async (e) => {
    const row = e.target.closest("[data-station]");
    if (!row) return;
    const s = stations[+row.dataset.station];
    if (e.target.closest("[data-fav]")) {
      s.is_favorite = !s.is_favorite;
      e.target.closest("[data-fav]").outerHTML = html`<button class="icon-btn ${s.is_favorite ? "on" : ""}" data-fav aria-label="Favourite">${icon(s.is_favorite ? "heart" : "heartO")}</button>`.s;
      try { s.is_favorite ? await api.post(`/api/radio/stations/${s.id}/favorite/`) : await api.del(`/api/radio/stations/${s.id}/favorite/`); }
      catch (err) { toast(err.message); }
      return;
    }
    api.post(`/api/radio/stations/${s.id}/play/`).catch(() => {});
    player.playItems([fromStation(s)]);
  });
}

export async function radioView(el) {
  const state = { q: "", province: "", tag: "", favorites: false };
  set(el, html`<h1>South African Radio</h1><p class="muted" style="margin-top:-10px">Live South African stations — talk, news, kwaito, amapiano, gospel, sport and more.</p>
    <input class="input" type="search" placeholder="Search stations" data-q><div data-facets></div><div data-list>${skeletonGrid(4)}</div>`);
  const facets = await api.get("/api/radio/stations/facets/").catch(() => ({ states: [], tags: [] }));
  const drawFacets = () => set($("[data-facets]", el), html`
    <div class="chips"><button class="chip ${state.favorites ? "on" : ""}" data-favs>♥ Favourites</button>
      ${facets.states.map((s) => html`<button class="chip ${state.province === s.name ? "on" : ""}" data-prov="${s.name}">${s.name}</button>`)}</div>
    <div class="chips">${facets.tags.slice(0, 18).map((t) => html`<button class="chip ${state.tag === t.name ? "on" : ""}" data-tag="${t.name}">${t.name}</button>`)}</div>`);
  const load = async () => {
    drawFacets();
    try {
      const stations = await api.list("/api/radio/stations/", {
        limit: 300, q: state.q, state: state.province, tag: state.tag, favorites: state.favorites ? "1" : "",
        https: location.protocol === "https:" && localStorage.getItem("lipina.httpsOnly") === "1" ? "1" : "",
      });
      const old = $("[data-list]", el);
      const fresh = old.cloneNode(false); // fresh node = no stale click listeners
      old.replaceWith(fresh);
      set(fresh, stations.length ? html`${stations.map((s, i) => stationRow(s, i))}` : empty("radio", "No stations match"));
      bindStations(fresh, stations);
    } catch (e) { errorView($("[data-list]", el), e, load); }
  };
  $("[data-facets]", el).addEventListener("click", (e) => {
    const b = e.target.closest("button");
    if (!b) return;
    if (b.dataset.favs !== undefined) state.favorites = !state.favorites;
    if (b.dataset.prov) state.province = state.province === b.dataset.prov ? "" : b.dataset.prov;
    if (b.dataset.tag) state.tag = state.tag === b.dataset.tag ? "" : b.dataset.tag;
    load();
  });
  $("[data-q]", el).addEventListener("input", debounce((e) => { state.q = e.target.value.trim(); load(); }, 300));
  await load();
  const off = () => markPlaying(el);
  player.addEventListener("track", off);
  return () => player.removeEventListener("track", off);
}

// --------------------------------------------------------------- podcasts

export async function podcastsView(el, _p, query) {
  const tab = query.get("tab") || "top";
  set(el, html`<h1>Podcasts</h1><input class="input" type="search" placeholder="Search all podcasts" data-q>
    <div class="tabs" style="margin-top:16px">${[["top", "Top in South Africa"], ["following", "Following"], ["new", "New episodes"], ["continue", "Continue listening"]].map(([k, l]) =>
      html`<a class="chip ${tab === k ? "on" : ""}" href="/podcasts?tab=${k}" data-link>${l}</a>`)}</div><div data-body>${skeletonGrid(8)}</div>`);
  const body = $("[data-body]", el);
  bindCards(body);
  const showDirectory = (list) => {
    set(body, list.length ? html`<div class="grid">${list.map((p, i) => card({ title: `${tab === "top" ? `${i + 1}. ` : ""}${p.title}`, sub: p.author, art: p.image, href: `/podcast/itunes/${p.itunes_id}` }))}</div>` : empty("podcast", "No podcasts found"));
  };
  $("[data-q]", el).addEventListener("input", debounce(async (e) => {
    const q = e.target.value.trim();
    if (!q) return podcastsView(el, _p, query);
    try { showDirectory(await api.get("/api/podcasts/directory/search/", { q })); } catch (err) { errorView(body, err, () => {}); }
  }, 400));
  try {
    if (tab === "top") showDirectory(await api.get("/api/podcasts/directory/top/"));
    else if (tab === "following") {
      const list = await api.get("/api/podcasts/shows/subscriptions/");
      set(body, list.length ? html`<div class="grid">${list.map((p) => card({ title: p.title, sub: p.author, art: p.image, href: `/podcast/${p.id}` }))}</div>` : empty("podcast", "Follow shows to see them here", "Browse the top charts to get started."));
    } else {
      const eps = tab === "new" ? await api.list("/api/podcasts/shows/feed/", { limit: 60 }) : await api.get("/api/podcasts/episodes/in-progress/");
      episodeList(body, eps, true, tab === "new" ? "Nothing new from the shows you follow" : "Episodes you start will show up here");
    }
  } catch (e) { errorView(body, e, () => podcastsView(el, _p, query)); }
}

function episodeList(el, eps, showShow, emptyMsg = "No episodes") {
  const items = eps.map(fromEpisode);
  set(el, eps.length ? html`${eps.map((e, i) => html`<div class="list-item" data-ep="${i}" data-key="episode:${e.id}" tabindex="0">
      ${showShow ? img(e.podcast_image) : ""}<div class="meta"><div class="tt">${e.title}</div>
      <div class="ts">${[showShow ? e.podcast_title : "", e.published_at ? new Date(e.published_at).toLocaleDateString() : "", e.duration ? fmtLong(e.duration) : "", e.completed ? "Played ✓" : ""].filter(Boolean).join(" · ")}</div>
      ${e.position && !e.completed && e.duration ? html`<div class="progress-mini"><div style="width:${Math.min(100, (e.position / e.duration) * 100)}%"></div></div>` : ""}
      </div>${isDownloaded(`episode:${e.id}`) ? html`<span class="dl-dot">●</span>` : ""}<button class="icon-btn" data-more>${icon("more")}</button></div>`)}`
    : empty("podcast", emptyMsg));
  el.onclick = (ev) => {
    const row = ev.target.closest("[data-ep]");
    if (!row) return;
    const item = items[+row.dataset.ep];
    if (ev.target.closest("[data-more]")) return itemMenu(ev.target.closest("[data-more]"), item);
    player.playItems([item]);
  };
  markPlaying(el);
}

export async function podcastView(el, params) {
  set(el, html`<div class="hero"><div class="art skeleton"></div><div><h1>&nbsp;</h1></div></div>`);
  let pod;
  try {
    if (params.itunes) {
      pod = await api.post("/api/podcasts/shows/", { itunes_id: +params.itunes });
      history.replaceState(null, "", `/podcast/${pod.id}`);
    } else pod = await api.get(`/api/podcasts/shows/${params.id}/`);
  } catch (e) { return errorView(el, e, () => podcastView(el, params)); }
  const draw = () => set(el, html`${hero({ kind: "Podcast", title: pod.title, sub: pod.author, art: pod.image })}
    <div class="actions"><button class="btn ${pod.is_subscribed ? "ghost" : "primary"}" data-sub>${pod.is_subscribed ? "✓ Following" : "Follow"}</button></div>
    ${pod.description ? html`<p class="muted" style="max-width:800px">${pod.description.slice(0, 600)}</p>` : ""}
    <h2>Episodes</h2><div data-eps>${skeletonGrid(3)}</div>`);
  draw();
  const bindSub = () => {
    $("[data-sub]", el).onclick = async () => {
      pod.is_subscribed = !pod.is_subscribed;
      try {
        pod.is_subscribed ? await api.post(`/api/podcasts/shows/${pod.id}/subscribe/`) : await api.del(`/api/podcasts/shows/${pod.id}/subscribe/`);
      } catch (e) { pod.is_subscribed = !pod.is_subscribed; toast(e.message); }
      const b = $("[data-sub]", el);
      b.className = `btn ${pod.is_subscribed ? "ghost" : "primary"}`;
      b.textContent = pod.is_subscribed ? "✓ Following" : "Follow";
    };
  };
  bindSub();
  try { episodeList($("[data-eps]", el), await api.list(`/api/podcasts/shows/${pod.id}/episodes/`, { limit: 200 }), false); }
  catch (e) { errorView($("[data-eps]", el), e, () => podcastView(el, params)); }
}

// -------------------------------------------------------------- recognize

export async function recognizeView(el) {
  let state = "idle", match = null, message = "";
  let recorder, stream, timer;
  const draw = () => {
    set(el, html`<h1>Identify a song</h1><p class="muted" style="margin-top:-10px">Hold your device near the music. Lipina listens for 10 seconds.</p>
      <div class="rec-wrap"><button class="rec-btn ${state === "listening" ? "listening" : ""}" data-rec ${state === "listening" || state === "matching" ? "disabled" : ""} aria-label="Listen">${icon(state === "matching" ? "more" : "wave")}</button>
      <h2>${{ idle: "Tap to identify", listening: "Listening…", matching: "Finding a match…", done: match ? "Got it!" : "Tap to try again" }[state]}</h2>
      ${message ? html`<p class="muted">${message}</p>` : ""}</div>
      ${match ? html`<div class="match">${img(match.cover_url, "")}<div><h2 style="margin:0">${match.title}</h2><p class="muted">${match.artist}${match.album ? ` · ${match.album}` : ""}${match.release_date ? ` · ${match.release_date}` : ""}</p>
        <div class="row">${match.matched_track ? html`<button class="btn primary" data-play-local>${icon("play")} Play from your library</button>` : ""}
        ${match.links?.preview ? html`<button class="btn" data-preview>${icon("play")} Preview</button>` : ""}
        ${match.links?.spotify ? html`<a class="btn ghost" href="${match.links.spotify}" target="_blank" rel="noopener">Spotify</a>` : ""}
        ${match.links?.apple_music ? html`<a class="btn ghost" href="${match.links.apple_music}" target="_blank" rel="noopener">Apple Music</a>` : ""}
        ${match.links?.song_link ? html`<a class="btn ghost" href="${match.links.song_link}" target="_blank" rel="noopener">All platforms</a>` : ""}
        <button class="btn ghost" data-lyrics>${icon("lyrics")} Lyrics</button></div></div></div>` : ""}
      <h2>History</h2><div data-history></div>`);
    $("[data-rec]", el)?.addEventListener("click", listen);
    $("[data-play-local]", el)?.addEventListener("click", () => player.playItems([fromTrack(match.matched_track)]));
    $("[data-preview]", el)?.addEventListener("click", () => player.playItems([{ key: `preview:${match.id}`, kind: "preview", title: match.title, subtitle: `${match.artist} · preview`, art: match.cover_url, url: match.links.preview }]));
    $("[data-lyrics]", el)?.addEventListener("click", async () => {
      try {
        const l = await api.get("/api/lyrics/", { title: match.title, artist: match.artist });
        const text = l.plain || (l.synced || "").replace(/\[[^\]]*\]/g, "");
        modal(html`<h3>${match.title}</h3><div class="lyrics plain">${text}</div>`);
      } catch { toast("No lyrics found"); }
    });
    history_();
  };
  const history_ = async () => {
    const list = await api.get("/api/recognize/").catch(() => []);
    const h = $("[data-history]", el);
    if (h) set(h, list.length ? html`${list.map((m) => html`<div class="list-item">${img(m.cover_url)}<div class="meta"><div class="tt">${m.title}</div><div class="ts">${m.artist} · ${new Date(m.created_at).toLocaleString()}</div></div></div>`)}` : html`<p class="muted">Songs you identify will appear here.</p>`);
  };
  async function listen() {
    if (!navigator.mediaDevices?.getUserMedia || !window.MediaRecorder) { message = "Your browser can't record audio. Try Chrome, Edge, Firefox or Safari 14.1+."; return draw(); }
    try { stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false } }); }
    catch { message = "Microphone access was blocked. Allow it in your browser's site settings."; return draw(); }
    const mime = ["audio/webm;codecs=opus", "audio/ogg;codecs=opus", "audio/mp4"].find((m) => MediaRecorder.isTypeSupported(m)) || "";
    recorder = new MediaRecorder(stream, mime ? { mimeType: mime } : undefined);
    const chunks = [];
    recorder.ondataavailable = (e) => e.data.size && chunks.push(e.data);
    recorder.onstop = async () => {
      stream.getTracks().forEach((t) => t.stop());
      state = "matching"; draw();
      const type = recorder.mimeType || "audio/webm";
      const ext = type.includes("mp4") ? "m4a" : type.includes("ogg") ? "ogg" : "webm";
      const fd = new FormData();
      fd.append("file", new Blob(chunks, { type }), `clip.${ext}`);
      try {
        const res = await api.upload("/api/recognize/", fd);
        match = res.match;
        message = match ? "" : res.detail || "No match found.";
      } catch (e) { match = null; message = e.message; }
      state = "done"; draw();
    };
    match = null; message = ""; state = "listening"; draw();
    recorder.start();
    timer = setTimeout(() => recorder.state === "recording" && recorder.stop(), 10000);
  }
  draw();
  return () => { clearTimeout(timer); if (recorder?.state === "recording") recorder.stop(); stream?.getTracks().forEach((t) => t.stop()); };
}

// ------------------------------------------------------------------ tools

export function toolsView(el) {
  const ring = (frac) => {
    const r = 100, c = 2 * Math.PI * r;
    return html`<svg width="220" height="220" viewBox="0 0 220 220"><circle cx="110" cy="110" r="${r}" stroke="#ffffff15" stroke-width="10" fill="none"/>
      <circle cx="110" cy="110" r="${r}" stroke="${focus.phase === "focus" || focus.phase === "idle" ? "var(--accent)" : "var(--gold)"}" stroke-width="10" fill="none" stroke-linecap="round" stroke-dasharray="${c}" stroke-dashoffset="${c * (1 - frac)}"/></svg>`;
  };
  const sounds = [["brown", "Brown noise", "Deep & warm"], ["pink", "Pink noise", "Balanced"], ["white", "White noise", "Masks chatter"], ["rain", "Rain", "Steady rainfall"], ["ocean", "Ocean", "Rolling swells"]];
  set(el, html`<h1>Focus & tools</h1>
  <div class="tool-grid">
    <section class="panel"><h3>Focus timer</h3><div class="timer-ring" data-ring></div>
      <div class="row" style="justify-content:center" data-focus-btns></div>
      <div class="row" style="margin-top:16px"><label class="muted small">Focus <input type="number" min="5" max="120" value="${focus.focusMin}" data-fmin class="chip" style="width:70px"> min</label>
      <label class="muted small"><input type="checkbox" data-pm ${focus.pauseMusic ? "checked" : ""}> Pause music on breaks</label></div>
      <p class="muted small">25 min focus · 5 min break · long break every 4 sessions.</p></section>
    <section class="panel"><h3>Ambient sounds</h3><p class="muted small">Plays on top of your music. Generated in your browser and works offline.</p>
      <div class="sound-tiles">${sounds.map(([k, t, s]) => html`<button class="sound-tile ${noise.type === k ? "on" : ""}" data-noise="${k}">${icon("wave")}<b>${t}</b><span class="muted small">${s}</span></button>`)}</div>
      <div class="row" style="margin-top:12px">${icon("volume")}<input type="range" min="0" max="100" value="${noise.volume * 100}" data-nvol style="flex:1"></div></section>
    <section class="panel"><h3>Sleep timer</h3><div class="chips">${[10, 15, 30, 45, 60, 90].map((m) => html`<button class="chip" data-sleep="${m}">${m} min</button>`)}<button class="chip" data-sleep="eot">End of track</button><button class="chip" data-sleep="0">Off</button></div><p class="muted small" data-sleep-state></p></section>
    <section class="panel"><h3>Equalizer</h3><label class="row small"><input type="checkbox" data-eq-on ${player.eqEnabled ? "checked" : ""}> Enabled</label>
      <div class="chips">${Object.keys(EQ_PRESETS).map((p) => html`<button class="chip" data-preset="${p}">${p}</button>`)}</div>
      <div class="eq">${["60", "230", "910", "3.6k", "14k"].map((f, i) => html`<div class="band"><span data-gv="${i}">${player.eqGains[i]} dB</span><input type="range" class="vertical" min="-12" max="12" step="1" value="${player.eqGains[i]}" data-band="${i}"><span>${f}</span></div>`)}</div>
      <p class="muted small">Applies to your library, downloads and local files. Radio and external podcasts play unprocessed.</p></section>
    <section class="panel"><h3>Metronome</h3><div class="bpm" data-bpm>${metronome.bpm}</div>
      <div class="beat-dots" data-dots>${Array.from({ length: metronome.beats }, () => html`<span></span>`)}</div>
      <input type="range" min="30" max="260" value="${metronome.bpm}" data-bpm-range style="width:100%">
      <div class="row" style="justify-content:center;margin-top:12px"><button class="btn primary" data-metro>${metronome.on ? "Stop" : "Start"}</button><button class="btn" data-tap>Tap tempo</button>
      <select class="chip" data-beats>${[2, 3, 4, 5, 6, 7].map((b) => html`<option ${b === metronome.beats ? "selected" : ""}>${b}</option>`)}</select><span class="muted small">beats/bar</span></div></section>
    <section class="panel"><h3>Tuner</h3><div class="tuner-note" data-note>—</div><div class="tuner-meter"><i data-needle></i></div>
      <p class="muted small" style="text-align:center" data-freq>Play a single note into your mic</p><div class="row" style="justify-content:center"><button class="btn" data-tuner>${tuner.running ? "Stop tuner" : "Start tuner"}</button></div></section>
  </div><p class="muted small" style="margin-top:20px">Keyboard: <span class="kbd">Space</span> play/pause · <span class="kbd">←</span>/<span class="kbd">→</span> seek · <span class="kbd">N</span>/<span class="kbd">P</span> next/prev · <span class="kbd">L</span> like · <span class="kbd">M</span> mute · <span class="kbd">/</span> search</p>`);

  const drawFocus = () => {
    const total = focus.total();
    const rem = focus.phase === "idle" ? total : focus.remaining;
    set($("[data-ring]", el), html`${ring(focus.phase === "idle" ? 0 : 1 - rem / total)}<div class="label"><div class="time">${fmtTime(rem)}</div><div class="muted">${{ idle: "Ready", focus: "Focus", short: "Short break", long: "Long break" }[focus.phase]}${focus.paused ? " · paused" : ""}</div><div class="muted small">${focus.sessions} sessions</div></div>`);
    set($("[data-focus-btns]", el), focus.phase === "idle" ? html`<button class="btn primary" data-fstart>${icon("play")} Start focus</button>`
      : html`<button class="btn" data-fpause>${focus.paused ? "Resume" : "Pause"}</button><button class="btn ghost" data-fstop>End</button>`);
  };
  focus.onTick = drawFocus;
  drawFocus();
  el.addEventListener("click", (e) => {
    const t = e.target.closest("button");
    if (!t) return;
    if (t.dataset.fstart !== undefined) { if ("Notification" in window && Notification.permission === "default") Notification.requestPermission(); focus.start(); }
    if (t.dataset.fpause !== undefined) focus.togglePause();
    if (t.dataset.fstop !== undefined) focus.stop();
    if (t.dataset.noise) {
      noise.set(noise.type === t.dataset.noise ? null : t.dataset.noise);
      $$("[data-noise]", el).forEach((b) => b.classList.toggle("on", b.dataset.noise === noise.type));
    }
    if (t.dataset.sleep) {
      const v = t.dataset.sleep;
      player.setSleep(v === "eot" || v === "0" ? null : +v, v === "eot");
      sleepState();
      toast(v === "0" ? "Sleep timer off" : v === "eot" ? "Stopping after this track" : `Sleeping in ${v} minutes`);
    }
    if (t.dataset.preset) {
      player.setEq(EQ_PRESETS[t.dataset.preset], true);
      $("[data-eq-on]", el).checked = true;
      $$("[data-band]", el).forEach((r, i) => { r.value = player.eqGains[i]; $(`[data-gv="${i}"]`, el).textContent = `${player.eqGains[i]} dB`; });
    }
    if (t.dataset.metro !== undefined) { metronome.toggle(); t.textContent = metronome.on ? "Stop" : "Start"; }
    if (t.dataset.tap !== undefined) { const b = metronome.tap(); if (b) setBpm(b); }
    if (t.dataset.tuner !== undefined) {
      if (tuner.running) { tuner.stop(); t.textContent = "Start tuner"; }
      else tuner.start().then(() => { t.textContent = "Stop tuner"; }, () => toast("Microphone access is needed for the tuner"));
    }
  });
  const sleepState = () => {
    $("[data-sleep-state]", el).textContent = player.sleepAt ? `Music stops at ${new Date(player.sleepAt).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}` : player.sleepEndOfTrack ? "Stops after the current track" : "Off";
  };
  sleepState();
  $("[data-fmin]", el).onchange = (e) => { focus.focusMin = Math.max(5, Math.min(120, +e.target.value || 25)); localStorage.setItem("lipina.focusMin", focus.focusMin); drawFocus(); };
  $("[data-pm]", el).onchange = (e) => { focus.pauseMusic = e.target.checked; };
  const nvol = $("[data-nvol]", el);
  setRangeFill(nvol);
  nvol.oninput = () => { noise.setVolume(nvol.value / 100); setRangeFill(nvol); };
  $("[data-eq-on]", el).onchange = (e) => player.setEq(player.eqGains, e.target.checked);
  $$("[data-band]", el).forEach((r) => (r.oninput = () => {
    const g = player.eqGains.slice();
    g[+r.dataset.band] = +r.value;
    player.setEq(g);
    $(`[data-gv="${r.dataset.band}"]`, el).textContent = `${r.value} dB`;
  }));
  const setBpm = (b) => { metronome.bpm = Math.max(30, Math.min(260, b)); $("[data-bpm]", el).textContent = metronome.bpm; $("[data-bpm-range]", el).value = metronome.bpm; };
  $("[data-bpm-range]", el).oninput = (e) => setBpm(+e.target.value);
  $("[data-beats]", el).onchange = (e) => { metronome.beats = +e.target.value; set($("[data-dots]", el), html`${Array.from({ length: metronome.beats }, () => html`<span></span>`)}`); };
  metronome.onBeat = (beat, accent) => {
    const dots = $$("[data-dots] span", el);
    dots.forEach((d, i) => { d.classList.toggle("on", i === beat); d.classList.toggle("accent", i === beat && accent); });
  };
  tuner.onPitch = ({ note, octave, cents, freq }) => {
    $("[data-note]", el).textContent = `${note}${octave}`;
    $("[data-needle]", el).style.left = `${50 + cents}%`;
    $("[data-freq]", el).textContent = `${freq.toFixed(1)} Hz · ${cents > 0 ? "+" : ""}${cents} cents ${Math.abs(cents) <= 5 ? "✓ in tune" : cents < 0 ? "(flat)" : "(sharp)"}`;
  };
  return () => { focus.onTick = null; metronome.onBeat = null; tuner.onPitch = null; if (tuner.running) tuner.stop(); };
}

// --------------------------------------------------------------- settings

export async function settingsView(el) {
  const me = auth.user || {};
  const est = await storageEstimate();
  set(el, html`<h1>Settings</h1>
    <section class="panel" style="max-width:640px"><h3>Profile</h3>
      <form data-profile><div class="field"><label>Username</label><input class="input" value="${me.username}" disabled></div>
      <div class="field"><label>Display name</label><input class="input" name="display_name" value="${me.display_name || ""}"></div>
      <div class="field"><label>Email</label><input class="input" name="email" type="email" value="${me.email || ""}"></div>
      <button class="btn primary">Save</button></form></section>
    <section class="panel" style="max-width:640px;margin-top:18px"><h3>Password</h3>
      <form data-pw><div class="field"><label>Current password</label><input class="input" name="old_password" type="password" autocomplete="current-password" required></div>
      <div class="field"><label>New password</label><input class="input" name="new_password" type="password" autocomplete="new-password" minlength="8" required></div>
      <button class="btn">Change password</button></form></section>
    <section class="panel" style="max-width:640px;margin-top:18px"><h3>Playback & offline</h3>
      <label class="row"><input type="checkbox" data-https ${localStorage.getItem("lipina.httpsOnly") === "1" ? "checked" : ""}> Only show radio stations that stream securely (https)</label>
      <p class="muted small">Storage: ${est ? `${(est.usage / 1048576).toFixed(0)} MB used of ${(est.quota / 1073741824).toFixed(1)} GB available` : "unknown"}</p>
      <div class="row"><button class="btn" data-install hidden>${icon("download")} Install Lipina app</button><button class="btn danger" data-clear-cache>Clear cached pages</button></div></section>
    <section class="panel" style="max-width:640px;margin-top:18px"><h3>About</h3><p class="muted small">Radio directory: radio-browser.info · Streaming: Spotify, Apple Music, YouTube · Lyrics: LRCLIB · Podcast directory: Apple Podcasts · Song recognition: AudD.</p>
      <button class="btn danger" data-logout>${icon("logout")} Log out</button></section>`);
  $("[data-profile]", el).onsubmit = async (e) => {
    e.preventDefault();
    const f = new FormData(e.target);
    try { auth.user = await api.patch("/api/auth/me/", { display_name: f.get("display_name"), email: f.get("email") }); localStorage.setItem("lipina.me", JSON.stringify(auth.user)); toast("Profile saved"); }
    catch (err) { toast(err.message); }
  };
  $("[data-pw]", el).onsubmit = async (e) => {
    e.preventDefault();
    const f = new FormData(e.target);
    try {
      const t = await api.post("/api/auth/password/", { old_password: f.get("old_password"), new_password: f.get("new_password") });
      localStorage.setItem("lipina.access", t.access); localStorage.setItem("lipina.refresh", t.refresh);
      e.target.reset(); toast("Password changed");
    } catch (err) { toast(err.message); }
  };
  $("[data-https]", el).onchange = (e) => localStorage.setItem("lipina.httpsOnly", e.target.checked ? "1" : "0");
  $("[data-clear-cache]", el).onclick = async () => { await caches.delete("lipina-api"); toast("Cached pages cleared"); };
  $("[data-logout]", el).onclick = () => { auth.logout(); window.dispatchEvent(new Event("lipina:logout")); };
  const install = $("[data-install]", el);
  if (window.__lipinaInstall) { install.hidden = false; install.onclick = () => window.__lipinaInstall.prompt(); }
}
