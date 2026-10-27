"""Export a book as an .m4b audiobook with chapters, read in the voices of its cast.

Every line is made the same way as when listening (and comes from the same cache), decoded to
raw audio, joined with the same short pauses the player leaves, then encoded once as AAC.
The result plays offline in any audiobook app: Apple Books, BookPlayer, Smart AudioBook Player…
"""

from __future__ import annotations

import re
import struct
import subprocess
import tempfile
import threading
import time
import wave
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from . import m4b, store, system, tts

RATE = 24000
GAP_LINE, GAP_PARAGRAPH, GAP_TITLE, GAP_CHAPTER = 0.09, 0.32, 0.8, 1.5  # seconds
BITRATE = 64000  # mono speech: about 29 MB per hour

_jobs: dict[str, dict] = {}


class Cancelled(Exception):
    pass


def output(book: dict) -> Path:
    name = re.sub(r'[\\/:*?"<>|]+', " ", book["title"]).strip()[:80] or "Audiobook"
    return store.book_dir(book["id"]) / "export" / f"{name}.m4b"


def status(book_id: str) -> dict:
    book = store.load(book_id)
    job = dict(_jobs.get(book_id, {"state": "idle"}))
    path = output(book)
    if path.exists() and job["state"] != "running":
        job.update(file=path.name, bytes=path.stat().st_size, made=path.stat().st_mtime)
    return job


def start(book_id: str) -> dict:
    if not system.CAN_EXPORT:
        raise RuntimeError("Exporting audiobooks only works on a Mac for now")
    if _jobs.get(book_id, {}).get("state") == "running":
        return status(book_id)
    _jobs[book_id] = {"state": "running", "done": 0, "total": 0, "message": "Starting…", "cancel": False}
    threading.Thread(target=_run, args=(book_id,), daemon=True, name=f"export-{book_id}").start()
    return status(book_id)


def cancel(book_id: str) -> dict:
    if book_id in _jobs:
        _jobs[book_id]["cancel"] = True
    return status(book_id)


def _spoken_title(title: str) -> str | None:
    """Chapter headings read aloud by the narrator ("Chapter One"); not "Front Matter" or "(continued)"."""
    if not title or "(continued)" in title or title.lower().startswith(("front matter", "contents", "copyright")):
        return None
    return title.title() if title.isupper() else title


class _Caf:
    """Writes 16-bit mono PCM to a CAF file, which (unlike WAV) has no 4 GB limit."""

    def __init__(self, path: Path):
        self.f = open(path, "wb")
        self.frames = 0
        desc = struct.pack(">dIIIIII", RATE, int.from_bytes(b"lpcm", "big"), 2, 2, 1, 1, 16)  # little-endian ints
        self.f.write(b"caff" + struct.pack(">HH", 1, 0) + b"desc" + struct.pack(">q", len(desc)) + desc)
        self._size_at = self.f.tell() + 4
        self.f.write(b"data" + struct.pack(">q", -1) + struct.pack(">I", 0))  # size filled in at the end

    @property
    def ms(self) -> int:
        return self.frames * 1000 // RATE

    def add(self, pcm: bytes) -> None:
        self.f.write(pcm)
        self.frames += len(pcm) // 2

    def silence(self, seconds: float) -> None:
        self.add(bytes(2 * int(RATE * seconds)))

    def close(self) -> None:
        self.f.seek(self._size_at)
        self.f.write(struct.pack(">q", 4 + 2 * self.frames))
        self.f.close()


def _pcm(path: Path) -> bytes:
    """Decode a cached line to 24 kHz mono 16-bit samples (whatever engine made it)."""
    with tempfile.NamedTemporaryFile(suffix=".wav", dir=path.parent, delete=False) as tmp:
        wav = Path(tmp.name)
    try:
        subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{RATE}", "-c", "1", str(path), str(wav)],
                       check=True, capture_output=True, timeout=120)
        with wave.open(str(wav)) as w:
            return w.readframes(w.getnframes())
    finally:
        wav.unlink(missing_ok=True)


def _run(book_id: str) -> None:
    job = _jobs[book_id]
    book = store.load(book_id)
    target = output(book)
    target.parent.mkdir(parents=True, exist_ok=True)
    work = target.parent / "work.caf"
    encoded = target.with_suffix(".tmp.m4b")
    audio = store.audio_dir(book_id)
    narrator = book["narrator"]
    started = time.monotonic()

    def render(text: str, v: dict) -> bytes:
        if job["cancel"]:
            raise Cancelled
        # Not urgent: if someone is listening at the same time, their lines go first.
        path = tts.synthesize(audio, text, v["voice"], v["rate"], v.get("pitch_shift", 0), urgent=False)
        return _pcm(path)

    try:
        items = []  # (chapter index, text, voice settings, pause after)
        for ci, ch in enumerate(book["chapters"]):
            heading = _spoken_title(ch["title"])
            if heading:
                items.append((ci, heading, narrator, GAP_TITLE))
            segs = ch["segments"]
            for i, seg in enumerate(segs):
                nxt = segs[i + 1] if i + 1 < len(segs) else None
                pause = GAP_CHAPTER if nxt is None else GAP_PARAGRAPH if nxt["para"] != seg["para"] else GAP_LINE
                items.append((ci, seg["text"], store.voice_for(book, seg), pause))
        job.update(total=len(items), message="Making the audio…")

        caf = _Caf(work)
        chapters: list[tuple[int, str]] = []
        try:
            with ThreadPoolExecutor(4) as pool:  # lines are made in order; decoding overlaps
                results = pool.map(lambda it: render(it[1], it[2]), items)
                for n, ((ci, _, _, pause), pcm) in enumerate(zip(items, results), 1):
                    if not chapters or chapters[-1][2] != ci:
                        chapters.append((caf.ms, book["chapters"][ci]["title"] or f"Chapter {ci + 1}", ci))
                    caf.add(pcm)
                    caf.silence(pause)
                    rate = n / max(1e-6, time.monotonic() - started)
                    left = (len(items) - n) / rate
                    job.update(done=n, message=f"Making the audio… {n} of {len(items)} lines, about {_duration(left)} left")
        finally:
            caf.close()

        job.update(message="Encoding the audiobook…")
        subprocess.run(["afconvert", "-f", "m4bf", "-d", "aac", "-b", str(BITRATE), "-q", "127", str(work), str(encoded)],
                       check=True, capture_output=True)
        cover = None
        if book.get("cover"):
            cover = ((store.book_dir(book_id) / book["cover"]).read_bytes(), book["cover"].rsplit(".", 1)[-1])
        m4b.add_chapters(encoded, [(ms, title) for ms, title, _ in chapters], book["title"], book["author"], cover)
        for old in target.parent.glob("*.m4b"):
            if old != encoded:
                old.unlink()
        encoded.rename(target)
        job.update(state="done", message=f"Audiobook ready: {_duration(caf.frames / RATE)} long")
    except Cancelled:
        job.update(state="idle", message="Export cancelled")
    except Exception as e:  # surfaced to the UI
        job.update(state="error", message=f"Export failed: {e}")
    finally:
        work.unlink(missing_ok=True)
        encoded.unlink(missing_ok=True)


def _duration(seconds: float) -> str:
    seconds = int(seconds)
    if seconds < 60:
        return f"{seconds} s"
    h, m = divmod(seconds // 60, 60)
    return f"{h} h {m} min" if h else f"{m} min"
