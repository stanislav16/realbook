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


def _clean(text: str) -> str:
    text = text.replace("[[", "(").replace("]]", ")")  # never pass embedded commands through
    text = STRETCHED.sub(lambda m: m.group(1) + m.group(1).lower() * min(3, m.group(2).count("-")), text)
    text = re.sub(r"[_*#]+", " ", text)
    text = text.replace("—", ", ").replace("–", ", ")
    return abbrev.expand(" ".join(text.split()))


def synthesize(cache_dir: Path, text: str, voice: str, rate: int, pitch_shift: int, urgent: bool = True,
               style: str = "") -> Path:
    """Render `text` to an audio file (once) and return its path. `style` is how the narration says the
    line is spoken ("quiet", "loud", "upset"); voices that can't do it read it as usual."""
    text = _clean(text)
    engine = designed.engine_of(voice)
    if engine and not designed.installed(engine):
        voice = "kokoro:af_heart"  # designed voices were removed; keep reading with the next best
    if voice.startswith("kokoro:") and not kokoro_tts.installed():
        voice = system.default_voice()  # natural voices were removed; keep reading with a system voice
    if not (designed.supports(voice, style) or (style == "quiet" and voice.startswith("kokoro:"))):
        style = ""  # same audio as usual, so the same cached file
    key = hashlib.sha1(f"{AUDIO_VERSION}|{voice}|{rate}|{pitch_shift}|{text}{'|' + style if style else ''}".encode()).hexdigest()
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
