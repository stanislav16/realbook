"""One line of a book as audio: what its voice says and how, wherever the line is asked for."""

from __future__ import annotations

import hashlib
import tempfile
import threading
import wave
from pathlib import Path

import numpy as np

from . import heuristic, store, system, tts, voices

RATE = 24000
GAP_TITLE = 0.8  # seconds between the chapter's title and its first line, as in an exported audiobook
_joining = threading.Lock()


def _spec(book: dict, segments: list[dict], seg: dict, styles: dict | None) -> tuple:
    v = store.voice_for(book, seg)
    if styles is None:
        styles = heuristic.line_styles(segments)
    style = styles.get(seg["q"], "") if seg["kind"] == "dialogue" and seg.get("speaker") else ""
    return (store.audio_dir(book["id"]), store.spoken(book, heuristic.as_said(segments, seg)), v["voice"], v["rate"], v.get("pitch_shift", 0)), {
        "style": style, "take": seg.get("take", 0)}


def _heading(book: dict, segments: list[dict], seg: dict) -> tuple | None:
    """For a chapter's first line: the narrator saying the chapter's title (the args for tts)."""
    if not segments or seg is not segments[0]:
        return None
    chapter = next((ch for ch in book["chapters"] if ch["segments"] is segments), None)
    title = chapter and store.spoken_title(chapter)
    if not title:
        return None
    n = book["narrator"]
    return (store.audio_dir(book["id"]), store.spoken(book, title), n["voice"], n.get("rate", voices.DEFAULT_RATE), n.get("pitch_shift", 0))


def _with_heading(line: Path, heading: Path) -> Path:
    """Where the chapter's title followed by its first line is kept, as one clip."""
    key = hashlib.sha1(f"heading1|{heading.name}|{line.name}".encode()).hexdigest()
    return line.parent / f"{key}{system.AUDIO_EXT}"


def path(book: dict, segments: list[dict], seg: dict, styles: dict | None = None) -> Path:
    """Where the line's audio is, or will be once it's made."""
    args, kw = _spec(book, segments, seg, styles)
    line = tts.audio_path(*args, **kw)
    heading = _heading(book, segments, seg)
    return _with_heading(line, tts.audio_path(*heading)) if heading else line


def make(book: dict, segments: list[dict], seg: dict, urgent: bool = True, styles: dict | None = None) -> Path:
    """The line's audio, made now if it hasn't been yet. A chapter's first line starts with the narrator
    saying the chapter's title, so a listener hears where one chapter ends and the next begins."""
    args, kw = _spec(book, segments, seg, styles)
    line = tts.synthesize(*args, urgent=urgent, **kw)
    heading = _heading(book, segments, seg)
    if not heading:
        return line
    title = tts.synthesize(*heading, urgent=urgent)
    out = _with_heading(line, title)
    with _joining:
        if not out.exists():
            joined = np.concatenate([_samples(title), np.zeros(int(GAP_TITLE * RATE), np.int16), _samples(line)])
            with tempfile.NamedTemporaryFile(suffix=".wav", dir=out.parent, delete=False) as tmp:
                wav = Path(tmp.name)
            with wave.open(str(wav), "wb") as w:
                w.setnchannels(1)
                w.setsampwidth(2)
                w.setframerate(RATE)
                w.writeframes(joined.astype("<i2").tobytes())
            done = out.with_suffix(".tmp" + system.AUDIO_EXT)
            system.encode(wav, done, RATE)
            done.rename(out)
    return out


def _samples(path: Path) -> np.ndarray:
    """A cached clip as 24 kHz mono 16-bit samples, whatever made it."""
    if system.MAC:
        with tempfile.NamedTemporaryFile(suffix=".wav", dir=path.parent, delete=False) as tmp:
            wav = Path(tmp.name)
        try:
            system.run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{RATE}", "-c", "1", str(path), str(wav)],
                       check=True, capture_output=True, timeout=120)
            with wave.open(str(wav)) as w:
                return np.frombuffer(w.readframes(w.getnframes()), "<i2")
        finally:
            wav.unlink(missing_ok=True)
    with wave.open(str(path)) as w:
        rate, channels, width = w.getframerate(), w.getnchannels(), w.getsampwidth()
        data = np.frombuffer(w.readframes(w.getnframes()), {1: "u1", 2: "<i2", 4: "<i4"}[width]).astype(np.float64)
    if width == 1:
        data = (data - 128) * 256
    elif width == 4:
        data = data / 65536
    data = data.reshape(-1, channels).mean(axis=1)
    if rate != RATE and len(data):
        data = np.interp(np.arange(0, len(data), rate / RATE), np.arange(len(data)), data)
    return np.clip(data, -32768, 32767).astype(np.int16)


def can_group(book: dict, segments: list[dict], seg: dict, styles: dict | None = None) -> str | None:
    """The voice this line can be made together with others in, if it can."""
    args, kw = _spec(book, segments, seg, styles)
    return args[2] if tts.can_group(args[2], kw["style"]) else None


def make_many(book: dict, group: list[tuple[list[dict], dict]]) -> None:
    """Lines in the same voice, each (its chapter's segments, the line), made together."""
    specs = [_spec(book, segs, seg, None) for segs, seg in group]
    cache_dir, _, voice, rate, pitch_shift = specs[0][0]
    tts.synthesize_many(cache_dir, voice, rate, pitch_shift, [(args[1], kw["take"]) for args, kw in specs])
    for segs, seg in group:
        if _heading(book, segs, seg):
            make(book, segs, seg, urgent=False)  # a chapter's first line, with its title before it
