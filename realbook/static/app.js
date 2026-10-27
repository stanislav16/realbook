"use strict";

const $ = (sel, el = document) => el.querySelector(sel);
const $$ = (sel, el = document) => [...el.querySelectorAll(sel)];
const PALETTE = ["#d9480f", "#1c7ed6", "#2b8a3e", "#9c36b5", "#d6336c", "#0c8599", "#a0620a", "#5f3dc4", "#5c940d", "#e03131", "#087f5b", "#7048e8"];
const NATIVE = new URLSearchParams(location.search).has("native");

const THEMES = [
  ["original", "Original", "#ffffff", "#1d1d1f"],
  ["paper", "Paper", "#f3f0e8", "#2b2925"],
  ["sepia", "Sepia", "#f1e4c9", "#3d2f1f"],
  ["gray", "Gray", "#48484b", "#e0e0e0"],
  ["night", "Night", "#000000", "#c8c8cc"],
];
const FONTS = {
  newyork: ["New York", 'ui-serif, "New York", "Iowan Old Style", Georgia, serif'],
  iowan: ["Iowan", '"Iowan Old Style", "Palatino Linotype", Georgia, serif'],
  palatino: ["Palatino", 'Palatino, "Palatino Linotype", serif'],
  georgia: ["Georgia", "Georgia, serif"],
  charter: ["Charter", 'Charter, "Bitstream Charter", Georgia, serif'],
  sf: ["San Francisco", '-apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif'],
};
const SIZES = [14, 15, 16, 17, 18, 20, 22, 24, 27, 30];
const DEFAULT_LOOK = { theme: "original", font: "newyork", size: 5, justify: true, colorDialogue: true };

const S = {
  config: { claude: false, appearance: {} },
  look: { ...DEFAULT_LOOK },
  voices: [],
  books: [],
  filter: "all",
  book: null,          // {id, title, narrator, cast, toc, ...}
  chapterIdx: 0,
  chapter: null,       // {title, segments}
  segIdx: 0,
  playing: false,
  audio: new Audio(),  // one element for the whole session: WebKit only lets an element that already played keep playing
  audioKey: "",
  prefetched: new Set(),
  rev: 0,              // bumps whenever a voice or speaker changes, so cached audio is refetched
  speed: 1,
  gapTimer: null,
  saveTimer: null,
  pollTimer: null,
  installTimer: null,
};

async function api(path, opts = {}) {
  const headers = {};
  if (opts.json !== undefined) {
    headers["Content-Type"] = "application/json";
    opts.body = JSON.stringify(opts.json);
  }
  const res = await fetch(path, { ...opts, headers });
  if (!res.ok) {
    let msg = res.statusText;
    try { msg = (await res.json()).detail || msg; } catch {}
    throw new Error(msg);
  }
  return res.json();
}

function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") node.className = v;
    else if (k === "style") node.style.cssText = v;
    else if (k.startsWith("on")) node.addEventListener(k.slice(2), v);
    else if (v !== undefined && v !== null && v !== false) node.setAttribute(k, v === true ? "" : v);
  }
  for (const c of children.flat()) if (c !== null && c !== undefined && c !== false) node.append(c);
  return node;
}

// Show `form` in the app's dialog. Resolves to onSave(form) when saved, or null when cancelled
// (Cancel button, Escape). Handles submit/cancel directly rather than waiting for the dialog's
// "close" event, which WebKit and background tabs don't always deliver.
function showDialog(form, onSave) {
  const dlg = $("#dialog");
  dlg.replaceChildren(form);
  return new Promise((resolve) => {
    const done = (value) => {
      dlg.oncancel = null;
      form.onsubmit = null;
      if (dlg.open) dlg.close();
      resolve(value);
    };
    form.onsubmit = (e) => { e.preventDefault(); done(onSave(form)); };
    dlg.oncancel = (e) => { e.preventDefault(); done(null); };
    form.querySelectorAll("[data-cancel]").forEach((b) => (b.onclick = () => done(null)));
    dlg.showModal();
    (form.querySelector("input:not([type=checkbox]), select") || form.querySelector("button.primary, button.danger"))?.focus();
  });
}

// In-app dialog: resolves to the form's values (or true when there are no fields), or null if cancelled.
function ask({ title, text = "", fields = [], ok = "OK", cancel = "Cancel", danger = false, body = null }) {
  const inputs = fields.map((f) => {
    const input = f.options
      ? el("select", { name: f.name }, ...f.options.map(([v, label]) => el("option", { value: v, selected: v === f.value }, label)))
      : el("input", { name: f.name, type: f.type || "text", value: f.value || "", placeholder: f.placeholder || "", autocomplete: "off", spellcheck: "false" });
    return el("label", { class: "field" }, el("span", {}, f.label), input, f.help ? el("small", {}, f.help) : null);
  });
  const form = el("form", {},
    el("h3", {}, title),
    text ? el("p", { class: "muted" }, text) : null,
    body,
    ...inputs,
    el("div", { class: "dialog-actions" },
      cancel ? el("button", { class: "button", type: "button", "data-cancel": true }, cancel) : null,
      el("button", { class: `button ${danger ? "danger" : "primary"}`, type: "submit" }, ok)));
  return showDialog(form, (form) =>
    fields.length ? Object.fromEntries(fields.map((f) => [f.name, form.elements[f.name].value.trim()])) : true);
}

let toastTimer;
function toast(msg, ms = 3500) {
  const t = $("#toast");
  t.textContent = msg;
  t.classList.remove("hidden");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.add("hidden"), ms);
}

// A macOS-style popup menu next to `anchor`. items: [{label, action, danger, disabled, dot}] or "-".
function popupMenu(anchor, items) {
  const menu = $("#menu");
  menu.replaceChildren(...items.filter(Boolean).map((it) => it === "-" ? el("hr") : el("button", {
    class: it.danger ? "danger" : "", disabled: it.disabled,
    onclick: (e) => { e.stopPropagation(); closeMenu(); it.action(); },
  }, it.dot !== undefined ? el("span", { class: "dot", style: it.dot ? `--c:${it.dot}` : "" }) : null, it.label)));
  menu.classList.remove("hidden");
  const r = anchor.getBoundingClientRect();
  menu.style.left = `${Math.max(8, Math.min(r.left, innerWidth - menu.offsetWidth - 8))}px`;
  const below = r.bottom + 4;
  menu.style.top = `${below + menu.offsetHeight > innerHeight - 8 ? Math.max(8, r.top - menu.offsetHeight - 4) : below}px`;
}
function closeMenu() { $("#menu").classList.add("hidden"); }

const charById = (id) => S.book?.cast.find((c) => c.id === id);
const colorOf = (id) => {
  const i = S.book?.cast.findIndex((c) => c.id === id);
  return i >= 0 ? PALETTE[i % PALETTE.length] : "";
};

/* ------------------------------------------------------------------ library */

const FILTER_TITLES = { reading: "Reading Now", all: "All Books", finished: "Finished" };

async function showLibrary() {
  stop();
  closePopovers();
  S.book = null;
  history.replaceState(null, "", location.pathname + location.search);
  $("#reader").classList.add("hidden");
  $("#library").classList.remove("hidden");
  S.books = await api("/api/books");
  renderVoiceBanner();
  renderLibrary();
}

