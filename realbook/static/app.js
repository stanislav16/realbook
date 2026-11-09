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
const DEFAULT_LOOK = { theme: "original", font: "newyork", size: 5, justify: true, colorDialogue: true, showText: false };
const SPEEDS = [0.8, 1, 1.15, 1.3, 1.5, 1.75, 2];

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
  following: true,
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
      dlg.oncancel = dlg.onpointerdown = dlg.onpointerup = null;
      form.onsubmit = null;
      if (dlg.open) dlg.close();
      resolve(value);
    };
    form.onsubmit = (e) => { e.preventDefault(); done(onSave(form)); };
    dlg.oncancel = (e) => { e.preventDefault(); done(null); };
    // Pressing outside the dialog closes it, unless something has been typed or changed in it.
    let dirty = false, outside = false;
    const beyond = (e) => { const r = dlg.getBoundingClientRect(); return e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom; };
    form.addEventListener("input", () => { dirty = true; });
    form.addEventListener("change", () => { dirty = true; });
    dlg.onpointerdown = (e) => { outside = beyond(e); };
    dlg.onpointerup = (e) => { if (outside && beyond(e) && !dirty) done(null); outside = false; };
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

// A macOS-style popup menu next to `anchor`. items: [{label, action, danger, disabled, dot, note, find}] or "-".
// With `search`, a field on top filters the items that have `find` (the text to match); Return picks the first.
function popupMenu(anchor, items, { search = false } = {}) {
  const menu = $("#menu");
  if (!menu.classList.contains("hidden") && S.menuAnchor === anchor) return closeMenu();  // its button again: closes it
  closePopovers();
  S.menuAnchor = anchor;
  const buttons = items.filter(Boolean).map((it) => it === "-" ? el("hr") : el("button", {
    class: it.danger ? "danger" : "", disabled: it.disabled, "data-find": it.find?.toLowerCase(),
    onclick: (e) => { e.stopPropagation(); closeMenu(); it.action(); },
  }, it.dot !== undefined ? el("span", { class: "dot", style: it.dot ? `--c:${it.dot}` : "" }) : null, it.label,
    it.note ? el("span", { class: "menu-note" }, it.note) : null));
  const field = search ? el("input", { class: "search-field menu-search", type: "search", placeholder: "Search", autocomplete: "off", spellcheck: "false",
    oninput: (e) => {
      const q = e.target.value.trim().toLowerCase();
      for (const b of buttons) {
        if (b.dataset.find !== undefined) b.hidden = !!q && !b.dataset.find.includes(q);
        else if (b.tagName === "HR") b.hidden = !!q;
      }
    },
    onkeydown: (e) => {
      if (e.key === "Enter") { e.preventDefault(); buttons.find((b) => b.tagName === "BUTTON" && !b.hidden && b.dataset.find !== undefined)?.click(); }
    } }) : null;
  menu.replaceChildren(...(field ? [field] : []), ...buttons);
  menu.style.left = menu.style.top = "0";  // measured at full width, wherever it last was
  menu.classList.remove("hidden");
  const r = anchor.getBoundingClientRect();
  const left = Math.max(8, Math.min(r.left, innerWidth - menu.offsetWidth - 8));
  menu.style.left = `${left}px`;
  const below = r.bottom + 4, above = below + menu.offsetHeight > innerHeight - 8;
  menu.style.top = `${above ? Math.max(8, r.top - menu.offsetHeight - 4) : below}px`;
  menu.style.transformOrigin = `${r.left + r.width / 2 - left}px ${above ? "100%" : "0"}`;  // it grows out of its button
  field?.focus();
}
function closeMenu() { $("#menu").classList.add("hidden"); S.menuAnchor = null; }

const charById = (id) => S.book?.cast.find((c) => c.id === id);
const colorOf = (id) => {
  const i = S.book?.cast.findIndex((c) => c.id === id);
  return i >= 0 ? PALETTE[i % PALETTE.length] : "";
};

/* ------------------------------------------------------------------ library */

const FILTER_TITLES = { reading: "Reading Now", all: "All Books", finished: "Finished", phone: "Listen on iPhone" };

async function showLibrary() {
  stop();
  closePopovers();
  closePanels();
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
  clearTimeout(S.phoneTimer);
  if (S.filter === "phone") {
    // Straight to the tab (as it last looked), never the library's covers in the tab's layout.
    $("#books").replaceChildren(S.phonePage || el("div", { class: "phone-page" }));
    renderContinue(null);
    $("#library").classList.add("phone-view");
    return renderPhone();
  }
  $("#library").classList.remove("phone-view");
  const q = $("#search").value.trim().toLowerCase();
  let books = S.books.filter((b) => !q || `${b.title} ${b.author}`.toLowerCase().includes(q));
  if (S.filter === "reading") books = books.filter((b) => b.progress > 0 && !b.finished).sort((a, b) => b.opened - a.opened);
  if (S.filter === "finished") books = books.filter((b) => b.finished);
  const grid = $("#books");
  grid.replaceChildren(...books.map(bookTile));
  renderContinue(q ? null : S.books.filter((b) => b.progress > 0 && !b.finished).sort((a, b) => b.opened - a.opened)[0]);
  if (!books.length) {
    grid.append(el("div", { class: "empty" }, q ? "No books match your search."
      : S.filter === "reading" ? "Books you've started will appear here."
      : S.filter === "finished" ? "Books you finish will appear here."
      : "No books yet. Click Add Book, or drop an EPUB or text file here."));
  }
}

// The book you're in, at the top of the library, to carry on with one click.
function renderContinue(b) {
  const box = $("#continue");
  if (!b || S.filter === "phone" || S.filter === "finished") return box.replaceChildren();
  const pct = Math.max(1, Math.round(b.progress * 100));
  box.replaceChildren(el("div", { class: "continue" },
    el("button", { class: "cover", onclick: () => openBook(b.id) }, coverEl(b)),
    el("div", { class: "continue-info" },
      el("div", { class: "continue-label" }, "Continue listening"),
      el("div", { class: "continue-title" }, b.title),
      el("div", { class: "continue-meta" }, [b.author, `Chapter ${b.position.chapter + 1} of ${b.chapters}`, `${pct}%`].filter(Boolean).join(" · ")),
      el("div", { class: "track" }, el("b", { style: `width:${pct}%` })),
      el("button", { class: "button primary", type: "button", onclick: async () => { await openBook(b.id); play(); } }, "▶︎  Resume"))));
}

