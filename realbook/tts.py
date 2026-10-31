"""Speech synthesis (system voices, Kokoro or Qwen designed voices), cached on disk."""

from __future__ import annotations

import hashlib
import re
import threading
from pathlib import Path

from . import abbrev, designed, kokoro_tts, system

AUDIO_VERSION = 3  # bump when the audio format changes; store.prepare() clears audio made the old way
#                   3: designed lines fade out instead of stopping dead, and clipped ones are made again
_locks: dict[str, threading.Lock] = {}
_locks_guard = threading.Lock()


class _Gate:
    """Lets one Kokoro render run at a time, serving lines needed now before prefetched ones."""

    def __init__(self) -> None:
        self._cond = threading.Condition()
        self._busy = False
        self._urgent_waiting = 0

    def __enter__(self):
        return self

    def acquire(self, urgent: bool) -> None:
        with self._cond:
            if urgent:
                self._urgent_waiting += 1
            while self._busy or (not urgent and self._urgent_waiting):
                self._cond.wait()
            if urgent:
                self._urgent_waiting -= 1
            self._busy = True

    def release(self) -> None:
        with self._cond:
            self._busy = False
            self._cond.notify_all()


_kokoro_gate = _Gate()


# A drawn-out sound written with hyphens ("Oh-h-h-h", "um-m-m", "Sh-h-h") was spelled out letter by
# letter. Joined up ("Ohhh") it's said as one sound. Only single repeated letters count, so words
# like "wide-eyed" stay as they are.
STRETCHED = re.compile(r"(\w)((?:-\1(?=-|\b))+)", re.IGNORECASE)
# Laughs: voices stumble over "Ah-h-h, hah!" and "Ho-ho-ho-o-o-o!"; in listening tests "Ha ha!" and
# "Ho ho ho!" sounded like laughing.
AH_HAH = re.compile(r"\b(a)h+(?:-h)*,?\s+hah\b", re.IGNORECASE)
LAUGH_RUN = re.compile(r"\b(h[aeo]+h?(?:-h[aeo]+h?)+)(?:-[aeo])*\b", re.IGNORECASE)


def _clean(text: str) -> str:
    text = text.replace("[[", "(").replace("]]", ")")  # never pass embedded commands through
    text = AH_HAH.sub(lambda m: ("H" if m.group(1).isupper() else "h") + "a ha", text)
    text = LAUGH_RUN.sub(lambda m: m.group(1).replace("-", " "), text)
    text = STRETCHED.sub(lambda m: m.group(1) + m.group(1).lower() * min(3, m.group(2).count("-")), text)
    text = re.sub(r"[_*#]+", " ", text)
    text = text.replace("—", ", ").replace("–", ", ")
    return abbrev.expand(" ".join(text.split()))


def _resolve(text: str, voice: str, style: str) -> tuple[str, str, str]:
    """What will really be read: the voice to read it if this one was removed, and the style if it can do it."""
    engine = designed.engine_of(voice)
    if engine and not designed.installed(engine):
        voice = "kokoro:af_heart"  # designed voices were removed; keep reading with the next best
    if voice.startswith("kokoro:") and not kokoro_tts.installed():
        voice = system.default_voice()  # natural voices were removed; keep reading with a system voice
    if not (designed.supports(voice, style) or (style == "quiet" and voice.startswith("kokoro:"))):
        style = ""  # same audio as usual, so the same cached file
    if designed.engine_of(voice):
        return designed.spaced_dots(_clean(designed.DASHES.sub("…", text))), voice, style
    return _clean(text), voice, style


def _key(text: str, voice: str, rate: int, pitch_shift: int, style: str, take: int) -> str:
    return hashlib.sha1((f"{AUDIO_VERSION}|{voice}|{rate}|{pitch_shift}|{text}{'|' + designed.style_tag(style) if style else ''}"
                         f"{f'|take{take}' if take else ''}{f'|pauses{designed.PAUSES_VERSION}' if designed.SPACED_DOTS in text else ''}").encode()).hexdigest()


def can_vary(voice: str) -> bool:
    """Designed voices read a line differently each time; the others always the same."""
    return bool(designed.engine_of(_resolve("", voice, "")[1]))


def audio_path(cache_dir: Path, text: str, voice: str, rate: int, pitch_shift: int, style: str = "", take: int = 0) -> Path:
    """Where this line's audio is, or will be once it's made."""
    text, voice, style = _resolve(text, voice, style)
    return cache_dir / f"{_key(text, voice, rate, pitch_shift, style, take)}{system.AUDIO_EXT}"


def synthesize(cache_dir: Path, text: str, voice: str, rate: int, pitch_shift: int, urgent: bool = True,
               style: str = "", take: int = 0) -> Path:
    """Render `text` to an audio file (once) and return its path. `style` is how the narration says the
    line is spoken ("quiet", "loud", "upset"); voices that can't do it read it as usual. `take` above 0
    is another reading of the line (Read Again)."""
    if urgent:
        designed.note_listening()
    text, voice, style = _resolve(text, voice, style)
    key = _key(text, voice, rate, pitch_shift, style, take)
    out = cache_dir / f"{key}{system.AUDIO_EXT}"
    if out.exists():
        return out
    with _locks_guard:
        lock = _locks.setdefault(key, threading.Lock())
    with lock:
        if out.exists():
            return out
        cache_dir.mkdir(parents=True, exist_ok=True)
        tmp = out.with_suffix(".tmp" + system.AUDIO_EXT)
        if designed.engine_of(voice):
            designed.synthesize(tmp, text, voice, urgent, style)  # has its own queue, with the same priorities
        elif voice.startswith("kokoro:"):
            _kokoro_gate.acquire(urgent)
            try:
                kokoro_tts.synthesize(tmp, text, voice, rate, pitch_shift, style)
            finally:
                _kokoro_gate.release()
        else:
            system.speak(text, voice, rate, pitch_shift, tmp)
        tmp.rename(out)
    return out


def can_group(voice: str, style: str) -> bool:
    """Lines in a designed voice, read as usual, can be made together."""
    voice = _resolve("", voice, style)
    return bool(designed.engine_of(voice[1])) and not voice[2]


def synthesize_many(cache_dir: Path, voice: str, rate: int, pitch_shift: int, lines: list[tuple[str, int]]) -> None:
    """Render several (text, take) lines in one designed voice together. A line someone else is making
    just now is left to them."""
    wanted: dict[Path, str] = {}
    held = []
    try:
        for text, take in lines:
            text = _resolve(text, voice, "")[0]
            key = _key(text, _resolve(text, voice, "")[1], rate, pitch_shift, "", take)
            out = cache_dir / f"{key}{system.AUDIO_EXT}"
            with _locks_guard:
                lock = _locks.setdefault(key, threading.Lock())
            if out in wanted or out.exists() or not lock.acquire(blocking=False):
                continue
            held.append(lock)
            wanted[out] = text
        if not wanted:
            return
        cache_dir.mkdir(parents=True, exist_ok=True)
        designed.synthesize_many(_resolve("", voice, "")[1], [(out.with_suffix(".tmp" + system.AUDIO_EXT), text) for out, text in wanted.items()])
        for out in wanted:
            out.with_suffix(".tmp" + system.AUDIO_EXT).rename(out)
    finally:
        for lock in held:
            lock.release()
