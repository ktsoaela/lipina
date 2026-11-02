// "Streaming" page: connect Spotify / Apple Music / YouTube Music, search them, browse playlists.
import { bindTrackTable, markPlaying, navigate, trackTable } from "./components.js";
import { player } from "./player.js";
import {
  appleArtwork, appleEngine, fromAppleMusic, fromITunes, fromSpotify, fromYouTube, getConfig, spotifyApi, spotifyAuth,
} from "./streaming.js";
import { api } from "./api.js";
import { $, debounce, empty, html, icon, img, toast } from "./ui.js";

const set = (el, content) => { el.innerHTML = content.s ?? content; };

const SERVICES = [
  { id: "spotify", name: "Spotify", color: "#1db954", note: "Full tracks with Spotify Premium, in Chrome, Edge or Firefox." },
  { id: "apple_music", name: "Apple Music", color: "#fa2d48", note: "Full songs for Apple Music subscribers. Everyone else gets 30-second previews." },
  { id: "youtube", name: "YouTube Music", color: "#ff0033", note: "Music videos play in a small window while you browse." },
];

function serviceState(cfg, id) {
  if (id === "spotify") return { enabled: cfg.spotify.enabled, connected: spotifyAuth.connected, who: spotifyAuth.session?.name };
  if (id === "apple_music") return { enabled: cfg.apple_music.enabled, connected: appleEngine.connected };
  return { enabled: cfg.youtube.enabled, connected: cfg.youtube.enabled, noAccount: true };
}

export async function streamingView(el, _params, query) {
  const tab = query.get("tab") || "search";
  let cfg;
  try { cfg = await getConfig(); } catch (e) {
    return set(el, empty("wave", "Streaming services are unavailable", e.message));
  }
  const tabs = [["search", "Search"], cfg.spotify.enabled && spotifyAuth.connected && ["spotify", "Spotify library"],
    cfg.apple_music.enabled && appleEngine.connected && ["apple", "Apple Music library"]].filter(Boolean);

  set(el, html`<h1>Streaming services</h1>
    <p class="muted" style="margin-top:-10px">Connect your accounts and play them in Lipina's player, alongside your own music and SA radio.</p>
    <div class="svc-grid">${SERVICES.map((s) => {
      const st = serviceState(cfg, s.id);
      const status = !st.enabled ? "Not set up on this server yet"
        : st.noAccount ? "Ready, no sign-in needed"
          : st.connected ? `Connected${st.who ? ` as ${st.who}` : ""}` : "Not connected";
      return html`<div class="svc panel" style="--svc:${s.color}">
        <div class="svc-head"><span class="svc-dot"></span><b>${s.name}</b></div>
        <div class="small ${st.connected ? "" : "muted"}">${status}</div>
        <p class="muted small">${s.note}</p>
        ${st.enabled && !st.noAccount ? (st.connected
          ? html`<button class="btn ghost" data-disconnect="${s.id}">Disconnect</button>`
          : html`<button class="btn primary" data-connect="${s.id}">Connect ${s.name}</button>`) : ""}
      </div>`;
    })}</div>
    ${!cfg.apple_music.enabled ? html`<p class="muted small">Apple Music results below are free 30-second iTunes previews.</p>` : ""}
    <div class="tabs">${tabs.map(([k, l]) => html`<a class="chip ${tab === k ? "on" : ""}" href="/streaming?tab=${k}" data-link>${l}</a>`)}</div>
    <div data-body></div>`);

  el.addEventListener("click", async (e) => {
    const c = e.target.closest("[data-connect]");
    const d = e.target.closest("[data-disconnect]");
    try {
      if (c?.dataset.connect === "spotify") return await spotifyAuth.login();
      if (c?.dataset.connect === "apple_music") { await appleEngine.authorize(); toast("Apple Music connected"); return navigate("/streaming"); }
      if (d) {
        if (player.current?.provider) player.pause();
        d.dataset.disconnect === "spotify" ? spotifyAuth.logout() : await appleEngine.unauthorize();
        toast("Disconnected");
        navigate("/streaming");
      }
    } catch (err) { toast(err.message || "Couldn't connect"); }
  });

  const body = $("[data-body]", el);
  if (tab === "spotify") spotifyLibrary(body, query.get("playlist"));
  else if (tab === "apple") appleLibrary(body, query.get("playlist"));
  else searchAll(body, cfg, query.get("q") || "");
  const mark = () => markPlaying(el);
  player.addEventListener("track", mark);
  return () => player.removeEventListener("track", mark);
}

function liveTable(el, items) {
  set(el, items.length ? trackTable(items) : html`<p class="muted">No results.</p>`);
  bindTrackTable(el, items);
}

// ------------------------------------------------------------------ search