function renderLibrary() {
  $$(".nav-item[data-filter]").forEach((b) => b.classList.toggle("current", b.dataset.filter === S.filter));
  $("#lib-title").textContent = FILTER_TITLES[S.filter];
  const q = $("#search").value.trim().toLowerCase();
  let books = S.books.filter((b) => !q || `${b.title} ${b.author}`.toLowerCase().includes(q));
  if (S.filter === "reading") books = books.filter((b) => b.progress > 0 && !b.finished).sort((a, b) => b.opened - a.opened);
  if (S.filter === "finished") books = books.filter((b) => b.finished);
  const grid = $("#books");
  grid.replaceChildren(...books.map(bookTile));
  if (!books.length) {
    grid.append(el("div", { class: "empty" }, q ? "No books match your search."
      : S.filter === "reading" ? "Books you've started will appear here."
      : S.filter === "finished" ? "Books you finish will appear here."
      : "No books yet. Click Add Book, or drop an EPUB or text file here."));
  }
}

function hash(s) { let h = 0; for (const ch of s) h = (h * 31 + ch.charCodeAt(0)) | 0; return Math.abs(h); }
const COVER_GRADIENTS = [["#3d5a80", "#1d2d44"], ["#8d3b3b", "#4a1c1c"], ["#2f6f5e", "#163a31"], ["#6a4c93", "#35264a"], ["#9a6b2f", "#4f3516"], ["#2f6d80", "#163843"], ["#5e6b3a", "#2f361c"], ["#7a3e65", "#3d1f33"]];

function coverEl(b) {
  if (b.cover) return el("img", { src: `/api/books/${b.id}/cover`, alt: "", loading: "lazy" });
  const [g1, g2] = COVER_GRADIENTS[hash(b.title) % COVER_GRADIENTS.length];
  return el("div", { class: "gen-cover", style: `--g1:${g1};--g2:${g2}` },
    el("div", { class: "gen-title" }, b.title),
    el("div", { class: "gen-author" }, b.author || ""));
}

function bookTile(b) {
  const status = b.finished ? el("span", {}, "Finished")
    : b.progress > 0 ? el("span", {}, `${Math.max(1, Math.round(b.progress * 100))}%`)
    : el("span", { class: "badge-new" }, "NEW");
  const more = el("button", { class: "more-btn", title: "More", onclick: (e) => {
    e.stopPropagation();
    popupMenu(e.currentTarget, [
      { label: "Book Info…", action: () => bookInfo(b) },
      { label: "Update from File…", action: () => updateFromFile(b) },
      S.config.export ? { label: "Export Audiobook…", action: () => exportBook(b) } : null,
      "-",
      { label: "Remove Book…", danger: true, action: () => removeBook(b) },
    ]);
  } }, "•••");
  return el("div", { class: "tile", title: b.author ? `${b.title} by ${b.author}` : b.title },
    el("button", { class: "cover", onclick: () => openBook(b.id) }, coverEl(b)),
    el("div", { class: "tile-meta" }, status, more));
}

function bookInfo(b) {
  const row = (k, v) => [el("dt", {}, k), el("dd", {}, v)];
  return ask({
    title: b.title, cancel: null, ok: "Done",
    body: el("dl", { class: "info-grid" },
      ...row("Author", b.author || "Unknown"),
      ...row("Chapters", String(b.chapters)),
      ...row("Characters", `${b.characters} with their own voice`),
      ...row("Found by", b.analyzer === "claude" ? "Claude" : "RealBook's built-in character finder"),
      ...row("Progress", b.finished ? "Finished" : `${Math.round(b.progress * 100)}%`),
      ...row("Added", new Date(b.created * 1000).toLocaleDateString())),
  });
}

function renderVoiceBanner() {
  const box = $("#voice-banner");
  const k = S.config.kokoro;
  if (!k || k.installed || S.config.qwen?.installed || S.config.hide_voice_banner) return box.classList.add("hidden");
  box.classList.remove("hidden");
  const downloading = k.state === "downloading";
  box.replaceChildren(
    el("div", {},
      el("strong", {}, "Get natural-sounding voices"),
      el("div", { class: "muted install-status" }, downloading ? k.message
        : `Kokoro voices sound far more human than the built-in ones. Free, offline, one-time ${Math.round(k.bytes / 1e6)} MB download.`)),
    el("button", { class: "button primary", disabled: downloading, onclick: async (e) => {
      e.currentTarget.disabled = true;
      e.currentTarget.textContent = "Downloading…";
      await startInstall("kokoro");
      watchInstall(null, "kokoro");
    } }, downloading ? "Downloading…" : "Download"),
    el("button", { class: "icon", title: "Hide", onclick: async () => {
      box.classList.add("hidden");
      S.config = await api("/api/settings", { method: "PUT", json: { hide_voice_banner: true } });
    } }, "×"));
  if (downloading) watchInstall(null, "kokoro");
}

// Re-read a book from its file: adds the cover and chapter names, keeps your place when the text matches.
async function updateFromFile(b) {
  let r;
  if (window.pywebview?.api) {
    r = await window.pywebview.api.update_from_file(b.id);
  } else {
    const input = $("#source-input");
    const file = await new Promise((resolve) => { input.onchange = () => resolve(input.files[0]); input.value = ""; input.click(); });
    if (!file) return;
    toast(`Reading “${file.name}”…`, 60000);
    r = await fetch(`/api/books/${b.id}/source?filename=${encodeURIComponent(file.name)}`, { method: "POST", body: file })
      .then(async (res) => (res.ok ? res.json() : { error: (await res.json()).detail }));
  }
  if (!r) return;
  if (r.error) return toast(r.error, 6000);
  toast(r.kept_text
    ? `Updated “${r.title}”: ${r.cover ? "cover and " : ""}chapter names added. Your place is kept.`
    : `Updated “${r.title}” from the new file. Characters were found again; your place is about the same.`, 6000);
  showLibrary();
}

async function removeBook(b) {
  if (!(await ask({ title: `Remove “${b.title}”?`, text: "The book and its saved audio will be deleted from RealBook. The original file you imported is not touched.", ok: "Remove", danger: true }))) return;
  await api(`/api/books/${b.id}`, { method: "DELETE" });
  showLibrary();
}

async function upload(file) {
  if (!file) return;
  toast(`Reading “${file.name}” and finding its characters…`, 60000);
  try {
    const b = await fetch(`/api/books?filename=${encodeURIComponent(file.name)}`, { method: "POST", body: file });
    if (!b.ok) throw new Error((await b.json()).detail || "Upload failed");
    const book = await b.json();
    toast(`Added “${book.title}” with ${book.characters} voiced characters`);
    openBook(book.id);
  } catch (e) {
    toast(e.message);
  }
}

/* ------------------------------------------------------------------- reader */

async function openBook(id) {
  stop();
  closePopovers();
  const [book, voices] = await Promise.all([api(`/api/books/${id}`), api("/api/voices")]);
  S.voices = voices;
  S.book = book;
  history.replaceState(null, "", `${location.pathname}${location.search}#${id}`);
  $("#library").classList.add("hidden");
  $("#reader").classList.remove("hidden");
  $("#book-title").textContent = book.title;
  showJob(book.job);
  if (book.job?.state === "running") pollJob();
  await loadChapter(book.position.chapter || 0, book.position.segment || 0);
  renderCast();
  savePosition();
}

// The part a chapter belongs to ("Book One - DUNE"), when it isn't just the chapter itself.
const sectionOf = (c) => (c && c.section && c.section !== c.title ? c.section : "");

