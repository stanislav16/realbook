"""RealBook web server: a JSON API plus the single-page reader in static/."""

from __future__ import annotations

import os
import threading
import time
import webbrowser
from pathlib import Path

import uvicorn
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from . import claude_analyzer, export, heuristic, kokoro_tts, local_analyzer, model_finder, designed, remote, store, system, tts, voices

HERE = Path(__file__).resolve().parent
app = FastAPI(title="RealBook")
jobs: dict[str, dict] = {}

NOT_PAIRED = """<!doctype html><meta name=viewport content="width=device-width,initial-scale=1">
<title>RealBook</title><body style="font:16px -apple-system,sans-serif;padding:40px 24px;text-align:center;color:#444">
<h2>RealBook</h2><p>To listen on this device, open RealBook on your Mac, go to Settings → Listen on Other Devices,
and scan the QR code with this device's camera.</p></body>"""


@app.middleware("http")
async def guard_remote(request: Request, call_next):
    """Requests from other devices need the pairing key, and can't change things on the Mac."""
    if remote.is_local(request.client.host if request.client else None):
        return await call_next(request)
    key = request.query_params.get("key")
    if key and remote.authorised(key):
        # Remember the key and drop it from the address bar.
        resp = RedirectResponse(request.url.remove_query_params("key"), status_code=303)
        resp.set_cookie(remote.COOKIE, key, max_age=365 * 86400, httponly=True, samesite="lax")
        return resp
    if not remote.authorised(request.cookies.get(remote.COOKIE)):
        if request.url.path.startswith("/api/"):
            return JSONResponse({"detail": "This device isn't paired with RealBook"}, status_code=403)
        return HTMLResponse(NOT_PAIRED, status_code=403)
    if remote.blocked(request.method, request.url.path):
        return JSONResponse({"detail": "Only possible on the Mac itself"}, status_code=403)
    if "/audio/" in request.url.path:
        remote.keep_awake()
    return await call_next(request)


def _book(book_id: str) -> dict:
    try:
        return store.load(book_id)
    except KeyError:
        raise HTTPException(404, "Book not found")


def _chapter(book: dict, n: int) -> dict:
    if not 0 <= n < len(book["chapters"]):
        raise HTTPException(404, "Chapter not found")
    return book["chapters"][n]


# ------------------------------------------------------------------ library


@app.get("/api/config")
def config(request: Request = None):
    source = claude_analyzer.key_source()
    values = store.settings()
    return {
        "claude": source is not None,
        "key_source": source,
        "voice_engine": values.get("voice_engine", "kokoro"),
        "apple_for_accents": values.get("apple_for_accents", True),
        "kokoro": kokoro_tts.install_status(),
        **{name: designed.install_status(engine) for name, engine in designed.ENGINES.items()},
        "local_ai": local_analyzer.status(),
        "appearance": values.get("appearance", {}),
        "hide_voice_banner": values.get("hide_voice_banner", False),
        # On another device, the UI hides what only works on the Mac.
        "remote": bool(request and request.client and not remote.is_local(request.client.host)),
        "platform": "mac" if system.MAC else "windows" if system.WINDOWS else "other",
        "export": system.CAN_EXPORT,
    }


class SettingsUpdate(BaseModel):
    anthropic_api_key: str | None = None
    voice_engine: str | None = None  # "kokoro" | "apple" | "qwen" | "breeze"
    apple_for_accents: bool | None = None
    appearance: dict | None = None  # reader theme, font, size: kept here because the app's port changes each launch
    hide_voice_banner: bool | None = None


