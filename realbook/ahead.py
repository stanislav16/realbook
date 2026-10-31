"""Keeps the next hours of the book being listened to ready for the iPhone, so it can carry on away
from this Mac without a whole offline copy.

The iPhone asks for the plan whenever it can reach this Mac and saves the lines that are ready. Lines
are saved by what they sound like (their audio file's name), so when one changes (another voice, a
fix, Read Again) only that line is made and saved again.
"""

from __future__ import annotations

import hashlib
import json
import logging
import subprocess
import threading
import time

from . import designed, heuristic, lines, store, system

HOURS = 4
WORDS_PER_HOUR = 9300  # about how fast the voices read: Dune is 205,000 words and about 22 hours
RESUME_WITHIN = 3 * 86400  # after this Mac restarts, carry on if the iPhone asked this recently
WINDOW = 64  # lines looked at together, and then the plan is made again: the reader may have moved on, or a voice changed
GROUP = 8  # lines made at once: more than this is no faster
GROUP_CHARS = 1200  # and no longer than this in all, so someone who starts listening doesn't wait long

log = logging.getLogger(__name__)

_lock = threading.Lock()
_wanted: str | None = None
_thread: threading.Thread | None = None
_state = {"book": None, "state": "idle", "done": 0, "total": 0}


def enabled() -> bool:
    return store.settings().get("ahead_enabled", True)


def plan(book: dict) -> list[dict]:
    """The lines to keep, in order: the next HOURS from where the reader is, and the lines of this
    chapter before it that are already made (to go back over them)."""
    at = book.get("position") or {}
    first, line = at.get("chapter", 0), at.get("segment", 0)
    words, out = 0, []
    for ci in range(first, len(book["chapters"])):
        segs = book["chapters"][ci]["segments"]
        styles = heuristic.line_styles(segs)
        for i, seg in enumerate(segs):
            where = lines.path(book, segs, seg, styles)
            ready = where.exists()
            behind = ci == first and i < line
            if behind and not ready:
                continue
            n = len(seg["text"].split())
            out.append({"chapter": ci, "segment": i, "key": where.stem, "ready": ready, "words": n, "behind": behind})
            if not behind:
                words += n
            if words >= HOURS * WORDS_PER_HOUR:
                return out
    return out


def manifest(book: dict) -> dict:
    """What the iPhone needs to know to keep the lines: `lines` are [chapter, segment, key, ready, words]."""
    wanted = plan(book)
    signs = {}
    for ci in sorted({l["chapter"] for l in wanted}):
        ch = book["chapters"][ci]
        signs[str(ci)] = hashlib.sha1(json.dumps([ch["title"], ch.get("section"), ch["segments"]], sort_keys=True, ensure_ascii=False).encode()).hexdigest()
    return {"lines": [[l["chapter"], l["segment"], l["key"], l["ready"], l["words"]] for l in wanted],
            "chapters": signs, "making": status()}


def status() -> dict:
    return {**_state, "enabled": enabled()}


def want(book_id: str) -> None:
    """Start, or carry on, making the next hours of this book."""
    global _wanted, _thread
    if not enabled():
        return
    values = store.settings()
    last = values.get("ahead_book") or {}
    if last.get("book") != book_id or time.time() - last.get("asked", 0) > 3600:
        values["ahead_book"] = {"book": book_id, "asked": time.time()}
        store.save_settings(values)
    with _lock:
        _wanted = book_id
        if _thread is None:
            _state["state"] = "making"  # it says so itself if there's nothing to do; the iPhone asks again soon
            _thread = threading.Thread(target=_run, daemon=True, name="keep-ahead")
            _thread.start()


def resume() -> None:
    """When this Mac starts: carry on for the book the iPhone asked about lately."""
    last = store.settings().get("ahead_book") or {}
    if last.get("book") and time.time() - last.get("asked", 0) < RESUME_WITHIN:
        try:
            store.load(last["book"])
        except KeyError:
            return
        want(last["book"])


def set_enabled(on: bool) -> dict:
    values = store.settings()
    values["ahead_enabled"] = on
    store.save_settings(values)
    if on:
        resume()
    return status()


def _on_battery() -> bool:
    """Hours of work drain a laptop: it waits until it's plugged in."""
    if not system.MAC:
        return False
    try:
        return "Battery Power" in subprocess.run(["pmset", "-g", "ps"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return False


def _run() -> None:
    global _thread
    try:
        _work()
    except Exception:
        log.exception("Stopped keeping lines ready for the iPhone")
        _state["state"] = "error"
    finally:
        with _lock:
            _thread = None


def _groups(book: dict, todo: list[dict]) -> list[list[dict]]:
    """Lines to make together: the same voice and about the same length, since a group takes as long
    as its longest line. The groups go in book order, as far as they can."""
    voices: dict[str, list[dict]] = {}
    alone = []
    for l in todo:
        segs = book["chapters"][l["chapter"]]["segments"]
        voice = lines.can_group(book, segs, segs[l["segment"]])
        if voice:
            voices.setdefault(voice, []).append(l)
        else:
            alone.append([l])
    groups = alone
    for same in voices.values():
        same.sort(key=lambda l: len(book["chapters"][l["chapter"]]["segments"][l["segment"]]["text"]))
        group: list[dict] = []
        chars = 0
        for l in same:
            n = len(book["chapters"][l["chapter"]]["segments"][l["segment"]]["text"])
            if group and (len(group) >= GROUP or chars + n > GROUP_CHARS):
                groups.append(group)
                group, chars = [], 0
            group.append(l)
            chars += n
        if group:
            groups.append(group)
    return sorted(groups, key=lambda g: min((l["chapter"], l["segment"]) for l in g))


def _make(book: dict, group: list[dict]) -> None:
    pairs = [(book["chapters"][l["chapter"]]["segments"], book["chapters"][l["chapter"]]["segments"][l["segment"]]) for l in group]
    if len(pairs) > 1 and not designed.listening():
        try:
            return lines.make_many(book, pairs)
        except Exception:
            log.exception("Couldn't make lines together; making them one at a time")
    for segs, seg in pairs:
        lines.make(book, segs, seg, urgent=False)  # someone listening goes first


def _work() -> None:
    fails = 0
    while True:
        book_id = _wanted
        try:
            book = store.load(book_id)
        except KeyError:
            book = None
        wanted = [l for l in plan(book) if not l["behind"]] if book and enabled() else []
        todo = [l for l in wanted if not l["ready"]]
        _state.update(book=book_id, done=len(wanted) - len(todo), total=len(wanted))
        if not todo or fails >= 3:
            with _lock:
                if book_id == _wanted:  # nobody asked for another book meanwhile
                    _state["state"] = "error" if fails >= 3 else "idle"
                    return
            fails = 0
            continue
        if _on_battery():
            _state["state"] = "battery"
            time.sleep(30)
            continue
        _state["state"] = "making"
        for group in _groups(book, todo[:WINDOW]):
            if _wanted != book_id or not enabled():
                break
            try:
                system.keep_awake()
                _make(book, group)
                fails = 0
                _state["done"] += len(group)
            except Exception:
                log.exception("Couldn't make a line for the iPhone")
                fails += 1
                if fails >= 3:
                    break