function renderToc() {
  const rows = [];
  let current = null;
  S.book.toc.forEach((c, i) => {
    const section = sectionOf(c);
    if (section && section !== current) {
      rows.push(el("button", { class: "toc-section", onclick: () => loadChapter(i, 0, S.playing) }, section));
    }
    current = section || c.section || null;
    rows.push(el("button", { class: `${i === S.chapterIdx ? "current" : ""} ${section ? "nested" : ""}`, onclick: () => loadChapter(i, 0, S.playing) }, c.title));
  });
  $("#toc-list").replaceChildren(...rows);
}

function togglePanel(which) {
  if (!S.book) return;
  const r = $("#reader");
  const on = r.classList.toggle(`show-${which}`);
  $(which === "toc" ? "#toc-btn" : "#cast-btn").classList.toggle("active", on);
  if (on && which === "toc") $("#toc-list .current")?.scrollIntoView({ block: "center" });
}

async function loadChapter(n, seg = 0, autoplay = false) {
  stop(false);
  S.chapterIdx = n;
  S.chapter = await api(`/api/books/${S.book.id}/chapters/${n}`);
  S.segIdx = Math.max(0, Math.min(seg, S.chapter.segments.length - 1));
  renderToc();
  renderPage();
  highlight(true);
  savePosition();  // reopening the book comes back here, even if you only browsed to it
  if (autoplay) play();
}

function jumpChapter(delta) {
  if (!S.book) return;
  const n = S.chapterIdx + delta;
  if (n >= 0 && n < S.book.toc.length) loadChapter(n, 0, S.playing);
}

function renderPage() {
  const page = $("#page");
  const scroll = page.scrollTop;
  const section = sectionOf(S.chapter);
  const inner = el("div", { class: "page-inner" },
    section ? el("div", { class: "page-section" }, section) : null,
    el("h2", {}, S.chapter.title));
  const segs = S.chapter.segments;
  let p = null, para = -1, lastWho = null;
  segs.forEach((seg, i) => {
    if (seg.para !== para) {
      p = el("p");
      inner.append(p);
      para = seg.para;
      lastWho = null;
    }
    const prev = segs[i - 1], next = segs[i + 1];
    const firstOfQuote = seg.kind === "dialogue" && !(prev && prev.kind === "dialogue" && prev.q === seg.q);
    const lastOfQuote = seg.kind === "dialogue" && !(next && next.kind === "dialogue" && next.q === seg.q);
    if (firstOfQuote && seg.speaker !== lastWho) {
      const c = charById(seg.speaker);
      p.append(el("span", {
        class: "who", style: c ? `--c:${colorOf(c.id)}` : "", title: "Who says this? Click to change",
        onclick: (e) => { e.stopPropagation(); speakerMenu(e.currentTarget, i); },
      }, c ? c.name : "?"));
      lastWho = seg.speaker;
    }
    let text = seg.text;
    if (firstOfQuote) text = "“" + text;
    if (lastOfQuote) text = text + "”";
    const cls = ["seg", seg.kind, seg.kind === "dialogue" && !seg.speaker ? "unknown" : ""].join(" ");
    p.append(el("span", {
      class: cls, "data-i": i,
      style: seg.kind === "dialogue" && seg.speaker ? `--c:${colorOf(seg.speaker)}` : null,
      onclick: () => { S.segIdx = i; play(); },
    }, text), " ");
  });
  inner.append(el("div", { class: "chapter-nav" },
    S.chapterIdx > 0 ? el("button", { onclick: () => loadChapter(S.chapterIdx - 1) }, "‹ Previous Chapter") : el("span"),
    S.chapterIdx < S.book.toc.length - 1 ? el("button", { onclick: () => loadChapter(S.chapterIdx + 1, 0, S.playing) }, "Next Chapter ›") : el("span")));
  page.replaceChildren(inner);
  page.scrollTop = scroll;
}

function highlight(jump = false) {
  $$(".seg.now").forEach((n) => n.classList.remove("now"));
  const node = $(`.seg[data-i="${S.segIdx}"]`);
  if (node) {
    node.classList.add("now");
    const page = $("#page");
    const r = node.getBoundingClientRect(), pr = page.getBoundingClientRect();
    if (jump || r.top < pr.top + 60 || r.bottom > pr.bottom - 110) {
      node.scrollIntoView({ block: "center", behavior: jump ? "auto" : "smooth" });
    }
  }
  const seg = S.chapter?.segments[S.segIdx];
  const c = seg && seg.kind === "dialogue" ? charById(seg.speaker) : null;
  const now = $("#now-speaker");
  now.textContent = c ? c.name : seg && seg.kind === "dialogue" ? "Unknown speaker" : "Narrator";
  const color = c ? colorOf(c.id) : "";
  now.style.setProperty("--c", color || "var(--page-ink)");
  $("#now-dot").style.setProperty("--c", color || "var(--page-muted)");
  $("#now-chapter").textContent = S.chapter ? [sectionOf(S.chapter), S.chapter.title].filter(Boolean).join(" · ") : "";
  $("#progress-bar").style.width = S.chapter ? `${(100 * S.segIdx) / Math.max(1, S.chapter.segments.length - 1)}%` : "0";
  if ("mediaSession" in navigator && S.chapter) {
    navigator.mediaSession.metadata = new MediaMetadata({
      title: [sectionOf(S.chapter), S.chapter.title].filter(Boolean).join(" · "), artist: S.book.title, album: "RealBook",
      artwork: S.book.cover ? [{ src: `/api/books/${S.book.id}/cover` }] : [{ src: "/static/icon-512.png", sizes: "512x512" }],
    });
  }
}

/* --------------------------------------------------------------- appearance */

function applyLook() {
  const r = $("#reader"), L = S.look;
  r.dataset.theme = L.theme;
  r.style.setProperty("--read-font", (FONTS[L.font] || FONTS.newyork)[1]);
  r.style.setProperty("--read-size", `${SIZES[L.size] ?? 20}px`);
  r.classList.toggle("justify", !!L.justify);
  r.classList.toggle("color-dialogue", !!L.colorDialogue);
}

async function setLook(patch) {
  Object.assign(S.look, patch);
  applyLook();
  if (S.chapter) highlight();
  if (!$("#aa-pop").classList.contains("hidden")) renderAa();
  S.config = await api("/api/settings", { method: "PUT", json: { appearance: S.look } }).catch(() => S.config);
}

function renderAa() {
  const L = S.look;
  const pop = $("#aa-pop");
  pop.replaceChildren(
    el("div", { class: "aa-sizes" },
      el("button", { title: "Smaller text", onclick: () => setLook({ size: Math.max(0, L.size - 1) }) }, "A"),
      el("button", { title: "Larger text", onclick: () => setLook({ size: Math.min(SIZES.length - 1, L.size + 1) }) }, "A")),
    el("div", { class: "aa-themes" }, ...THEMES.map(([id, name, bg, ink]) =>
      el("button", { class: `theme-swatch ${L.theme === id ? "current" : ""}`, onclick: () => setLook({ theme: id }) },
        el("span", { style: id === "original" ? "background:linear-gradient(135deg,#fff 50%,#1e1e1e 50%);color:#888" : `background:${bg};color:${ink}` }, "Aa"),
        el("span", {}, name)))),
    el("label", { class: "pop-row" }, el("span", {}, "Font"),
      el("select", { onchange: (e) => setLook({ font: e.target.value }) },
        ...Object.entries(FONTS).map(([id, [name]]) => el("option", { value: id, selected: id === L.font }, name)))),
    el("label", { class: "pop-row" }, el("span", {}, "Justify text"),
      el("input", { type: "checkbox", checked: L.justify, onchange: (e) => setLook({ justify: e.target.checked }) })),
    el("label", { class: "pop-row" }, el("span", {}, "Colour dialogue by character"),
      el("input", { type: "checkbox", checked: L.colorDialogue, onchange: (e) => setLook({ colorDialogue: e.target.checked }) })));
}

