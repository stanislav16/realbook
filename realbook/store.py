"""Books on disk: data/books/<id>/book.json plus an audio/ cache next to it."""

from __future__ import annotations

import json
import os
import re
import threading
import time
import uuid
from pathlib import Path

from . import heuristic, importer, segmenter, system, voices

DATA_DIR = system.data_dir()
BOOKS_DIR = DATA_DIR / "books"
SETTINGS = DATA_DIR / "settings.json"


def settings() -> dict:
    try:
        return json.loads(SETTINGS.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_settings(values: dict) -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    tmp = SETTINGS.with_suffix(".tmp")
    tmp.touch(mode=0o600)
    tmp.write_text(json.dumps(values))
    tmp.replace(SETTINGS)

_cache: dict[str, dict] = {}
_locks: dict[str, threading.RLock] = {}


def lock(book_id: str) -> threading.RLock:
    return _locks.setdefault(book_id, threading.RLock())


def book_dir(book_id: str) -> Path:
    if not re.fullmatch(r"[a-z0-9-]+", book_id):
        raise KeyError(book_id)
    return BOOKS_DIR / book_id


def audio_dir(book_id: str) -> Path:
    return book_dir(book_id) / "audio"


def load(book_id: str) -> dict:
    if book_id not in _cache:
        path = book_dir(book_id) / "book.json"
        if not path.exists():
            raise KeyError(book_id)
        _cache[book_id] = json.loads(path.read_text())
    return _cache[book_id]


def save(book: dict) -> None:
    with lock(book["id"]):
        d = book_dir(book["id"])
        d.mkdir(parents=True, exist_ok=True)
        tmp = d / "book.json.tmp"
        tmp.write_text(json.dumps(book, ensure_ascii=False))
        tmp.replace(d / "book.json")
        _cache[book["id"]] = book


def list_books() -> list[dict]:
    if not BOOKS_DIR.exists():
        return []
    out = []
    for d in sorted(BOOKS_DIR.iterdir()):
        try:
            b = load(d.name)
        except (KeyError, json.JSONDecodeError):
            continue
        out.append(summary(b))
    return sorted(out, key=lambda b: -b["created"])


def summary(b: dict) -> dict:
    pos = b.get("position", {"chapter": 0, "segment": 0})
    sizes = [len(ch["segments"]) for ch in b["chapters"]]
    done = sum(sizes[: pos["chapter"]]) + pos["segment"]
    total = max(1, sum(sizes))
    return {
        "id": b["id"], "title": b["title"], "author": b["author"], "created": b["created"],
        "opened": b.get("opened", 0), "analyzer": b["analyzer"], "chapters": len(b["chapters"]),
        "characters": len(b["characters"]), "position": pos, "cover": b.get("cover"),
        "progress": round(done / total, 4),
        "finished": pos["chapter"] == len(sizes) - 1 and pos["segment"] >= sizes[-1] - 1 if sizes else False,
    }


def _chapters(imported: importer.ImportedBook) -> tuple[str, list[dict]]:
    style = segmenter.detect_quote_style("\n".join(c[1] for c in imported.chapters[:5]))
    chapters = [{"title": t, "section": section, "segments": segmenter.segment_chapter(text, style)}
                for t, text, section in imported.chapters]
    return style, [c for c in chapters if c["segments"]]


def _store_files(book: dict, filename: str, data: bytes, imported: importer.ImportedBook) -> None:
    """Keep the original (so a future, better importer can re-read it) and the cover image."""
    d = book_dir(book["id"])
    d.mkdir(parents=True, exist_ok=True)
    for old in (book.get("source"), book.get("cover")):
        if old:
            (d / old).unlink(missing_ok=True)
    book["source"] = "source" + (Path(filename).suffix.lower() or ".txt")
    (d / book["source"]).write_bytes(data)
    book["cover"] = None
    if imported.cover:
        book["cover"] = f"cover.{imported.cover[1]}"
        (d / book["cover"]).write_bytes(imported.cover[0])


def create(filename: str, data: bytes) -> dict:
    imported = importer.import_book(filename, data)
    title, author = imported.title, imported.author
    style, chapters = _chapters(imported)
    slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")[:40] or "book"
    book = {
        "id": f"{slug}-{uuid.uuid4().hex[:6]}",
        "title": title, "author": author, "created": time.time(), "quote_style": style,
        "analyzer": "heuristic", "narrator": {}, "characters": [], "chapters": chapters,
        "position": {"chapter": 0, "segment": 0}, "source": None, "cover": None,
    }
    apply_analysis(book, heuristic.analyze(chapters), "heuristic")
    _store_files(book, filename, data, imported)
    save(book)
    return book


def update_source(book_id: str, filename: str, data: bytes) -> dict:
    """Re-read a book from its file: cover, chapter names, and (if the text changed) the text.

    When the file has the same chapters, only titles and cover change, so the reading position,
    speakers and voices all stay. Otherwise the text is replaced, the characters are found again,
    and the reading position moves to the same point in the new text.
    """
    imported = importer.import_book(filename, data)
    style, chapters = _chapters(imported)
    with lock(book_id):
        book = load(book_id)
        # Same chapters, give or take a heading line the new importer now strips: keep the text.
        same = len(chapters) == len(book["chapters"]) and all(
            abs(len(new["segments"]) - len(old["segments"])) <= 3 for new, old in zip(chapters, book["chapters"]))
        if same:
            for old, new in zip(book["chapters"], chapters):
                old["title"], old["section"] = new["title"], new["section"]
        else:
            progress = summary(book)["progress"]
            book["chapters"], book["quote_style"] = chapters, style
            apply_analysis(book, heuristic.analyze(chapters), "heuristic")
            book["position"] = _position_at(chapters, progress)
        book["title"] = imported.title or book["title"]
        book["author"] = imported.author or book["author"]
        _store_files(book, filename, data, imported)
        save(book)
    return {**summary(book), "kept_text": same}


def _position_at(chapters: list[dict], fraction: float) -> dict:
    target = int(fraction * sum(len(c["segments"]) for c in chapters))
    for i, ch in enumerate(chapters):
        if target < len(ch["segments"]):
            return {"chapter": i, "segment": target}
        target -= len(ch["segments"])
    return {"chapter": len(chapters) - 1, "segment": len(chapters[-1]["segments"]) - 1}


def apply_analysis(book: dict, result: dict, analyzer: str) -> None:
    """Install a fresh cast (from either analyzer) and give everyone a voice."""
    book["analyzer"] = analyzer
    narrator, cast = voices.cast(result["characters"], book.get("narrator"))
    book["narrator"] = narrator
    book["characters"] = cast


def recount_lines(book: dict) -> None:
    counts: dict[str, set] = {}
    for ci, ch in enumerate(book["chapters"]):
        for seg in ch["segments"]:
            if seg["kind"] == "dialogue" and seg["speaker"]:
                counts.setdefault(seg["speaker"], set()).add((ci, seg["q"]))
    for c in book["characters"]:
        c["lines"] = len(counts.get(c["id"], ()))


def recast_all() -> None:
    """Re-pick voices in every book (keeping the ones set by hand), e.g. after new voices arrive."""
    for summary_ in list_books():
        book = load(summary_["id"])
        with lock(book["id"]):
            book["narrator"], book["characters"] = voices.cast(book["characters"], book["narrator"])
            save(book)


SEGMENTS_VERSION = 2  # bump when segmentation rules change; prepare() re-chunks existing books
PROFILE_VERSION = 2  # bump when the free analyzer's voice profiling changes; prepare() re-profiles books
CAST_VERSION = 2  # bump when voice descriptions or design settings change; prepare() re-casts every book
SPEAKERS_VERSION = 2  # 2: pronouns ("She's") had become characters; prepare() hands their lines out again


def fix_pronoun_characters(book: dict) -> bool:
    """Remove "characters" that are really pronouns, giving their lines to whoever "she"/"he" was.

    Only those lines change; speakers you set by hand elsewhere stay as they are.
    """
    import copy

    bogus = {c["id"] for c in book["characters"] if c["name"].lower() in heuristic.PRONOUNS}
    if not bogus:
        return False
    chapters = copy.deepcopy(book["chapters"])
    fresh = {c["id"]: c for c in heuristic.analyze(chapters)["characters"]}
    have = {c["id"] for c in book["characters"]} - bogus
    for ch, again in zip(book["chapters"], chapters):
        for seg, seg_again in zip(ch["segments"], again["segments"]):
            if seg.get("speaker") in bogus:
                who = seg_again.get("speaker")
                if who and who not in have and who in fresh:  # e.g. "the old woman", hidden inside "She" before
                    book["characters"].append(fresh[who])
                    have.add(who)
                seg["speaker"] = who if who in have else None
    book["characters"] = [c for c in book["characters"] if c["id"] not in bogus]
    recount_lines(book)
    book["narrator"], book["characters"] = voices.cast(book["characters"], book["narrator"])
    return True


def reprofile(book: dict) -> None:
    """Re-read how each character sounds with the current rules, keeping who says what as it is."""
    import copy

    fresh = {c["id"]: c for c in heuristic.analyze(copy.deepcopy(book["chapters"]))["characters"]}
    for c in book["characters"]:
        if c["id"] in fresh:
            c["pitch"], c["summary"] = fresh[c["id"]]["pitch"], fresh[c["id"]]["summary"]
    book["narrator"], book["characters"] = voices.cast(book["characters"], book["narrator"])


def rechunk(book: dict) -> None:
    """Re-split each run of narration or each quote with the current rules.

    Paragraphs and quotes stay the same, so speakers carry over by quote, and the reading
    position moves to whichever new line contains the start of the old one.
    """
    pos = book.get("position", {"chapter": 0, "segment": 0})
    for ci, ch in enumerate(book["chapters"]):
        old, new, moved = ch["segments"], [], {}
        i = 0
        while i < len(old):
            j = i
            while j + 1 < len(old) and (old[j + 1]["para"], old[j + 1]["kind"], old[j + 1]["q"]) == (old[i]["para"], old[i]["kind"], old[i]["q"]):
                j += 1
            group = old[i:j + 1]
            starts, at = [], 0
            for s in group:
                starts.append(at)
                at += len(s["text"]) + 1
            piece_start = len(new)
            at = 0
            for piece in segmenter._chunks(" ".join(s["text"] for s in group)):
                new.append({**group[0], "id": len(new), "text": piece, "_start": at})
                at += len(piece) + 1
            for s, start in zip(group, starts):
                moved[s["id"]] = max(k for k in range(piece_start, len(new)) if new[k]["_start"] <= start)
            i = j + 1
        for s in new:
            del s["_start"]
        ch["segments"] = new
        if ci == pos.get("chapter"):
            pos["segment"] = moved.get(pos["segment"], 0)


def prepare() -> None:
    """Bring older libraries up to date: current segmentation rules, and audio in the current format."""
    from . import tts

    values = settings()
    if values.get("audio_version", 1) < tts.AUDIO_VERSION:
        # Lines are made again, at the current quality, the next time they're played.
        import shutil

        for d in [*BOOKS_DIR.glob("*/audio"), DATA_DIR / "previews"]:
            shutil.rmtree(d, ignore_errors=True)
        values["audio_version"] = tts.AUDIO_VERSION
        save_settings(values)
    if values.get("profile_version", 1) < PROFILE_VERSION:
        for s in list_books():
            book = load(s["id"])
            if book["analyzer"] == "heuristic":  # Claude's profiles don't need it
                with lock(book["id"]):
                    reprofile(book)
                    save(book)
        values["profile_version"] = PROFILE_VERSION
        save_settings(values)
    if values.get("speakers_version", 1) < SPEAKERS_VERSION:
        for s in list_books():
            book = load(s["id"])
            with lock(book["id"]):
                if fix_pronoun_characters(book):
                    save(book)
        values["speakers_version"] = SPEAKERS_VERSION
        save_settings(values)
    if values.get("cast_version", 1) < CAST_VERSION:
        recast_all()  # voices you picked by hand are kept
        values["cast_version"] = CAST_VERSION
        save_settings(values)
    if values.get("segments_version", 1) >= SEGMENTS_VERSION:
        return
    for s in list_books():
        book = load(s["id"])
        with lock(book["id"]):
            rechunk(book)
            save(book)
    values["segments_version"] = SEGMENTS_VERSION
    save_settings(values)


def voice_for(book: dict, seg: dict) -> dict:
    if seg["kind"] == "dialogue" and seg.get("speaker"):
        for c in book["characters"]:
            if c["id"] == seg["speaker"]:
                return {"voice": c["voice"], "rate": c["rate"], "pitch_shift": c.get("pitch_shift", 0)}
    n = book["narrator"]
    return {"voice": n["voice"], "rate": n.get("rate", voices.DEFAULT_RATE), "pitch_shift": n.get("pitch_shift", 0)}


def delete(book_id: str) -> None:
    import shutil

    with lock(book_id):
        shutil.rmtree(book_dir(book_id), ignore_errors=True)
        _cache.pop(book_id, None)