/* ------------------------------------------------------------- iPhone tab */

const size = (n) => (n >= 1e9 ? (n / 1e9).toFixed(1) + " GB" : Math.round(n / 1e6) + " MB");

// Turning iPhone access on and off, the pairing code, and each book's offline copy (its export).
async function renderPhone() {
  const grid = $("#books");
  let r, books, ahead;
  try {
    [r, books, ahead] = await Promise.all([api("/api/remote"), api("/api/phone/books"), api("/api/ahead")]);
  } catch (e) {
    return grid.replaceChildren(el("div", { class: "empty" }, e.message));
  }
  if (S.filter !== "phone") return;
  // While an offline copy is being made this runs every 2 s: redraw only when something changed,
  // so the covers don't flicker.
  const state = JSON.stringify([r, books, ahead]);
  const unchanged = state === S.phoneState && S.phonePage?.isConnected;
  S.phoneState = state;
  const refresh = () => { if (S.filter === "phone" && !$("#library").classList.contains("hidden")) renderPhone(); };
  const toggle = (on) => async () => {
    try { await api("/api/remote", { method: "POST", json: { enabled: on } }); refresh(); } catch (e) { toast(e.message); }
  };

  const pairing = el("section", { class: "phone-card" }, el("h4", {}, "Pair your iPhone"));
  if (r.running && r.url) {
    const qr = el("div", { class: "remote-qr" });
    qr.innerHTML = r.qr;  // SVG made by RealBook's own server
    pairing.append(el("div", { class: "phone-pair" }, qr, el("div", {},
      el("p", {}, "In the RealBook app on your iPhone, tap Pair and scan this code."),
      el("p", { class: "muted small" }, "Or scan it with the Camera to listen in Safari, live from this Mac. Anyone with this code on your network can listen to your books."),
      el("div", { class: "design-actions" },
        el("button", { class: "button small", type: "button", onclick: toggle(false) }, "Turn Off"),
        el("button", { class: "button small", type: "button", title: "Devices paired with the old code stop working", onclick: async () => { await api("/api/remote/reset", { method: "POST" }); refresh(); } }, "New Code")))));
  } else if (r.running) {
    pairing.append(el("p", { class: "muted small" }, "This Mac isn't connected to a network."), el("button", { class: "button small", type: "button", onclick: toggle(false) }, "Turn Off"));
  } else {
    pairing.append(el("p", { class: "muted small" }, "Let your iPhone reach RealBook over your Wi‑Fi, to download books and keep your place in step with this Mac."),
      el("button", { class: "button primary", type: "button", onclick: toggle(true) }, "Turn On"));
  }

  const making = ahead.enabled && (ahead.state === "making" || ahead.state === "battery");
  const aheadNote = !ahead.enabled ? "Off. The iPhone plays live, and offline copies still work."
    : ahead.state === "making" ? `Making the next hours of “${ahead.title}” for your iPhone: ${ahead.done} of ${ahead.total} lines. Your listening always goes first.`
    : ahead.state === "battery" ? `Waiting for this Mac to be plugged in, to make the next hours of “${ahead.title}”.`
    : ahead.state === "error" ? `Couldn't make some lines of “${ahead.title}”. It tries again the next time your iPhone connects.`
    : ahead.title ? `The next hours of “${ahead.title}” are ready: ${ahead.total} lines.`
    : "Starts by itself when you open RealBook on your iPhone.";
  const away = el("section", { class: "phone-card" }, el("h4", {}, "Listening away from this computer"),
    el("p", { class: "muted small" }, "Your iPhone saves the next 4 hours of the book you're listening to, whenever it can reach this Mac, so you can leave without an offline copy. When a voice or a line changes, only that line is made and saved again."),
    el("div", { class: "phone-row" }, el("div", { class: "phone-info" }, el("span", { class: "muted small" }, aheadNote)),
      el("button", { class: "button small", type: "button", onclick: async () => {
        try { await api("/api/ahead", { method: "POST", json: { enabled: !ahead.enabled } }); refresh(); } catch (e) { toast(e.message); }
      } }, ahead.enabled ? "Turn Off" : "Turn On")));
  const running = making || books.some((b) => b.export.state === "running");
  const rows = books.map((b) => {
    const x = b.export;
    const start = async () => { try { await api(`/api/books/${b.id}/export`, { method: "POST" }); refresh(); } catch (e) { toast(e.message); } };
    let state, action = null;
    if (x.state === "running") {
      const pct = x.total ? Math.round((100 * x.done) / x.total) : 0;
      state = el("div", { class: "phone-progress" }, el("div", { class: "export-bar" }, el("div", { style: `width:${pct}%` })), el("span", { class: "muted small" }, x.message));
      action = el("button", { class: "button small", type: "button", onclick: async () => { await api(`/api/books/${b.id}/export/cancel`, { method: "POST" }); refresh(); } }, "Cancel");
    } else if (x.file && x.phone) {
      state = el("span", { class: "muted small" }, `Ready to download · ${size(x.bytes)} · made ${new Date(x.made * 1000).toLocaleDateString()}`);
      action = el("button", { class: "button small", type: "button", title: "Make it again, with the current voices", onclick: start }, "Update");
    } else {
      state = el("span", { class: "muted small" }, x.state === "error" ? x.message : x.file ? "Made before the iPhone app; make it again to download it" : "Not made yet");
      action = el("button", { class: "button small primary", type: "button", onclick: start }, "Make Offline Copy");
    }
    return el("div", { class: "phone-row" }, el("div", { class: "phone-cover" }, coverEl(b)),
      el("div", { class: "phone-info" }, el("div", { class: "phone-title" }, b.title), state), action);
  });
  const copies = el("section", { class: "phone-card" }, el("h4", {}, "Offline copies"),
    el("p", { class: "muted small" }, "The iPhone app plays a book offline from its offline copy: the whole book made into audio once, with the current voices. Making one takes as long as the voices need for lines you haven't listened to yet, so a long book can take hours; this Mac needs to stay on meanwhile."),
    ...rows);
  if (!unchanged) {
    S.phonePage = el("div", { class: "phone-page" }, pairing, away, copies);
    grid.replaceChildren(S.phonePage);
  }
  if (running) S.phoneTimer = setTimeout(refresh, 2000);
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
  const pct = Math.max(1, Math.round(b.progress * 100));
  const status = b.finished ? el("span", {}, "Finished")
    : b.progress > 0 ? el("span", { class: "tile-progress", title: `${pct}% listened` },
      el("span", { class: "track" }, el("b", { style: `width:${pct}%` })), `${pct}%`)
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
  closePanels();
  const [book, voices] = await Promise.all([api(`/api/books/${id}`), api("/api/voices")]);
  S.voices = voices;
  S.book = book;
  $("#cast-search").value = "";
  history.replaceState(null, "", `${location.pathname}${location.search}#${id}`);
  $("#library").classList.add("hidden");
  $("#reader").classList.remove("hidden");
  $("#book-title").textContent = book.title;
  // The cover at its own shape, so none of it is cropped when it's this big.
  const cover = coverEl(book), frame = $("#now-cover");
  frame.style.removeProperty("--ratio");
  if (cover.tagName === "IMG") cover.onload = () => frame.style.setProperty("--ratio", cover.naturalWidth / cover.naturalHeight);
  frame.replaceChildren(cover);
  $("#np-title").textContent = book.title;
  const [g1, g2] = COVER_GRADIENTS[hash(book.title) % COVER_GRADIENTS.length];
  $("#np-backdrop").style.backgroundImage = book.cover ? `url("/api/books/${book.id}/cover")` : `linear-gradient(160deg, ${g1}, ${g2})`;
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
  let current = null, part = null;
  const add = (row) => (part ? part.append(row) : rows.push(row));
  // Each part is its own block, so its heading stays in view only while its chapters do.
  const startPart = () => {
    part = el("div", { class: "toc-part" });
    rows.push(part);
  };
  S.book.toc.forEach((c, i) => {
    const section = sectionOf(c);
    // A chapter named after its part, with more chapters under it, is that part's heading.
    const heading = !section && c.section && S.book.toc[i + 1]?.section === c.section;
    if (section !== current && section) {
      startPart();
      add(el("button", { class: "toc-section", onclick: () => pickChapter(i) }, section));
    } else if (heading) {
      startPart();
    } else if (!section) {
      part = null;
    }
    current = section || c.section || null;
    add(el("button", { class: `${i === S.chapterIdx ? "current" : ""} ${section ? "nested" : ""} ${heading ? "toc-section" : ""}`, onclick: () => pickChapter(i) }, c.title));
  });
  $("#toc-list").replaceChildren(...rows);
}