function toggleAa(anchor) {
  const pop = $("#aa-pop");
  if (!pop.classList.contains("hidden")) return closePopovers();
  renderAa();
  pop.classList.remove("hidden");
  const r = anchor.getBoundingClientRect();
  pop.style.top = `${r.bottom + 6}px`;
  pop.style.left = `${Math.min(innerWidth - pop.offsetWidth - 10, r.left + r.width / 2 - pop.offsetWidth / 2)}px`;
  anchor.classList.add("active");
}

function closePopovers() {
  $("#aa-pop").classList.add("hidden");
  $("#aa-btn").classList.remove("active");
  closeMenu();
}

/* ----------------------------------------------------------------- playback */

const segUrl = (ch, i) => `/api/books/${S.book.id}/audio/${ch}/${i}?r=${S.rev}`;

function setPlayingUI() {
  $("#icon-play").classList.toggle("hidden", S.playing);
  $("#icon-pause").classList.toggle("hidden", !S.playing);
}

function play() {
  if (!S.book) return;
  S.playing = true;
  setPlayingUI();
  const key = `${S.chapterIdx}:${S.segIdx}:${S.rev}`;
  if (S.audioKey === key && S.audio.paused && S.audio.currentTime > 0 && !S.audio.ended) {
    S.audio.play();
    return;
  }
  playCurrent();
}

function togglePlay() { S.playing ? pause() : play(); }

function stop(resetUI = true) {
  S.playing = false;
  clearTimeout(S.gapTimer);
  S.audio.pause();
  S.audioKey = "";
  if (resetUI) setPlayingUI();
}

function pause() {
  S.playing = false;
  clearTimeout(S.gapTimer);
  S.audio.pause();
  setPlayingUI();
}

function playCurrent() {
  clearTimeout(S.gapTimer);
  const segs = S.chapter.segments;
  if (S.segIdx >= segs.length) return nextChapter();
  highlight();
  savePosition();
  const a = S.audio;
  a.src = segUrl(S.chapterIdx, S.segIdx);
  a.defaultPlaybackRate = a.playbackRate = S.speed;
  S.audioKey = `${S.chapterIdx}:${S.segIdx}:${S.rev}`;
  a.play().catch((e) => {
    if (e.name === "NotAllowedError") { S.playing = false; setPlayingUI(); }
  });
  prefetchAhead();
}

function onEnded() {
  if (!S.playing) return;
  const segs = S.chapter.segments;
  const cur = segs[S.segIdx], next = segs[S.segIdx + 1];
  S.segIdx++;
  const gap = !next ? 0 : next.para !== cur.para ? 320 : 90;
  S.gapTimer = setTimeout(playCurrent, gap / S.speed);
}

async function nextChapter() {
  if (S.chapterIdx + 1 < S.book.toc.length) {
    await loadChapter(S.chapterIdx + 1, 0, true);
  } else {
    stop();
    toast("The end.");
  }
}

// Ask the server to synthesize the next few lines now, so each one is ready when its turn comes.
function prefetchAhead() {
  for (let k = 1; k <= 4; k++) {
    const i = S.segIdx + k;
    if (i >= S.chapter.segments.length) break;
    const url = segUrl(S.chapterIdx, i);
    if (!S.prefetched.has(url)) {
      S.prefetched.add(url);
      fetch(url + "&prefetch=1").then((r) => r.blob()).catch(() => S.prefetched.delete(url));
    }
  }
}

function step(delta) {
  if (!S.chapter) return;
  const was = S.playing;
  stop(false);
  S.segIdx = Math.max(0, Math.min(S.chapter.segments.length - 1, S.segIdx + delta));
  highlight();
  if (was) play(); else { setPlayingUI(); savePosition(); }
}

function savePosition() {
  clearTimeout(S.saveTimer);
  const id = S.book.id, pos = { chapter: S.chapterIdx, segment: S.segIdx };
  S.saveTimer = setTimeout(() => api(`/api/books/${id}/position`, { method: "PUT", json: pos }).catch(() => {}), 1200);
}

function voicesChanged() {
  S.rev++;
  S.prefetched.clear();
}

/* --------------------------------------------------------------------- cast */