@app.put("/api/settings")
def update_settings(s: SettingsUpdate):
    values = store.settings()
    if s.anthropic_api_key is not None:
        key = s.anthropic_api_key.strip()
        if key and not key.startswith("sk-ant-"):
            raise HTTPException(400, "That doesn't look like an Anthropic API key (they start with sk-ant-)")
        if key:
            values["anthropic_api_key"] = key
        else:
            values.pop("anthropic_api_key", None)
    if s.appearance is not None:
        values["appearance"] = {**values.get("appearance", {}), **s.appearance}
    if s.hide_voice_banner is not None:
        values["hide_voice_banner"] = s.hide_voice_banner
    voice_change = False
    if s.voice_engine in designed.ENGINES and not designed.installed(designed.ENGINES[s.voice_engine]):
        raise HTTPException(400, "Download these voices first")
    if s.voice_engine in ("kokoro", "apple", *designed.ENGINES) and s.voice_engine != values.get("voice_engine", "kokoro"):
        values["voice_engine"] = s.voice_engine
        voice_change = True
    if s.apple_for_accents is not None and s.apple_for_accents != values.get("apple_for_accents", True):
        values["apple_for_accents"] = s.apple_for_accents
        voice_change = True
    store.save_settings(values)
    if voice_change:
        store.recast_all()
        if voices.designed_engine():
            designed.warm_up(voices.designed_engine())
    return config()


@app.post("/api/kokoro/install")
def install_kokoro():
    """Download the natural-voice model, then re-cast every book with it."""
    return kokoro_tts.install_async(on_done=store.recast_all)


@app.post("/api/{engine}/install")
def install_designed(engine: str):
    """Download a designed-voice engine's models, then switch to it and re-cast every book."""
    if engine not in designed.ENGINES:
        raise HTTPException(404, "Unknown voice engine")
    e = designed.ENGINES[engine]

    def use_them():
        store.save_settings({**store.settings(), "voice_engine": engine})
        store.recast_all()
        designed.warm_up(e)

    return designed.install_async(e, on_done=use_them)


@app.get("/api/remote")
def remote_status():
    return remote.status()


class RemoteToggle(BaseModel):
    enabled: bool


@app.post("/api/remote")
def set_remote(t: RemoteToggle):
    """Turn listening on other devices (phone, tablet, PC on the same Wi-Fi) on or off."""
    return remote.set_enabled(t.enabled)


@app.post("/api/remote/reset")
def reset_remote():
    return remote.reset_token()


@app.post("/api/open-voice-settings")
def open_voice_settings():
    """Open where the system offers more voices: VoiceOver Utility on a Mac, Speech settings on Windows."""
    if not system.open_voice_settings():
        raise HTTPException(500, "Couldn't open the voice settings")
    return {"ok": True}


@app.get("/api/books")
def books():
    return store.list_books()


@app.post("/api/books")
async def upload(request: Request, filename: str):
    data = await request.body()
    if not data:
        raise HTTPException(400, "Empty file")
    try:
        book = store.create(filename, data)
    except ValueError as e:
        raise HTTPException(400, str(e))
    return store.summary(book)


@app.post("/api/books/{book_id}/source")
async def update_source(book_id: str, request: Request, filename: str):
    """Re-read a book from its original file (adds a cover and chapter names, keeps your place)."""
    _book(book_id)
    data = await request.body()
    if not data:
        raise HTTPException(400, "Empty file")
    try:
        return store.update_source(book_id, filename, data)
    except ValueError as e:
        raise HTTPException(400, str(e))


@app.delete("/api/books/{book_id}")
def delete_book(book_id: str):
    _book(book_id)
    store.delete(book_id)
    return {"ok": True}


@app.get("/api/books/{book_id}")
def get_book(book_id: str):
    b = _book(book_id)
    if voices.designed_engine():
        talkers = sorted(b["characters"], key=lambda c: -c.get("lines", 0))[:12]
        designed.design_ahead([b["narrator"]["voice"]] + [c["voice"] for c in talkers])
    return {
        **store.summary(b),
        "narrator": b["narrator"],
        "cast": b["characters"],
        "toc": [{"title": c["title"], "section": c.get("section", ""), "segments": len(c["segments"])} for c in b["chapters"]],
        "job": jobs.get(book_id),
    }


@app.get("/api/books/{book_id}/chapters/{n}")
def get_chapter(book_id: str, n: int):
    return _chapter(_book(book_id), n)


class Position(BaseModel):
    chapter: int
    segment: int


@app.put("/api/books/{book_id}/position")
def set_position(book_id: str, pos: Position):
    b = _book(book_id)
    with store.lock(book_id):
        b["position"] = pos.model_dump()
        b["opened"] = time.time()
        store.save(b)
    return {"ok": True}