function searchAll(el, cfg, initial) {
  const sources = [
    cfg.spotify.enabled && spotifyAuth.connected && {
      name: "Spotify",
      run: async (q) => (await spotifyApi("/search", { query: { q, type: "track", limit: 20 } })).tracks.items.map(fromSpotify),
    },
    cfg.apple_music.enabled && {
      name: appleEngine.connected ? "Apple Music" : "Apple Music · previews",
      run: async (q) => ((await appleEngine.api("/v1/catalog/{storefront}/search", { term: q, types: "songs", limit: 25 }))
        .results?.songs?.data || []).map(fromAppleMusic),
    },
    !cfg.apple_music.enabled && {
      name: "iTunes · 30-second previews",
      run: async (q) => (await api.get("/api/connect/itunes/search/", { q })).results.map(fromITunes),
    },
    cfg.youtube.enabled && {
      name: "YouTube Music",
      run: async (q) => (await api.get("/api/connect/youtube/search/", { q })).results.map(fromYouTube),
    },
  ].filter(Boolean);

  set(el, html`<input class="input" type="search" placeholder="Search songs on ${sources.map((s) => s.name.split(" ·")[0]).join(", ")}" value="${initial}" data-q autofocus>
    ${cfg.spotify.enabled && !spotifyAuth.connected ? html`<p class="muted small">Connect Spotify above to include it in search.</p>` : ""}
    <div data-results style="margin-top:12px"></div>`);
  const input = $("[data-q]", el);
  const out = $("[data-results]", el);
  let seq = 0;

  const run = async (q) => {
    history.replaceState(null, "", q ? `/streaming?q=${encodeURIComponent(q)}` : "/streaming");
    const mine = ++seq;
    if (!q) return set(out, empty("search", "Search across your streaming services", "Try an artist like Tyla, Master KG or Kabza De Small."));
    set(out, html`${sources.map((s, i) => html`<h2>${s.name}</h2><div data-src="${i}"><p class="muted">Searching…</p></div>`)}`);
    await Promise.all(sources.map(async (s, i) => {
      const box = $(`[data-src="${i}"]`, out);
      try {
        const items = await s.run(q);
        if (mine === seq) liveTable(box, items);
      } catch (e) {
        if (mine === seq) set(box, html`<p class="muted">${e.message}</p>`);
      }
    }));
  };
  input.addEventListener("input", debounce(() => run(input.value.trim()), 450));
  run(initial.trim());
}

// --------------------------------------------------------- Spotify library

async function spotifyTracks(id) {
  if (id === "liked") return (await spotifyApi("/me/tracks", { query: { limit: 50 } })).items.map((i) => i.track);
  let page;
  try { page = await spotifyApi(`/playlists/${id}/tracks`, { query: { limit: 100 } }); } catch (e) {
    if (e.status !== 403 && e.status !== 404) throw e;
    page = await spotifyApi(`/playlists/${id}/items`, { query: { limit: 100 } }); // newer API naming
  }
  return page.items.map((i) => i.track || i.item).filter((t) => t?.type === "track" && t.uri);
}

async function spotifyLibrary(el, playlistId) {
  set(el, html`<p class="muted">Loading…</p>`);
  try {
    if (playlistId) {
      const items = (await spotifyTracks(playlistId)).map(fromSpotify);
      set(el, html`<div class="row"><a class="btn ghost" href="/streaming?tab=spotify" data-link>← Playlists</a>
        <button class="btn primary" data-all ${items.length ? "" : "disabled"}>${icon("play")} Play all</button></div><div data-t style="margin-top:12px"></div>`);
      $("[data-all]", el).onclick = () => player.playItems(items, 0);
      return liveTable($("[data-t]", el), items);
    }
    const lists = (await spotifyApi("/me/playlists", { query: { limit: 50 } })).items.filter(Boolean);
    set(el, html`<div class="grid">
      <a class="card" href="/streaming?tab=spotify&playlist=liked" data-link>${img(null)}<div class="t">Liked Songs</div><div class="s">Spotify</div></a>
      ${lists.map((p) => html`<a class="card" href="/streaming?tab=spotify&playlist=${p.id}" data-link>${img(p.images?.[0]?.url)}<div class="t">${p.name}</div><div class="s">${p.owner?.display_name || ""}</div></a>`)}
    </div>`);
  } catch (e) { set(el, empty("wave", "Couldn't load your Spotify library", e.message)); }
}

// ----------------------------------------------------- Apple Music library

async function appleLibrary(el, playlistId) {
  set(el, html`<p class="muted">Loading…</p>`);
  try {
    if (playlistId) {
      const items = (await appleEngine.api(`/v1/me/library/playlists/${playlistId}/tracks`, { limit: 100 })).data.map(fromAppleMusic);
      set(el, html`<div class="row"><a class="btn ghost" href="/streaming?tab=apple" data-link>← Playlists</a>
        <button class="btn primary" data-all ${items.length ? "" : "disabled"}>${icon("play")} Play all</button></div><div data-t style="margin-top:12px"></div>`);
      $("[data-all]", el).onclick = () => player.playItems(items, 0);
      return liveTable($("[data-t]", el), items);
    }
    const lists = (await appleEngine.api("/v1/me/library/playlists", { limit: 100 })).data;
    set(el, lists.length ? html`<div class="grid">${lists.map((p) => html`<a class="card" href="/streaming?tab=apple&playlist=${encodeURIComponent(p.id)}" data-link>${img(appleArtwork(p.attributes?.artwork))}<div class="t">${p.attributes?.name}</div><div class="s">Apple Music</div></a>`)}</div>`
      : empty("library", "No playlists in your Apple Music library yet"));
  } catch (e) { set(el, empty("wave", "Couldn't load your Apple Music library", e.message)); }
}

// --------------------------------------------------- Spotify sign-in return

export async function spotifyCallbackView(el, _params, query) {
  set(el, html`<p class="muted">Connecting Spotify…</p>`);
  history.replaceState(null, "", "/connect/spotify");
  try {
    const s = await spotifyAuth.finish(query);
    toast(s.product && s.product !== "premium" ? "Spotify connected. Full playback needs Premium." : `Spotify connected as ${s.name}`);
    navigate("/streaming?tab=spotify");
  } catch (e) {
    set(el, empty("wave", "Couldn't connect Spotify", e.message, html`<a class="btn" href="/streaming" data-link>Back</a>`));
  }
}