function voiceSelect(current, onchange) {
  const LABEL = { en_US: "American", en_GB: "British", en_IE: "Irish", en_AU: "Australian", en_IN: "Indian", en_ZA: "South African", "en-scotland": "Scottish" };
  const groups = new Map();
  for (const v of S.voices) {
    const key = v.engine === "kokoro"
      ? (v.blend ? "Natural · blends of two voices" : `Natural · ${LABEL[v.locale] || v.locale}`)
      : `Mac · ${LABEL[v.locale] || v.locale}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(v);
  }
  const sel = el("select", { onchange: (e) => onchange(e.target.value) });
  if (isDesigned(current)) {
    sel.append(el("optgroup", { label: "Designed" }, el("option", { value: current, selected: true }, "Designed voice")));
  } else if (designing()) {
    sel.append(el("optgroup", { label: "Designed" }, el("option", { value: "designed" }, "Designed voice (from description)")));
  }
  if (!isDesigned(current) && !S.voices.some((v) => v.name === current)) {
    sel.append(el("option", { value: current, selected: true }, `${current.replace("kokoro:", "")} (not available)`));
  }
  for (const [label, vs] of groups) {
    const g = el("optgroup", { label });
    for (const v of vs) {
      const tag = v.engine === "kokoro" ? (v.grade >= 7 ? " ★" : "") : v.quality >= 3 ? " ★★" : v.quality === 2 ? " ★" : "";
      const who = v.gender === "unknown" ? "" : ` · ${v.gender}${v.age !== "adult" ? ", " + v.age : ""}`;
      g.append(el("option", { value: v.name, selected: v.name === current }, `${v.base}${tag}${who}`));
    }
    sel.append(g);
  }
  return sel;
}

function slider(label, min, max, value, fmt, onchange) {
  const out = el("span", {}, fmt(value));
  const input = el("input", { type: "range", min, max, value,
    oninput: (e) => { out.textContent = fmt(+e.target.value); },
    onchange: (e) => onchange(+e.target.value) });
  return el("label", { class: "slider" }, el("span", {}, label), input, out);
}

function sampleLine(charId) {
  const seg = S.chapter?.segments.find((s) => s.kind === "dialogue" && s.speaker === charId && s.text.length > 25);
  return seg ? seg.text : "";
}

function preview(settings, text) {
  const q = new URLSearchParams({ voice: settings.voice, rate: settings.rate, pitch_shift: settings.pitch_shift || 0, text: text || "" });
  new Audio(`/api/preview?${q}`).play().catch(() => {});
}

const DESIGNED = ["qwen", "breeze"];  // engines that make voices from descriptions
const isDesigned = (voice) => DESIGNED.some((e) => voice.startsWith(e + ":"));
const designing = () => DESIGNED.includes(S.config.voice_engine) && S.config[S.config.voice_engine]?.installed;

function voiceControls(person, who, save, text) {
  const s = { voice: person.voice, rate: person.rate, pitch_shift: person.pitch_shift || 0 };
  const commit = async (patch) => {
    Object.assign(s, patch);
    await save(s);
    voicesChanged();
    preview(s, text);
  };
  const pick = (voice) => (voice === "designed" ? designVoice(who, {}, text) : commit({ voice }));
  return [
    el("div", { class: "voice-row" },
      voiceSelect(s.voice, pick),
      el("button", { class: "button small", title: "Hear this voice", onclick: () => preview(s, text) }, "▶")),
    ...(designing() ? designControls(person, who, text) : []),
    // Designed voices get their pitch and pace from the description.
    ...(isDesigned(s.voice) ? [] : [
      slider("Pitch", -20, 20, s.pitch_shift, (v) => (v > 0 ? "+" : "") + v, (v) => commit({ pitch_shift: v })),
      slider("Speed", 110, 280, s.rate, (v) => v, (v) => commit({ rate: v })),
    ]),
  ];
}

function designControls(person, who, text) {
  const area = el("textarea", { class: "design-text", rows: 3, spellcheck: "false",
    placeholder: "e.g. An old fisherman with a rough, low voice and a strong Irish accent" }, person.designed_from || "");
  return [
    el("label", { class: "design" }, el("span", {}, "Voice description"), area),
    el("div", { class: "design-actions" },
      el("button", { class: "button small", title: "Design a voice from this description", onclick: () => designVoice(who, { description: area.value }, text) }, "Use Description"),
      el("button", { class: "button small", title: "Same description, a different voice", onclick: () => designVoice(who, { new_take: true }, text) }, "New Take"),
      person.voice_description
        ? el("button", { class: "button small", title: "Go back to the description written from the book", onclick: () => designVoice(who, { description: "" }, text) }, "Reset")
        : null),
  ];
}

async function designVoice(who, json, text) {
  const b = S.book;
  try {
    const updated = await api(`/api/books/${b.id}/design/${who}`, { method: "PUT", json });
    if (who === "narrator") b.narrator = updated; else b.cast = b.cast.map((c) => (c.id === who ? updated : c));
    voicesChanged();
    renderCast();
    toast("Designing the voice. You'll hear it in a few seconds");
    preview(updated, text);
  } catch (e) { toast(e.message); }
}

function renderCast() {
  const b = S.book;
  const narrator = el("div", { class: "char" },
    el("div", { class: "char-top" }, el("span", { class: "dot" }), el("span", { class: "char-name" }, "Narrator")),
    el("div", { class: "char-summary" }, "Reads everything outside quotation marks"),
    ...voiceControls(b.narrator, "narrator", async (s) => { b.narrator = await api(`/api/books/${b.id}/narrator`, { method: "PUT", json: s }); }, ""));
  const cards = b.cast.map((c) => {
    const meta = [c.gender !== "unknown" ? c.gender : null, c.age !== "adult" ? c.age : null, c.accent ? c.accent.replace("_", " ") : null].filter(Boolean).join(" · ");
    return el("div", { class: "char", style: `--c:${colorOf(c.id)}` },
      el("div", { class: "char-top" },
        el("span", { class: "dot" }),
        el("span", { class: "char-name" }, c.name),
        el("span", { class: "char-lines" }, `${c.lines} line${c.lines === 1 ? "" : "s"}`)),
      el("div", { class: "char-summary" }, c.summary && c.summary !== meta ? c.summary : meta || "no description found"),
      c.evidence?.length ? el("details", {}, el("summary", {}, "What the book says"), ...c.evidence.map((e) => el("blockquote", {}, e))) : null,
      ...voiceControls(c, c.id, async (s) => {
        Object.assign(c, await api(`/api/books/${b.id}/characters/${c.id}`, { method: "PUT", json: s }));
      }, sampleLine(c.id)),
      c.locked ? el("div", { class: "lock" }, "Voice set by you. Re-cast keeps it.") : null,
    );
  });
  $("#cast-list").replaceChildren(narrator, ...cards);
}

function castMenu(anchor) {
  const busy = S.book.job?.state === "running";
  popupMenu(anchor, [
    { label: "Find Characters Again", disabled: busy, action: () => analyze("heuristic") },
    { label: S.config.claude ? "Analyze with Claude…" : "Analyze with Claude (add a key in Settings)", disabled: busy || !S.config.claude, action: () => analyze("claude") },
    "-",
    { label: "Add Character…", action: () => newCharacter() },
  ]);
}

async function newCharacter() {
  const v = await ask({
    title: "New character", ok: "Add",
    fields: [
      { name: "name", label: "Name" },
      { name: "gender", label: "Gender", value: "unknown", options: [["female", "Female"], ["male", "Male"], ["unknown", "Not sure"]] },
      { name: "age", label: "Age", value: "adult", options: [["child", "Child"], ["young", "Young"], ["adult", "Adult"], ["old", "Old"]] },
    ],
  });
  if (!v || !v.name) return null;
  const c = await api(`/api/books/${S.book.id}/characters`, { method: "POST", json: v });
  S.book.cast.push(c);
  renderCast();
  return c;
}

/* ------------------------------------------------------------ speaker menu */

function speakerMenu(anchor, segI) {
  const choose = async (speaker) => {
    const r = await api(`/api/books/${S.book.id}/chapters/${S.chapterIdx}/segments/${segI}/speaker`, { method: "PUT", json: { speaker } });
    for (const id of r.changed) S.chapter.segments[id].speaker = speaker;
    S.book.cast = r.cast;
    voicesChanged();
    renderPage();
    renderCast();
    highlight();
  };
  popupMenu(anchor, [
    ...S.book.cast.map((c) => ({ label: c.name, dot: colorOf(c.id), action: () => choose(c.id) })),
    { label: "Unknown (narrator reads it)", dot: "", action: () => choose(null) },
    "-",
    { label: "New Character…", action: async () => { const c = await newCharacter(); if (c) await choose(c.id); } },
  ]);
}

/* ----------------------------------------------------------------- analysis */

function showJob(job) {
  const box = $("#job");
  if (!job) return box.classList.add("hidden");
  box.classList.remove("hidden");
  box.classList.toggle("error", job.state === "error");
  box.textContent = job.state === "running" ? `⏳ ${job.message}` : job.message;
}

async function analyze(engine) {
  const msg = engine === "claude"
    ? "Claude will read the whole book to describe each character and decide who says every line. This uses your Anthropic API credits (roughly $1–3 for a full novel). Speakers you fixed by hand will be replaced."
    : "RealBook will look for the characters again with its built-in finder. Speakers you fixed by hand will be replaced.";
  if (!(await ask({ title: engine === "claude" ? "Analyze with Claude" : "Find characters again", text: msg, ok: "Start" }))) return;
  try {
    S.book.job = await api(`/api/books/${S.book.id}/analyze`, { method: "POST", json: { engine } });
    showJob(S.book.job);
    if (!$("#reader").classList.contains("show-cast")) togglePanel("cast");
    pollJob();
  } catch (e) {
    toast(e.message);
  }
}

function pollJob() {
  clearInterval(S.pollTimer);
  const id = S.book.id;
  S.pollTimer = setInterval(async () => {
    if (S.book?.id !== id) return clearInterval(S.pollTimer);
    const b = await api(`/api/books/${id}`);
    showJob(b.job);
    S.book.job = b.job;
    if (b.job?.state !== "running") {
      clearInterval(S.pollTimer);
      if (b.job?.state === "done") {
        S.book = b;
        voicesChanged();
        await loadChapter(S.chapterIdx, S.segIdx);
        renderCast();
        toast(b.job.message);
      }
    }
  }, 1500);
}

/* ----------------------------------------------------------------- settings */

async function openSettings() {
  closePopovers();
  S.config = await api("/api/config");
  const c = S.config;
  const k = c.kokoro;
  const designedEngines = DESIGNED.map((name) => [name, c[name]]).filter(([, d]) => d);
  const status = el("p", { class: "muted small" });
  const voiceSection = el("section", { class: "settings-section" }, el("h4", {}, "Voices"));
  if (!k.installed) {
    voiceSection.append(
      el("p", { class: "muted" }, `Natural voices (Kokoro) sound far more human than the built-in Mac voices. Free, and they run offline on this Mac. One-time download of ${Math.round(k.bytes / 1e6)} MB.`),
      el("button", { class: "button primary small", type: "button", disabled: k.state === "downloading", onclick: async (e) => {
        e.currentTarget.disabled = true;
        await startInstall("kokoro");
        watchInstall(status, "kokoro");
      } }, k.state === "downloading" ? "Downloading…" : "Download Natural Voices"),
      status);
    if (k.state === "downloading" || k.state === "error") watchInstall(status, "kokoro");
  }
  if (k.installed || designedEngines.some(([, d]) => d.installed)) {
    voiceSection.append(...[
      el("label", { class: "field" }, el("span", {}, "Read books with"),
        el("select", { name: "voice_engine" },
          k.installed ? el("option", { value: "kokoro", selected: c.voice_engine === "kokoro" }, "Natural voices (Kokoro)") : null,
          ...designedEngines.filter(([, d]) => d.installed).map(([name, d]) => el("option", { value: name, selected: c.voice_engine === name }, d.label)),
          el("option", { value: "apple", selected: c.voice_engine === "apple" }, c.platform === "mac" ? "Mac system voices" : "Windows voices"))),
      k.installed ? el("label", { class: "check" }, el("input", { type: "checkbox", name: "apple_for_accents", checked: c.apple_for_accents }),
        el("span", {}, "With natural voices, use Mac voices for Scottish, Irish, Indian, Australian and South African characters, when one with that accent is installed (natural voices only do American and British)")) : null,
      el("p", { class: "muted small" }, "Changing these re-casts every book. Voices you picked by hand are kept."),
    ].filter(Boolean));
  }
  const toGet = designedEngines.filter(([, d]) => d.supported && !d.installed);
  if (toGet.length) {
    voiceSection.append(el("p", { class: "muted" }, "Designed voices make a voice for each character from how the book describes them, accents included, and you can rewrite any description. Slower than natural voices; free and offline."));
  }
  for (const [name, d] of toGet) {
    const dStatus = el("p", { class: "muted small" });
    voiceSection.append(el("div", { class: "engine-offer" },
      el("strong", {}, d.label.replace("Designed voices ", "").replace(/[()]/g, "")),
      el("p", { class: "muted small" }, `${d.speed} One-time download of ${(d.bytes / 1e9).toFixed(1)} GB.`),
      d.licence ? el("p", { class: "small" }, d.licence) : null,
      el("button", { class: "button small", type: "button", disabled: d.state === "downloading", onclick: async (e) => {
        e.currentTarget.disabled = true;
        await startInstall(name);
        watchInstall(dStatus, name);
      } }, d.state === "downloading" ? "Downloading…" : `Download ${d.label.match(/\((.*)\)/)?.[1] || "Voices"}`),
      dStatus));
    if (d.state === "downloading" || d.state === "error") watchInstall(dStatus, name);
  }
  voiceSection.append(
    el("button", { class: "button small", type: "button", onclick: () => openModelFinder() }, "Find Voice Models…"),
    el("p", { class: "muted small" }, c.platform === "mac" ? "More Mac voices: VoiceOver Utility → Speech → Voice → Customize. Pick Premium or Enhanced versions."
      : "More Windows voices: Settings → Time & language → Speech → Add voices."),
    el("button", { class: "button small", type: "button", onclick: () => api("/api/open-voice-settings", { method: "POST" }).catch((e) => toast(e.message)) },
      c.platform === "mac" ? "Open VoiceOver Utility" : "Open Speech Settings"));

  const remoteSection = el("section", { class: "settings-section" }, el("h4", {}, "Listen on Other Devices"));
  const remoteBox = el("div");
  const showRemote = (r) => {
    const toggle = (on) => async () => {
      try { showRemote(await api("/api/remote", { method: "POST", json: { enabled: on } })); } catch (e) { toast(e.message); }
    };
    const parts = [el("p", { class: "muted small" }, "Read and listen on your phone, tablet or another computer on the same Wi‑Fi. This computer makes the voices, so it needs to be on; it stays awake while something is playing.")];
    if (r.running && r.url) {
      const qr = el("div", { class: "remote-qr" });
      qr.innerHTML = r.qr;  // SVG made by RealBook's own server
      parts.push(qr,
        el("p", { class: "small" }, "Scan with your phone's camera, or open this address: ", el("code", { class: "remote-url" }, r.url)),
        el("p", { class: "muted small" }, "Anyone with this link on your network can listen to your books. On iPhone, use Share → Add to Home Screen for an app icon."),
        el("div", { class: "design-actions" },
          el("button", { class: "button small", type: "button", onclick: toggle(false) }, "Turn Off"),
          el("button", { class: "button small", type: "button", title: "Devices paired with the old link stop working", onclick: async () => showRemote(await api("/api/remote/reset", { method: "POST" })) }, "New Link")));
    } else if (r.running) {
      parts.push(el("p", { class: "muted small" }, "This computer isn't connected to a network."), el("button", { class: "button small", type: "button", onclick: toggle(false) }, "Turn Off"));
    } else {
      parts.push(el("button", { class: "button small", type: "button", onclick: toggle(true) }, "Turn On"));
    }
    remoteBox.replaceChildren(...parts);
  };
  remoteSection.append(remoteBox);
  api("/api/remote").then(showRemote).catch(() => remoteSection.remove());

  const claudeSection = el("section", { class: "settings-section" }, el("h4", {}, "Claude (optional)"));
  if (c.key_source === "env") {
    claudeSection.append(el("p", { class: "muted small" }, "Enabled through the ANTHROPIC_API_KEY environment variable."));
  } else {
    claudeSection.append(el("label", { class: "field" }, el("span", {}, "Anthropic API key"),
      el("input", { name: "key", type: "password", autocomplete: "off", placeholder: c.claude ? "Saved. Paste a new key to replace it" : "sk-ant-…" }),
      el("small", {}, "Enables “Analyze with Claude” for more accurate characters. Stored only on this Mac.")));
    if (c.key_source === "settings") {
      claudeSection.append(el("button", { class: "button small", type: "button", onclick: async () => {
        S.config = await api("/api/settings", { method: "PUT", json: { anthropic_api_key: "" } });
        form.querySelector("[data-cancel]").click();
        toast("Claude API key removed");
      } }, "Remove Saved Key"));
    }
  }

  const form = el("form", {},
    el("h3", {}, "Settings"), voiceSection, remoteSection, claudeSection,
    el("div", { class: "dialog-actions" },
      el("button", { class: "button", type: "button", "data-cancel": true }, "Cancel"),
      el("button", { class: "button primary", type: "submit" }, "Save")));
  const patch = await showDialog(form, (form) => {
    const f = form.elements, out = {};
    if (f.key && f.key.value.trim()) out.anthropic_api_key = f.key.value.trim();
    if (f.voice_engine && f.voice_engine.value !== c.voice_engine) out.voice_engine = f.voice_engine.value;
    if (f.apple_for_accents && f.apple_for_accents.checked !== c.apple_for_accents) out.apple_for_accents = f.apple_for_accents.checked;
    return out;
  });
  clearInterval(S.installTimer);
  if (!patch || !Object.keys(patch).length) return;
  try {
    S.config = await api("/api/settings", { method: "PUT", json: patch });
    if (patch.anthropic_api_key) toast("API key saved. “Analyze with Claude” is now available");
    if (patch.voice_engine || "apple_for_accents" in patch) { toast("Voices re-cast in every book"); await refreshCast(); }
  } catch (e) { toast(e.message); }
}

/* ------------------------------------------------------------------ export */

// Make an .m4b audiobook of the whole book, to play offline in any audiobook app on any device.
function exportBook(b) {
  closePopovers();
  const body = el("div");
  const size = (n) => (n >= 1e9 ? (n / 1e9).toFixed(1) + " GB" : Math.round(n / 1e6) + " MB");
  let timer;
  const show = (st) => {
    const parts = [];
    if (st.state === "running") {
      const pct = st.total ? Math.floor((100 * st.done) / st.total) : 0;
      parts.push(el("div", { class: "export-bar" }, el("div", { style: `width:${pct}%` })), el("p", { class: "muted small" }, st.message),
        el("button", { class: "button small", type: "button", onclick: async () => show(await api(`/api/books/${b.id}/export/cancel`, { method: "POST" })) }, "Cancel Export"));
    } else {
      if (st.message && st.state !== "done") parts.push(el("p", { class: st.state === "error" ? "error small" : "muted small" }, st.message));
      if (st.file) {
        parts.push(el("p", { class: "small" }, `${st.state === "done" ? st.message + ". " : ""}“${st.file}” (${size(st.bytes)}), made ${new Date(st.made * 1000).toLocaleString()}.`),
          el("div", { class: "design-actions" },
            S.config.remote || !window.pywebview
              ? el("a", { class: "button small primary", href: `/api/books/${b.id}/export/file`, download: st.file }, "Download")
              : el("button", { class: "button small primary", type: "button", onclick: () => api(`/api/books/${b.id}/export/reveal`, { method: "POST" }) }, "Show in Finder"),
            el("button", { class: "button small", type: "button", onclick: start }, "Export Again")),
          el("p", { class: "muted small" }, "On iPhone, AirDrop or download it and open it in Books. On Android or Windows, copy it to the device and open it in an audiobook app (e.g. Smart AudioBook Player, VLC)."));
      } else {
        parts.push(el("button", { class: "button small primary", type: "button", onclick: start }, "Export"));
      }
    }
    body.replaceChildren(...parts);
    clearTimeout(timer);
    if (st.state === "running") timer = setTimeout(async () => { if ($("#dialog").open) show(await api(`/api/books/${b.id}/export`)); }, 1000);
  };
  const start = async () => {
    try { show(await api(`/api/books/${b.id}/export`, { method: "POST" })); } catch (e) { toast(e.message); }
  };
  const form = el("form", {},
    el("h3", {}, "Export Audiobook"),
    el("p", { class: "muted small" }, `Makes “${b.title}” into an .m4b audiobook with chapters, read in the voices from the Cast. It plays offline in any audiobook app on iPhone, Android or Windows. Lines you've already listened to are reused; the rest are made now, so a long book can take hours. You can keep reading meanwhile, and closing this window doesn't stop it.`),
    body,
    el("div", { class: "dialog-actions" }, el("button", { class: "button", type: "button", "data-cancel": true }, "Close")));
  showDialog(form, () => null).then(() => clearTimeout(timer));
  api(`/api/books/${b.id}/export`).then(show).catch((e) => toast(e.message));
}

/* ------------------------------------------------------------ model finder */

// Browse text-to-speech models on Hugging Face, to see whether something better than the current engines is out.
function openModelFinder() {
  closePopovers();
  const list = el("div", { class: "models" });
  const q = el("input", { type: "search", placeholder: "Search models, e.g. voice design", autocomplete: "off", spellcheck: "false" });
  const sort = el("select", {},
    el("option", { value: "trending" }, "Trending"), el("option", { value: "likes" }, "Most liked"),
    el("option", { value: "downloads" }, "Most downloaded"), el("option", { value: "new" }, "Newest"));
  const english = el("input", { type: "checkbox", checked: true });
  const mac = el("input", { type: "checkbox" });
  const fmt = (n) => (n >= 1e6 ? (n / 1e6).toFixed(1) + "M" : n >= 1e3 ? (n / 1e3).toFixed(1) + "k" : String(n));
  const date = (d) => (d ? new Date(d).toLocaleDateString(undefined, { day: "numeric", month: "short", year: "numeric" }) : "");
  const open = (url) => api("/api/open-link", { method: "POST", json: { url } }).catch((e) => toast(e.message));
  let results = [], seq = 0;
  const render = () => {
    const shown = results.filter((m) => !mac.checked || m.mlx || m.in_realbook);
    list.replaceChildren(...(shown.length ? shown.map((m) => {
      const [owner, name] = m.id.split("/");
      const badges = [
        m.in_realbook ? el("span", { class: "badge used" }, `In RealBook (${m.in_realbook})`) : null,
        m.mlx ? el("span", { class: "badge good", title: "An MLX version exists, which runs fast on Apple silicon Macs" }, "Runs on Mac") : null,
        ...m.features.map((f) => el("span", { class: f === "Voice design" ? "badge good" : "badge" }, f)),
        el("span", { class: /^(apache|mit|bsd|cc-by-4|cc0)/.test(m.licence) ? "badge" : "badge warn", title: "Licence" }, m.licence),
        m.gated ? el("span", { class: "badge warn", title: "You must accept terms on Hugging Face to download it" }, "Gated") : null,
      ];
      return el("div", { class: "model" },
        el("div", { class: "model-top" },
          el("a", { href: m.url, class: "model-name", onclick: (e) => { e.preventDefault(); open(m.url); } }, name, el("span", { class: "muted" }, ` by ${owner}`)),
          el("span", { class: "model-stats muted" }, `♥ ${fmt(m.likes)} · ↓ ${fmt(m.downloads)}`)),
        el("div", { class: "badges" }, ...badges),
        el("div", { class: "muted small" }, `Released ${date(m.created)}${m.updated ? ` · updated ${date(m.updated)}` : ""}${m.languages > 1 ? ` · ${m.languages} languages` : ""}`));
    }) : [el("p", { class: "muted" }, "No models match.")]));
  };
  const load = async () => {
    const mine = ++seq;
    list.replaceChildren(el("p", { class: "muted" }, "Searching Hugging Face…"));
    try {
      const r = await api(`/api/models/search?${new URLSearchParams({ q: q.value, sort: sort.value, english: english.checked })}`);
      if (mine === seq) { results = r; render(); }
    } catch (e) { if (mine === seq) list.replaceChildren(el("p", { class: "muted" }, e.message)); }
  };
  let timer;
  q.oninput = () => { clearTimeout(timer); timer = setTimeout(load, 400); };
  sort.onchange = english.onchange = load;
  mac.onchange = render;
  const form = el("form", { class: "finder" },
    el("h3", {}, "Find Voice Models"),
    el("p", { class: "muted small" }, "New open speech models from Hugging Face. Good signs for RealBook: “Voice design” (voices from a description), “Runs on Mac”, and an open licence such as apache-2.0 or mit. To hear models side by side, try the ",
      el("a", { href: "#", onclick: (e) => { e.preventDefault(); open("https://huggingface.co/spaces/TTS-AGI/TTS-Arena-V2"); } }, "TTS Arena"), "."),
    el("div", { class: "finder-bar" }, q, sort),
    el("div", { class: "finder-checks" },
      el("label", { class: "check" }, english, el("span", {}, "English")),
      el("label", { class: "check" }, mac, el("span", {}, "Runs on Mac only"))),
    list,
    el("div", { class: "dialog-actions" }, el("button", { class: "button primary", type: "button", "data-cancel": true }, "Done")));
  showDialog(form, () => null);
  load();
}

// `which` is "kokoro" (natural voices) or a designed-voice engine ("qwen", "breeze").
async function startInstall(which) {
  try {
    S.config[which] = await api(`/api/${which}/install`, { method: "POST" });
  } catch (e) { toast(e.message); }
}

// Poll the download; `target` is a status line to update. When it finishes, every book is re-cast.
function watchInstall(target, which) {
  clearInterval(S.installTimer);
  S.installTimer = setInterval(async () => {
    S.config = await api("/api/config");
    const k = S.config[which];
    if (which === "kokoro") $$(".install-status").forEach((n) => (n.textContent = k.message));
    if (target) target.textContent = k.message;
    if (k.state !== "downloading") {
      clearInterval(S.installTimer);
      if (k.installed) {
        $("#dialog [data-cancel]")?.click();
        toast(DESIGNED.includes(which) ? `${S.config[which].label} installed. Every book has been re-cast with them`
          : "Natural voices installed. Every book has been re-cast with them", 6000);
        await refreshCast();
        if (!S.book) showLibrary();
      }
    }
  }, 1000);
}

// Pick up a server-side re-cast: new voices for the narrator and cast of the open book.
async function refreshCast() {
  S.voices = await api("/api/voices");
  if (!S.book) return;
  const b = await api(`/api/books/${S.book.id}`);
  S.book.narrator = b.narrator;
  S.book.cast = b.cast;
  voicesChanged();
  renderCast();
  renderPage();
  highlight();
}

/* -------------------------------------------------------------------- wiring */

if (NATIVE) document.body.classList.add("native", new URLSearchParams(location.search).get("native") === "windows" ? "windows" : "mac");
$$("[data-action=settings]").forEach((b) => (b.onclick = openSettings));
$$(".nav-item[data-filter]").forEach((b) => (b.onclick = () => { S.filter = b.dataset.filter; renderLibrary(); }));
$("#search").oninput = renderLibrary;
$("#file-input").onchange = (e) => { upload(e.target.files[0]); e.target.value = ""; };
// In the app, use the native Open sheet: it also accepts EPUB folders, which a web file input can't.
$("#add-book").onclick = (e) => { if (window.pywebview?.api) { e.preventDefault(); window.pywebview.api.add_books(); } };
$("#back").onclick = showLibrary;
$("#toc-btn").onclick = () => togglePanel("toc");
$("#cast-btn").onclick = () => togglePanel("cast");
$("#aa-btn").onclick = (e) => { e.stopPropagation(); toggleAa(e.currentTarget); };
$("#cast-more").onclick = (e) => { e.stopPropagation(); castMenu(e.currentTarget); };
$("#recast").onclick = async () => {
  const [r, voices] = await Promise.all([api(`/api/books/${S.book.id}/recast`, { method: "POST" }), api("/api/voices")]);
  S.voices = voices;
  S.book.narrator = r.narrator;
  S.book.cast = r.cast;
  voicesChanged();
  renderCast();
  toast("Voices re-cast");
};
$("#page").addEventListener("scroll", (e) => $("#reader").classList.toggle("scrolled", e.target.scrollTop > 8), { passive: true });
$("#play").onclick = togglePlay;
$("#prev").onclick = () => step(-1);
$("#next").onclick = () => step(1);
$("#speed").onchange = (e) => { S.speed = +e.target.value; S.audio.defaultPlaybackRate = S.audio.playbackRate = S.speed; };
S.audio.preload = "auto";
S.audio.addEventListener("waiting", () => $("#play").classList.add("loading"));
S.audio.addEventListener("playing", () => $("#play").classList.remove("loading"));
S.audio.addEventListener("pause", () => $("#play").classList.remove("loading"));
S.audio.onended = onEnded;
S.audio.onerror = () => { if (S.playing) { toast("Couldn't make audio for this line; skipping it"); onEnded(); } };
document.addEventListener("click", (e) => {
  if (!$("#menu").contains(e.target)) closeMenu();
  if (!$("#aa-pop").contains(e.target) && e.target !== $("#aa-btn")) { $("#aa-pop").classList.add("hidden"); $("#aa-btn").classList.remove("active"); }
});
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") return closePopovers();
  if (!S.book || $("#dialog").open || e.metaKey || ["INPUT", "SELECT", "TEXTAREA"].includes(document.activeElement?.tagName)) return;
  if (e.code === "Space") { e.preventDefault(); togglePlay(); }
  else if (e.key === "ArrowRight") step(1);
  else if (e.key === "ArrowLeft") step(-1);
});
let dragDepth = 0;
document.addEventListener("dragenter", (e) => { e.preventDefault(); if (!S.book) { dragDepth++; document.body.classList.add("dragging"); } });
document.addEventListener("dragleave", () => { if (--dragDepth <= 0) { dragDepth = 0; document.body.classList.remove("dragging"); } });
document.addEventListener("dragover", (e) => e.preventDefault());
document.addEventListener("drop", (e) => {
  e.preventDefault();
  dragDepth = 0;
  document.body.classList.remove("dragging");
  if (!S.book) upload(e.dataTransfer.files[0]);
});
if ("mediaSession" in navigator) {
  navigator.mediaSession.setActionHandler("play", play);
  navigator.mediaSession.setActionHandler("pause", pause);
  navigator.mediaSession.setActionHandler("nexttrack", () => step(1));
  navigator.mediaSession.setActionHandler("previoustrack", () => step(-1));
}

(async function init() {
  S.config = await api("/api/config");
  if (S.config.remote) document.body.classList.add("remote");
  if (!S.config.export) document.body.classList.add("no-export");
  S.look = { ...DEFAULT_LOOK, ...(S.config.appearance || {}) };
  applyLook();
  const books = await api("/api/books");
  S.filter = books.some((b) => b.progress > 0 && !b.finished) ? "reading" : "all";
  const id = location.hash.slice(1);
  if (id) {
    try { return await openBook(id); } catch {}
  }
  showLibrary();
})();