@app.get("/api/books/{book_id}/cover")
def cover(book_id: str):
    b = _book(book_id)
    if not b.get("cover"):
        raise HTTPException(404, "No cover")
    return FileResponse(store.book_dir(book_id) / b["cover"], headers={"Cache-Control": "max-age=86400"})


# -------------------------------------------------------------- the cast


class VoiceSettings(BaseModel):
    voice: str
    rate: int
    pitch_shift: int = 0


@app.put("/api/books/{book_id}/narrator")
def set_narrator(book_id: str, v: VoiceSettings):
    b = _book(book_id)
    with store.lock(book_id):
        b["narrator"] = {**v.model_dump(), "locked": True}
        store.save(b)
    return b["narrator"]


@app.put("/api/books/{book_id}/characters/{char_id}")
def set_character_voice(book_id: str, char_id: str, v: VoiceSettings):
    b = _book(book_id)
    with store.lock(book_id):
        for c in b["characters"]:
            if c["id"] == char_id:
                c.update(v.model_dump(), locked=True)
                store.save(b)
                return c
    raise HTTPException(404, "Character not found")


@app.post("/api/books/{book_id}/recast")
def recast(book_id: str):
    """Re-pick voices for every character the user has not set by hand."""
    b = _book(book_id)
    with store.lock(book_id):
        b["narrator"], b["characters"] = voices.cast(b["characters"], b["narrator"])
        store.save(b)
    return {"narrator": b["narrator"], "cast": b["characters"]}


class Design(BaseModel):
    description: str | None = None  # None keeps it; "" goes back to the one written from the book
    new_take: bool = False  # design the same description again, for a different-sounding voice


@app.put("/api/books/{book_id}/design/{who}")
def design_voice(book_id: str, who: str, d: Design):
    """Give the narrator or a character a designed voice: from a new description, or a new take."""
    if not voices.designed_engine():
        raise HTTPException(400, "Turn on designed voices in Settings first")
    b = _book(book_id)

    def find():
        return b["narrator"] if who == "narrator" else next((c for c in b["characters"] if c["id"] == who), None)

    with store.lock(book_id):
        person = find()
        if person is None:
            raise HTTPException(404, "Character not found")
        if d.description is not None:
            if d.description.strip():
                person["voice_description"] = d.description.strip()[:600]
            else:
                person.pop("voice_description", None)
        if d.new_take:
            person["voice_take"] = person.get("voice_take", 0) + 1
        person.pop("locked", None)
        b["narrator"], b["characters"] = voices.cast(b["characters"], b["narrator"])
        store.save(b)
        person = find()
    designed.design_ahead([person["voice"]])
    return person


class NewCharacter(BaseModel):
    name: str
    gender: str = "unknown"
    age: str = "adult"


@app.post("/api/books/{book_id}/characters")
def add_character(book_id: str, nc: NewCharacter):
    b = _book(book_id)
    with store.lock(book_id):
        base = heuristic._slug(nc.name)
        cid, i = base, 2
        while any(c["id"] == cid for c in b["characters"]):
            cid, i = f"{base}-{i}", i + 1
        char = {"id": cid, "name": nc.name, "aliases": [], "gender": nc.gender, "age": nc.age,
                "accent": "", "pitch": 0, "pace": 0, "summary": "added by hand", "evidence": [], "lines": 0}
        _, cast = voices.cast(b["characters"] + [char], b["narrator"])
        b["characters"] = cast
        store.save(b)
    return next(c for c in cast if c["id"] == cid)


class Speaker(BaseModel):
    speaker: str | None