function togglePanel(which) {
  if (!S.book) return;
  const r = $("#reader");
  const on = r.classList.toggle(`show-${which}`);
  if (which === "toc") {
    $("#toc-btn").classList.toggle("on", on);
    const list = $("#toc"), current = $("#toc-list .current");
    list.style.setProperty("--toc-head", `${list.querySelector(".panel-head").offsetHeight}px`);
    if (on && current) list.scrollTop = current.offsetTop - list.clientHeight / 2;
  }
}

function closePanels() {
  $("#reader").classList.remove("show-toc", "show-cast");
  $("#toc-btn").classList.remove("on");
}

function pickChapter(i) {
  closePanels();
  follow();
  loadChapter(i, 0, S.playing);
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
      onclick: () => { follow(); S.segIdx = i; play(); },
    }, text), " ");
  });
  inner.append(el("div", { class: "chapter-nav" },
    S.chapterIdx > 0 ? el("button", { onclick: () => loadChapter(S.chapterIdx - 1) }, "‹ Previous Chapter") : el("span"),
    S.chapterIdx < S.book.toc.length - 1 ? el("button", { onclick: () => loadChapter(S.chapterIdx + 1, 0, S.playing) }, "Next Chapter ›") : el("span")));
  page.replaceChildren(inner);
  page.scrollTop = scroll;
}

// Keeps the line being read in view, unless the reader has scrolled away to look at something else.
function follow() {
  clearTimeout(S.followTimer);
  S.following = true;
  $("#follow-btn").classList.add("hidden");
}

function scrolledAway() {
  S.following = false;
  clearTimeout(S.scrollCheck);
  $("#follow-btn").classList.remove("hidden");
  clearTimeout(S.followTimer);
  // Carry on following a little after the scrolling stops, if the book is playing.
  S.followTimer = setTimeout(function again() {
    if (!S.playing) { S.followTimer = setTimeout(again, 2000); return; }
    follow();
    highlight();
  }, 8000);
}