@app.put("/api/books/{book_id}/chapters/{n}/segments/{sid}/speaker")
def set_speaker(book_id: str, n: int, sid: int, sp: Speaker):
    """Reassign a quote (every segment of it) to another character, or to nobody."""
    b = _book(book_id)
    ch = _chapter(b, n)
    if not 0 <= sid < len(ch["segments"]) or ch["segments"][sid]["kind"] != "dialogue":
        raise HTTPException(400, "Not a line of dialogue")
    if sp.speaker and not any(c["id"] == sp.speaker for c in b["characters"]):
        raise HTTPException(400, "Unknown character")
    with store.lock(book_id):
        q = ch["segments"][sid]["q"]
        changed = []
        for seg in ch["segments"]:
            if seg["kind"] == "dialogue" and seg["q"] == q:
                seg["speaker"] = sp.speaker
                seg["by_hand"] = True  # the local AI's speaker pass leaves these alone
                changed.append(seg["id"])
        store.recount_lines(b)
        store.save(b)
    return {"changed": changed, "cast": b["characters"]}


# ---------------------------------------------------------------- analysis


class AnalyzeRequest(BaseModel):
    engine: str  # "claude" | "heuristic" | "local" (profiles only, from a small model on this Mac)


@app.post("/api/books/{book_id}/analyze")
def analyze(book_id: str, req: AnalyzeRequest):
    b = _book(book_id)
    if jobs.get(book_id, {}).get("state") == "running":
        raise HTTPException(409, "Already analysing this book")
    if req.engine == "claude" and not claude_analyzer.available():
        raise HTTPException(400, "Add an Anthropic API key in Settings to use Claude")
    if req.engine in ("local", "local-speakers") and not designed.supported():
        raise HTTPException(400, "The local AI needs a Mac with Apple silicon")

    if req.engine == "local-speakers":
        def run_speakers():
            job = jobs[book_id]
            try:
                if not local_analyzer.installed():
                    local_analyzer.install(lambda msg: job.update(message=msg))
                n = local_analyzer.find_speakers(book_id, progress=lambda msg: job.update(message=msg))
                job.update(state="done", message=f"Decided who speaks {n} lines that had no speech tag")
            except Exception as e:  # surfaced to the UI
                job.update(state="error", message=str(e))

        jobs[book_id] = {"state": "running", "message": "Starting…", "engine": "local-speakers"}
        threading.Thread(target=run_speakers, daemon=True).start()
        return jobs[book_id]

    if req.engine == "local":
        def run_local():
            job = jobs[book_id]
            try:
                if not local_analyzer.installed():
                    local_analyzer.install(lambda msg: job.update(message=msg))
                import copy

                snapshot = copy.deepcopy(store.load(book_id))
                results = local_analyzer.profile_book(snapshot, local_analyzer.model_dir(),
                                                      progress=lambda msg: job.update(message=msg))
                with store.lock(book_id):
                    book = store.load(book_id)
                    n = local_analyzer.apply(book, results)
                    store.save(book)
                job.update(state="done", message=f"Described {n} characters from what the book says about them")
            except Exception as e:  # surfaced to the UI
                job.update(state="error", message=str(e))

        jobs[book_id] = {"state": "running", "message": "Starting…", "engine": "local"}
        threading.Thread(target=run_local, daemon=True).start()
        return jobs[book_id]

    def run():
        job = jobs[book_id]
        try:
            # Work on a copy so the book stays readable while Claude runs.
            import copy

            chapters = copy.deepcopy(b["chapters"])
            if req.engine == "claude":
                result = claude_analyzer.analyze(chapters, lambda msg: job.update(message=msg))
            else:
                result = heuristic.analyze(chapters)
            with store.lock(book_id):
                b["chapters"] = chapters
                b["narrator"] = b.get("narrator") or {}
                store.apply_analysis(b, result, req.engine)
                store.save(b)
            job.update(state="done", message=f"Found {len(result['characters'])} speaking characters")
        except Exception as e:  # surfaced to the UI
            job.update(state="error", message=str(e))

    jobs[book_id] = {"state": "running", "message": "Starting…", "engine": req.engine}
    threading.Thread(target=run, daemon=True).start()
    return jobs[book_id]


# ----------------------------------------------------------------- export


@app.get("/api/books/{book_id}/export")
def export_status(book_id: str):
    _book(book_id)
    return export.status(book_id)


@app.post("/api/books/{book_id}/export")
def start_export(book_id: str):
    """Make an .m4b audiobook of the whole book, with chapters, in the cast's voices."""
    _book(book_id)
    try:
        return export.start(book_id)
    except RuntimeError as e:
        raise HTTPException(400, str(e))


@app.post("/api/books/{book_id}/export/cancel")
def cancel_export(book_id: str):
    _book(book_id)
    return export.cancel(book_id)


@app.get("/api/books/{book_id}/export/file")
def export_file(book_id: str):
    path = export.output(_book(book_id))
    if not path.exists():
        raise HTTPException(404, "Export the audiobook first")
    return FileResponse(path, media_type="audio/mp4", filename=path.name)


@app.post("/api/books/{book_id}/export/reveal")
def reveal_export(book_id: str):
    path = export.output(_book(book_id))
    if not path.exists():
        raise HTTPException(404, "Export the audiobook first")
    system.reveal(path)
    return {"ok": True}


# ------------------------------------------------------------------ audio


@app.get("/api/voices")
def list_voices():
    return voices.selectable_voices() + kokoro_tts.blends()


@app.get("/api/books/{book_id}/audio/{n}/{sid}")
def segment_audio(book_id: str, n: int, sid: int, prefetch: int = 0):
    b = _book(book_id)
    ch = _chapter(b, n)
    if not 0 <= sid < len(ch["segments"]):
        raise HTTPException(404, "Segment not found")
    seg = ch["segments"][sid]
    v = store.voice_for(b, seg)
    path = tts.synthesize(store.audio_dir(book_id), seg["text"], v["voice"], v["rate"], v["pitch_shift"], urgent=not prefetch)
    return FileResponse(path, media_type=system.AUDIO_TYPE, headers={"Cache-Control": "no-cache"})


@app.get("/api/preview")
def preview(voice: str, rate: int = voices.DEFAULT_RATE, pitch_shift: int = 0, text: str = ""):
    if voices.lookup(voice) is None:
        raise HTTPException(400, "Unknown voice")
    text = text[:300] or "Hello. This is how I will sound when I read your book."
    path = tts.synthesize(store.DATA_DIR / "previews", text, voice, rate, pitch_shift)
    return FileResponse(path, media_type=system.AUDIO_TYPE)


# ------------------------------------------------------------------ pages


app.mount("/static", StaticFiles(directory=HERE / "static"), name="static")


@app.get("/manifest.webmanifest")
def manifest(request: Request):
    """Lets phones add RealBook to the home screen. Home-screen apps on iPhone don't share Safari's
    cookies, so on a paired device the start address carries the pairing key."""
    start = "/"
    if request.client and not remote.is_local(request.client.host):
        start = f"/?key={remote.token()}"
    return JSONResponse({
        "name": "RealBook", "short_name": "RealBook", "start_url": start, "display": "standalone",
        "background_color": "#1e1e1e", "theme_color": "#1e1e1e",
        "icons": [{"src": "/static/icon-180.png", "sizes": "180x180", "type": "image/png"},
                  {"src": "/static/icon-512.png", "sizes": "512x512", "type": "image/png"}],
    }, media_type="application/manifest+json")


@app.get("/")
def index():
    return FileResponse(HERE / "static" / "index.html")


def prepare_library() -> None:
    """Update older libraries, and give an empty one the sample story."""
    store.prepare()
    if voices.designed_engine():
        designed.warm_up(voices.designed_engine())
    if remote.enabled():
        remote.start()
    if store.list_books():
        return
    for sample in sorted((HERE / "samples").glob("*.txt")):
        store.create(sample.name, sample.read_bytes())


def main() -> None:
    """Browser mode (for development): serve the UI and open it in the default browser."""
    port = int(os.environ.get("REALBOOK_PORT", "8765"))
    prepare_library()
    url = f"http://127.0.0.1:{port}"
    print(f"RealBook is running at {url}  (Ctrl+C to stop)")
    if not claude_analyzer.available():
        print("Character analysis: free built-in analyzer. Add an Anthropic API key in Settings to enable Claude.")
    if not os.environ.get("REALBOOK_NO_BROWSER"):
        threading.Timer(1.0, lambda: webbrowser.open(url)).start()
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")


if __name__ == "__main__":
    main()