function scrollToLine(node, jump) {
  const page = $("#page");
  if (!page.clientHeight) return;  // on the cover view
  const r = node.getBoundingClientRect(), pr = page.getBoundingClientRect();
  if (!jump && r.top >= pr.top + 60 && r.bottom <= pr.bottom - 60) return;
  // Only the page moves: scrollIntoView would also move anything around it that can scroll.
  const top = Math.max(0, Math.min(page.scrollHeight - page.clientHeight, page.scrollTop + r.top - pr.top - Math.max(40, (pr.height - r.height) * 0.3)));
  clearTimeout(S.scrollCheck);
  page.scrollTo({ top, behavior: jump || matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth" });
  // A smooth scroll can stall, never moving, while the window isn't being drawn (behind another
  // window, say). So if the page hasn't got there shortly after, put it there.
  if (!jump) S.scrollCheck = setTimeout(() => { if (S.following && Math.abs(page.scrollTop - top) > 2) page.scrollTop = top; }, 700);
}

function highlight(jump = false) {
  $$(".seg.now").forEach((n) => n.classList.remove("now"));
  const node = $(`.seg[data-i="${S.segIdx}"]`);
  if (jump) follow();
  if (node) {
    node.classList.add("now");
    if (S.following) scrollToLine(node, jump);
  }
  $("#now-chapter").textContent = S.chapter ? [sectionOf(S.chapter), S.chapter.title].filter(Boolean).join(" · ") : "";
  showScrub();
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
  r.classList.toggle("text-view", !!L.showText);
  $("#text-btn").classList.toggle("on", !!L.showText);
}

// The whole chapter, or the cover and the line being read.
function toggleText() {
  if (!S.book) return;
  setLook({ showText: !S.look.showText });
  if (S.look.showText) highlight(true);
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
        el("span", { style: id === "original" ? "background:linear-gradient(135deg,#fff 50%,#000 50%);color:#888" : `background:${bg};color:${ink}` }, "Aa"),
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
  const left = Math.min(innerWidth - pop.offsetWidth - 10, r.left + r.width / 2 - pop.offsetWidth / 2);
  pop.style.left = `${left}px`;
  pop.style.transformOrigin = `${r.left + r.width / 2 - left}px 0`;
  anchor.classList.add("active");
}

function closePopovers() {
  $("#aa-pop").classList.add("hidden");
  $("#more-btn").classList.remove("active");
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
  if (!S.following) { follow(); highlight(); }
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
  if (S.sleep?.kind === "chapter" && S.chapterIdx + 1 < S.book.toc.length) {
    setSleep("off");
    stop();
    await loadChapter(S.chapterIdx + 1, 0, false);
  } else if (S.chapterIdx + 1 < S.book.toc.length) {
    await loadChapter(S.chapterIdx + 1, 0, true);
  } else {
    stop();
    S.segIdx = Math.max(0, S.chapter.segments.length - 1);
    highlight();
    savePosition();
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
  if (S.chapter) jumpTo(S.segIdx + delta);
}

function jumpTo(i) {
  const was = S.playing;
  stop(false);
  S.segIdx = Math.max(0, Math.min(S.chapter.segments.length - 1, i));
  highlight();
  if (was) play(); else { setPlayingUI(); savePosition(); }
}

// The bar under the cover: which line of the chapter, dragged to move.
function showScrub(at = null) {
  const n = S.chapter?.segments.length || 1, bar = $("#scrub");
  bar.max = Math.max(0, n - 1);
  if (at === null) bar.value = S.segIdx;
  const i = at ?? S.segIdx;
  bar.style.setProperty("--p", `${(100 * i) / Math.max(1, n - 1)}%`);
  $("#pos-left").textContent = `Line ${i + 1} of ${n}`;
  $("#pos-right").textContent = S.chapter ? timeLeft(S.chapter.segments.slice(i)) : "";
}

// Lines not made yet have no length, so this goes by words: Dune's voices read 2.65 a second, pauses included.
function timeLeft(segments) {
  const words = segments.reduce((sum, s) => sum + s.text.trim().split(/\s+/).length, 0);
  const minutes = Math.round(words / 2.65 / S.speed / 60);
  return minutes < 1 ? "Under a minute left" : `About ${minutes} min left`;
}

function setSpeed(v) {
  S.speed = v;
  S.audio.defaultPlaybackRate = S.audio.playbackRate = v;
  $("#speed-label").textContent = `${v}×`;
  showScrub();
}

// Stops playing after a while, or at the end of the chapter.
function setSleep(kind, minutes = 0) {
  clearTimeout(S.sleepTimer);
  clearInterval(S.sleepTick);
  S.sleep = kind === "off" ? null : { kind, ends: Date.now() + minutes * 60000 };
  if (kind === "minutes") {
    S.sleepTimer = setTimeout(() => { pause(); setSleep("off"); }, minutes * 60000);
    S.sleepTick = setInterval(showSleep, 1000);
  }
  showSleep();
}

function showSleep() {
  const s = S.sleep;
  $("#sleep-btn").classList.toggle("on", !!s);
  const left = s ? Math.max(0, Math.round((s.ends - Date.now()) / 1000)) : 0;
  $("#sleep-label").textContent = !s ? "Sleep" : s.kind === "chapter" ? "Chapter end" : `${Math.floor(left / 60)}:${String(left % 60).padStart(2, "0")}`;
}

// Coming back to this window after listening on the iPhone: carry on from where the phone got to.
async function catchUpPosition() {
  if (!S.book || S.playing || document.hidden) return;
  const id = S.book.id;
  let book;
  try { book = await api(`/api/books/${id}`); } catch { return; }
  const p = book.position || {};
  if (S.book?.id !== id || S.playing || (p.updated || 0) <= (S.positionSaved || 0)) return;
  if (p.chapter !== S.chapterIdx || p.segment !== S.segIdx) {
    S.positionSaved = p.updated;
    await loadChapter(p.chapter, p.segment);
    toast("Continuing from where you got to on your iPhone");
  }
}
document.addEventListener("visibilitychange", catchUpPosition);
window.addEventListener("focus", catchUpPosition);

function savePosition() {
  clearTimeout(S.saveTimer);
  const id = S.book.id, pos = { chapter: S.chapterIdx, segment: S.segIdx };
  S.positionSaved = Date.now() / 1000;
  S.saveTimer = setTimeout(() => api(`/api/books/${id}/position`, { method: "PUT", json: pos }).catch(() => {}), 1200);
}

function voicesChanged() {
  S.rev++;
  S.prefetched.clear();
}

// A new reading of one line, and plays it: voices read a line a little differently each time.
async function readAgain(i) {
  const { book, chapterIdx } = S;
  stop();
  S.segIdx = i;
  highlight();
  toast("Reading it again…");
  try {
    await api(`/api/books/${book.id}/chapters/${chapterIdx}/segments/${i}/again`, { method: "POST" });
  } catch (e) {
    return toast(e.message);
  }
  if (S.book !== book || S.chapterIdx !== chapterIdx || S.segIdx !== i) return;  // moved on meanwhile
  voicesChanged();
  S.playing = true;
  setPlayingUI();
  playCurrent();
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

const DESIGNED = ["qwen"];  // engines that make voices from descriptions
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
    person.voice_from ? el("div", { class: "voice-from" },
      el("span", {}, `Same voice as in ${person.voice_from.title}`),
      el("button", { class: "button small", title: "A voice of their own in this book, from how this book describes them",
        onclick: () => (isDesigned(s.voice) ? designVoice(who, { description: "" }, text) : ownVoice(who, text)) }, "Own Voice")) : null,
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
    el("label", { class: "design" }, el("span", {}, person.voice_description ? "Your description (used instead of the book's)"
      : person.voice_from ? `Voice description, from ${person.voice_from.title}` : "Voice description, from the book"), area),
    el("div", { class: "design-actions" },
      el("button", { class: "button small", title: "Design a voice from this description", onclick: () => designVoice(who, { description: area.value }, text) }, "Use Description"),
      el("button", { class: "button small", title: "Same description, a different voice", onclick: () => designVoice(who, { new_take: true }, text) }, "New Take"),
      person.voice_description
        ? el("button", { class: "button small", title: "Go back to the description written from the book", onclick: () => designVoice(who, { description: "" }, text) }, "Reset")
        : null,
      person.locked
        ? el("button", { class: "button small", title: "Let this character's voice follow the book again (it may change)", onclick: () => designVoice(who, {}, text) }, "Unpin Voice")
        : el("button", { class: "button small", title: "Keep exactly this voice: new descriptions, re-casts and updates won't replace it", onclick: () => keepVoice(person, who) }, "Keep Voice")),
  ];
}

// Pin the voice a character has now, so later analysis or updates never replace it.
async function keepVoice(person, who) {
  const b = S.book;
  const body = { voice: person.voice, rate: person.rate || 180, pitch_shift: person.pitch_shift || 0 };
  try {
    if (who === "narrator") b.narrator = await api(`/api/books/${b.id}/narrator`, { method: "PUT", json: body });
    else {
      const updated = await api(`/api/books/${b.id}/characters/${who}`, { method: "PUT", json: body });
      b.cast = b.cast.map((c) => (c.id === who ? updated : c));
    }
    renderCast();
    toast("Voice kept. Updates and re-runs won't change it");
  } catch (e) { toast(e.message); }
}

// Not the voice from the author's other book: one cast for this book.
async function ownVoice(who, text) {
  const b = S.book;
  try {
    const updated = await api(`/api/books/${b.id}/own-voice/${who}`, { method: "POST" });
    if (who === "narrator") b.narrator = updated; else b.cast = b.cast.map((c) => (c.id === who ? updated : c));
    voicesChanged();
    renderCast();
    preview(updated, text);
  } catch (e) { toast(e.message); }
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

// What a character can be searched by: their name and the other names the book uses.
const findText = (c) => [c.name, ...(c.aliases || []), ...(c.other_names || [])].join(" ");

function renderCast() {
  const b = S.book;
  const q = ($("#cast-search").value || "").trim().toLowerCase();
  const narrator = el("div", { class: "char" },
    el("div", { class: "char-top" }, el("span", { class: "dot" }), el("span", { class: "char-name" }, "Narrator")),
    el("div", { class: "char-summary" }, "Reads everything outside quotation marks"),
    ...voiceControls(b.narrator, "narrator", async (s) => { b.narrator = await api(`/api/books/${b.id}/narrator`, { method: "PUT", json: s }); }, ""));
  const cards = b.cast.filter((c) => !q || findText(c).toLowerCase().includes(q)).map((c) => {
    const meta = [c.gender !== "unknown" ? c.gender : null, c.age !== "adult" ? c.age : null, c.accent ? c.accent.replace("_", " ") : null].filter(Boolean).join(" · ");
    return el("div", { class: "char", style: `--c:${colorOf(c.id)}` },
      el("div", { class: "char-top" },
        el("span", { class: "dot" }),
        el("span", { class: "char-name" }, c.name),
        el("span", { class: "char-lines" }, `${c.lines} line${c.lines === 1 ? "" : "s"}`),
        el("button", { class: "more-btn", title: "Rename, merge or remove", onclick: (e) => { e.stopPropagation(); characterMenu(e.currentTarget, c); } }, "•••")),
      el("div", { class: "char-summary" }, c.summary && c.summary !== meta ? c.summary : meta || "no description found",
        c.not_person ? el("em", {}, " · probably not a person") : null),
      c.evidence?.length ? el("details", {}, el("summary", {}, "What the book says"), ...c.evidence.map((e) => el("blockquote", {}, e))) : null,
      ...voiceControls(c, c.id, async (s) => {
        Object.assign(c, await api(`/api/books/${b.id}/characters/${c.id}`, { method: "PUT", json: s }));
      }, sampleLine(c.id)),
      c.locked ? el("div", { class: "lock" }, "Voice kept by you: updates and re-casts won't change it.") : null,
    );
  });
  $("#cast-list").replaceChildren(...(q && !"narrator".includes(q) ? [] : [narrator]), ...cards,
    ...(q && !cards.length ? [el("p", { class: "muted cast-none" }, `No character called “${q}”`)] : []));
}

// "✓ 28 Oct" when an AI step has already been run on this book.
function doneNote(step) {
  const t = S.book.ai_done?.[step];
  return t ? `✓ ${new Date(t * 1000).toLocaleDateString(undefined, { day: "numeric", month: "short" })}` : null;
}

function castMenu(anchor) {
  const busy = S.book.job?.state === "running";
  popupMenu(anchor, [
    S.config.local_ai?.supported ? { label: "Describe Characters with Local AI…", disabled: busy, note: doneNote("describe"), action: () => analyze("local") } : null,
    S.config.local_ai?.supported ? { label: "Find Speakers with Local AI…", disabled: busy, note: doneNote("speakers"), action: () => analyze("local-speakers") } : null,
    "-",
    { label: "Export for AI Review…", disabled: busy, action: () => exportReview() },
    { label: "Import AI Review…", disabled: busy, note: doneNote("review"), action: () => importReview() },
    { label: S.config.claude ? "Analyze with Claude…" : "Analyze with Claude (add a key in Settings)", disabled: busy || !S.config.claude, action: () => analyze("claude") },
    "-",
    { label: "Add Character…", action: () => newCharacter() },
    { label: "Pronunciations…", action: () => editPronunciations() },
  ]);
}

// How the voices should say unusual names ("Piter" → "Peter"), so they say them the same way every time.
async function editPronunciations(word = "") {
  const b = S.book;
  const rows = el("div", { class: "say-rows" });
  const speakerOf = (w) => b.cast.find((c) => [c.name, ...(c.aliases || [])].some((n) => n.split(/\s+/).includes(w))) || b.narrator;
  const addRow = (w = "", say = "") => {
    const word = el("input", { value: w, placeholder: "As written", autocomplete: "off", spellcheck: "false" });
    const how = el("input", { value: say, placeholder: "Say it like", autocomplete: "off", spellcheck: "false" });
    const row = el("div", { class: "say-row" }, word, el("span", { class: "muted" }, "→"), how,
      el("button", { class: "button small", type: "button", title: "Listen", onclick: () => {
        const p = speakerOf(word.value.trim());
        if (how.value.trim()) preview({ voice: p.voice, rate: p.rate ?? 100, pitch_shift: p.pitch_shift || 0 }, `${how.value.trim()}.`);
      } }, "▶"),
      el("button", { class: "button small", type: "button", title: "Remove", onclick: () => row.remove() }, "×"));
    rows.append(row);
    return how;
  };
  for (const [w, say] of Object.entries(b.pronunciations || {})) addRow(w, say);
  const focus = word && !(word in (b.pronunciations || {})) ? addRow(word) : null;
  if (!rows.children.length) addRow();
  const go = ask({ title: "Pronunciations", ok: "Save", body: el("div", {},
    el("p", { class: "muted" }, "Voices guess at unusual names and can say them differently each time. Spell a name the way it should sound, and every voice will say it that way."),
    rows,
    el("button", { class: "button", type: "button", onclick: () => addRow().previousSibling.previousSibling.focus() }, "Add Name"),
    el("p", { class: "muted small" }, "Use ordinary spelling, like “Peter” for Piter. ▶ plays it with the voice of whoever has that name.")) });
  if (focus) setTimeout(() => focus.focus(), 50);
  if (!(await go)) return;
  const words = {};
  for (const r of rows.querySelectorAll(".say-row")) {
    const [w, say] = [...r.querySelectorAll("input")].map((i) => i.value.trim());
    if (w && say) words[w] = say;
  }
  try {
    b.pronunciations = await api(`/api/books/${b.id}/pronunciations`, { method: "PUT", json: { words } });
    toast("Saved. Lines are re-read with the new pronunciations.");
  } catch (e) { toast(e.message); }
}

// A package a stronger AI chat (e.g. Claude) can check: every line marked with its id and speaker.
async function exportReview() {
  const b = S.book;
  const native = !!window.pywebview;
  const go = await ask({
    title: "Export for AI review", ok: native ? "Save to Downloads" : "Download",
    body: el("div", { class: "review-steps" },
      el("p", { class: "muted" }, "Have a stronger AI, like Claude, check who says each line and how each character should sound. RealBook makes a ZIP with the book split into parts, each with its own instructions."),
      el("ol", {},
        el("li", {}, "Unzip it, open a chat at ", el("b", {}, "claude.ai"), " (or another strong AI) and drag in ", el("b", {}, "Part 1"), ". No need to type anything; the file explains the task."),
        el("li", {}, "The AI answers with a block of corrections. Copy its whole reply."),
        el("li", {}, "Here: Cast ••• → ", el("b", {}, "Import AI Review…"), " → paste → Import."),
        el("li", {}, "Repeat for each part, best in a new chat each time.")),
      el("p", { class: "muted small" }, "Corrected lines are protected like lines you fix by hand; the local AI won't change them later.")),
  });
  if (!go) return;
  if (native) {
    try {
      const r = await api(`/api/books/${b.id}/review/save`, { method: "POST" });
      toast(`Saved to Downloads (${r.parts} part${r.parts === 1 ? "" : "s"})`, 5000);
    } catch (e) { toast(e.message); }
  } else {
    const a = el("a", { href: `/api/books/${b.id}/review/export`, download: "" });
    document.body.append(a); a.click(); a.remove();
  }
}

async function importReview() {
  const b = S.book;
  const area = el("textarea", { class: "design-text review-paste", rows: 10, spellcheck: "false",
    placeholder: "Paste the AI's whole reply here, including the ```json block." });
  const text = await ask({ title: "Import AI review", ok: "Import", body: el("div", {},
    el("p", { class: "muted" }, "Paste the reply from the AI chat for one part of this book's review."), area) });
  if (!text || !area.value.trim()) return;
  try {
    const r = await api(`/api/books/${b.id}/review/import`, { method: "POST", json: { text: area.value } });
    b.cast = r.cast; b.narrator = r.narrator; b.pronunciations = r.pronunciations;
    b.ai_done = { ...(b.ai_done || {}), review: Date.now() / 1000 };
    S.chapter = await api(`/api/books/${b.id}/chapters/${S.chapterIdx}`);
    voicesChanged(); renderCast(); renderPage(); highlight();
    const bits = [r.speakers && `${r.speakers} speakers`, r.characters && `${r.characters} characters`, r.added && `${r.added} new`, r.merged && `${r.merged} merged`, r.said && `${r.said} pronunciations`, r.narrator && "the narrator"].filter(Boolean);
    toast(`Review imported: ${bits.join(", ") || "nothing to change"}${r.skipped_count ? ` (${r.skipped_count} entries didn't match the book and were skipped)` : ""}`, 6000);
  } catch (e) { toast(e.message, 6000); }
}

function characterMenu(anchor, c) {
  popupMenu(anchor, [
    { label: "Rename…", action: () => renameCharacter(c) },
    { label: "Merge into…", action: () => mergeCharacter(c) },
    { label: "Pronunciation…", action: () => editPronunciations(c.name.split(/\s+/).find((w) => /^[A-Z]/.test(w) && !["The", "Lady", "Duke", "Baron", "Dr.", "Reverend", "Mother", "Princess", "Emperor"].includes(w)) || c.name.split(/\s+/)[0]) },
    "-",
    { label: "Remove", danger: true, action: () => removeCharacter(c) },
  ]);
}

async function renameCharacter(c) {
  const others = [...new Set([...(c.other_names || []), ...(c.aliases || [])])].filter((n) => n !== c.name).slice(0, 6);
  const v = await ask({
    title: `Rename “${c.name}”`, ok: "Rename",
    fields: [{ name: "name", label: "Name", value: c.name, help: others.length ? `The book also calls them: ${others.join(", ")}` : "" }],
  });
  if (!v || !v.name || v.name === c.name) return;
  try {
    const updated = await api(`/api/books/${S.book.id}/characters/${c.id}`, { method: "PATCH", json: { name: v.name } });
    S.book.cast = S.book.cast.map((x) => (x.id === c.id ? updated : x));
    renderCast(); renderPage(); highlight();
  } catch (e) { toast(e.message); }
}

async function mergeCharacter(c) {
  const options = S.book.cast.filter((x) => x.id !== c.id).sort((a, b) => b.lines - a.lines).map((x) => [x.id, `${x.name} (${x.lines} lines)`]);
  const v = await ask({
    title: `Merge “${c.name}” into…`, ok: "Merge",
    text: `For when two entries are the same person. ${c.lines ? `Their ${c.lines} lines` : "Their lines"} move to the character you choose, and “${c.name}” is removed.`,
    fields: [{ name: "into", label: "Same person as", value: options[0]?.[0], options }],
  });
  if (!v) return;
  await dropCharacter(c, v.into);
}

async function removeCharacter(c) {
  const ok = await ask({ title: `Remove “${c.name}”?`, ok: "Remove", danger: true,
    text: c.lines ? `Their ${c.lines} lines will be read by the narrator. To give them to another character instead, use Merge into…` : "" });
  if (ok) await dropCharacter(c, null);
}

async function dropCharacter(c, into) {
  try {
    const r = await api(`/api/books/${S.book.id}/characters/${c.id}${into ? `?into=${encodeURIComponent(into)}` : ""}`, { method: "DELETE" });
    S.book.cast = r.cast;
    S.chapter = await api(`/api/books/${S.book.id}/chapters/${S.chapterIdx}`);
    voicesChanged(); renderCast(); renderPage(); highlight();
    toast(into ? `Merged into ${S.book.cast.find((x) => x.id === into)?.name}` : `Removed ${c.name}`);
  } catch (e) { toast(e.message); }
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
    ...S.book.cast.map((c) => ({ label: c.name, dot: colorOf(c.id), find: findText(c), action: () => choose(c.id) })),
    { label: "Unknown (narrator reads it)", dot: "", action: () => choose(null) },
    "-",
    { label: "New Character…", action: async () => { const c = await newCharacter(); if (c) await choose(c.id); } },
  ], { search: S.book.cast.length > 8 });
}

/* ----------------------------------------------------------------- analysis */

function showJob(job) {
  const box = $("#job");
  if (!job) return box.classList.add("hidden");
  box.classList.remove("hidden");
  box.classList.toggle("error", job.state === "error");
  box.replaceChildren(...(job.state === "running" ? [el("span", { class: "spinner" }), job.message] : [job.message]));
}

async function analyze(engine) {
  const ai = S.config.local_ai;
  const msg = engine === "claude"
    ? "Claude will read the whole book to describe each character and decide who says every line. This uses your Anthropic API credits (roughly $1–3 for a full novel). Speakers you fixed by hand will be replaced."
    : engine === "local"
      ? `A small AI model on this Mac (${ai.label}) reads what the book says about each of the main characters and decides their gender, age, accent and how they sound. Free and offline; it takes a few seconds per character. Who says which line stays as it is. Characters whose description changes get a new voice, except voices you've kept (Keep Voice) and descriptions you wrote.${ai.installed ? "" : ` The first time, it downloads the model (${(ai.bytes / 1e9).toFixed(1)} GB).`}`
      : engine === "local-speakers"
        ? `The AI model on this Mac (${ai.label}) reads each scene and decides who speaks the lines that have no speech tag, where RealBook otherwise just guesses that speakers take turns. Lines with a tag ("said Paul") and lines you set by hand stay as they are. Then it describes the characters again from their corrected lines; characters whose description changes get a new voice, except voices you've kept. Free and offline; about a minute per busy chapter (around half an hour for a long novel), and you can keep listening meanwhile.${ai.installed ? "" : ` The first time, it downloads the model (${(ai.bytes / 1e9).toFixed(1)} GB).`}`
        : "RealBook will look for the characters again with its built-in finder. Speakers you fixed by hand will be replaced.";
  const title = { claude: "Analyze with Claude", local: "Describe characters with local AI", "local-speakers": "Find speakers with local AI", heuristic: "Find characters again" }[engine];
  if (!(await ask({ title, text: msg, ok: "Start" }))) return;
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
        S.config = await api("/api/config");  // e.g. the local AI model is now installed
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
          el("option", { value: "apple", selected: c.voice_engine === "apple" }, c.platform === "mac" ? "Mac system voices" : c.platform === "windows" ? "Windows voices" : "System voices (espeak-ng)"))),
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
      el("button", { class: "button small", type: "button", disabled: d.state === "downloading", onclick: async (e) => {
        e.currentTarget.disabled = true;
        await startInstall(name);
        watchInstall(dStatus, name);
      } }, d.state === "downloading" ? "Downloading…" : `Download ${d.label.match(/\((.*)\)/)?.[1] || "Voices"}`),
      dStatus));
    if (d.state === "downloading" || d.state === "error") watchInstall(dStatus, name);
  }
  voiceSection.append(el("button", { class: "button small", type: "button", onclick: () => openModelFinder() }, "Find Voice Models…"));
  if (c.platform !== "linux") voiceSection.append(
    el("p", { class: "muted small" }, c.platform === "mac" ? "More Mac voices: VoiceOver Utility → Speech → Voice → Customize. Pick Premium or Enhanced versions."
      : "More Windows voices: Settings → Time & language → Speech → Add voices."),
    el("button", { class: "button small", type: "button", onclick: () => api("/api/open-voice-settings", { method: "POST" }).catch((e) => toast(e.message)) },
      c.platform === "mac" ? "Open VoiceOver Utility" : "Open Speech Settings"));


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
    el("h3", {}, "Settings"), voiceSection, claudeSection,
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

// `which` is "kokoro" (natural voices) or a designed-voice engine ("qwen").
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
$("#text-btn").onclick = toggleText;
$("#now-cover").onclick = toggleText;
$("#page").addEventListener("contextmenu", (e) => {
  const line = e.target.closest(".seg");
  if (!line) return;
  e.preventDefault();
  const i = +line.dataset.i;
  popupMenu({ contains: () => false, getBoundingClientRect: () => new DOMRect(e.clientX, e.clientY, 0, 0) }, [
    { label: "Play from Here", action: () => { jumpTo(i); if (!S.playing) play(); } },
    { label: "Read This Line Again", action: () => readAgain(i) },
  ]);
});
$("#more-btn").onclick = (e) => {
  e.stopPropagation();
  const btn = e.currentTarget;
  if (!$("#aa-pop").classList.contains("hidden")) return closePopovers();  // the button again: closes it
  popupMenu(btn, [
    { label: "Read This Line Again", disabled: !S.chapter, action: () => readAgain(S.segIdx) },
    "-",
    { label: "Cast", note: "⌘2", action: () => togglePanel("cast") },
    { label: "Text Size & Theme…", action: () => toggleAa(btn) },
    S.config.export ? "-" : null,
    S.config.export ? { label: "Export Audiobook…", action: () => exportBook(S.book) } : null,
  ]);
};
$("#speed-btn").onclick = (e) => {
  e.stopPropagation();
  popupMenu(e.currentTarget, SPEEDS.map((v) => ({ label: `${v}×`, note: v === S.speed ? "✓" : "", action: () => setSpeed(v) })));
};
$("#sleep-btn").onclick = (e) => {
  e.stopPropagation();
  const k = S.sleep?.kind;
  popupMenu(e.currentTarget, [
    { label: "Off", note: !k ? "✓" : "", action: () => setSleep("off") },
    ...[5, 15, 30, 45, 60].map((m) => ({ label: `${m} minutes`, action: () => setSleep("minutes", m) })),
    { label: "End of Chapter", note: k === "chapter" ? "✓" : "", action: () => setSleep("chapter") },
  ]);
};
$("#scrub").addEventListener("input", (e) => showScrub(+e.target.value));
$("#scrub").addEventListener("change", (e) => { jumpTo(+e.target.value); e.target.blur(); });  // space is play again
$("#follow-btn").onclick = () => { follow(); highlight(true); };
$("#page").addEventListener("wheel", scrolledAway, { passive: true });
$("#page").addEventListener("pointerdown", (e) => { if (e.offsetX >= e.currentTarget.clientWidth) scrolledAway(); });  // its scrollbar
document.addEventListener("visibilitychange", () => { if (!document.hidden && S.following && S.chapter) highlight(); });
$$("[data-close-panel]").forEach((b) => { b.onclick = closePanels; });
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
S.audio.preload = "auto";
S.audio.addEventListener("waiting", () => $("#play").classList.add("loading"));
S.audio.addEventListener("playing", () => $("#play").classList.remove("loading"));
S.audio.addEventListener("pause", () => $("#play").classList.remove("loading"));
S.audio.onended = onEnded;
S.audio.onerror = () => {
  if (!S.playing) return;
  if (!S.config.system_voices && !S.config.kokoro?.installed) {  // Linux, before any voices are downloaded
    pause();
    toast("Download the natural voices first, to hear your books.", 6000);
    return openSettings();
  }
  toast("Couldn't make audio for this line; skipping it");
  onEnded();
};
$("#cast-search").addEventListener("input", () => renderCast());
// Pressing anywhere else closes what's open: menus, the Aa popover, and the Chapters and Cast
// panels. Watched on the way down, so a button that handles its own click can't hide it. A menu's
// or panel's own button is left to toggle it. Playing or moving through the book keeps a panel open.
document.addEventListener("pointerdown", (e) => {
  const t = e.target, inside = (sel) => t.closest?.(sel);
  if (!$("#dialog").open) {
    // A press that closes something on the text only closes it: it doesn't also start that line.
    S.swallowClick = !!inside("#page, #now-cover") && (!$("#menu").classList.contains("hidden") || !$("#aa-pop").classList.contains("hidden")
      || $("#reader").classList.contains("show-toc") || $("#reader").classList.contains("show-cast"));
    if (!inside("#menu") && !S.menuAnchor?.contains(t)) closeMenu();
    if (!inside("#aa-pop") && !inside("#menu") && !inside("#more-btn")) { $("#aa-pop").classList.add("hidden"); $("#more-btn").classList.remove("active"); }
    if (!inside("#menu") && !inside("#aa-pop") && !inside("#play, #prev, #next, #scrub")) {
      const r = $("#reader");
      if (!inside("#toc") && !inside("#toc-btn")) { r.classList.remove("show-toc"); $("#toc-btn").classList.remove("on"); }
      if (!inside("#cast")) r.classList.remove("show-cast");
    }
  }
}, true);
document.addEventListener("click", (e) => {
  if (S.swallowClick) { S.swallowClick = false; e.stopPropagation(); e.preventDefault(); }
}, true);
window.addEventListener("blur", closeMenu);
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") {
    if (!$("#menu").classList.contains("hidden") || !$("#aa-pop").classList.contains("hidden")) return closePopovers();
    if (!$("#dialog").open) closePanels();
    return;
  }
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
