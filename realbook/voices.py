"""Installed macOS voices and casting them to characters."""

from __future__ import annotations

import re
import subprocess
import time

from . import kokoro_tts, qwen_tts, store, system

# Gender / age / quality for voices macOS ships or offers as downloads.
# quality: 3 = Premium, 2 = Enhanced or a good classic voice, 1 = basic/robotic.
KNOWN = {
    # Classic Nuance/Apple voices
    "Samantha": ("female", "adult", 2), "Alex": ("male", "adult", 2), "Daniel": ("male", "adult", 2),
    "Karen": ("female", "adult", 2), "Moira": ("female", "adult", 2), "Tessa": ("female", "adult", 2),
    "Rishi": ("male", "adult", 2), "Aman": ("male", "adult", 2), "Tara": ("female", "adult", 2),
    "Fiona": ("female", "adult", 2), "Veena": ("female", "adult", 2), "Kathy": ("female", "adult", 1),
    "Fred": ("male", "old", 1), "Ralph": ("male", "adult", 1), "Albert": ("male", "old", 1),
    "Junior": ("male", "child", 1), "Victoria": ("female", "adult", 1), "Agnes": ("female", "adult", 1),
    "Bruce": ("male", "adult", 1), "Vicki": ("female", "adult", 1), "Princess": ("female", "child", 1),
    # Eloquence voices
    "Eddy": ("male", "young", 1), "Flo": ("female", "young", 1), "Grandma": ("female", "old", 1),
    "Grandpa": ("male", "old", 1), "Reed": ("male", "adult", 1), "Rocko": ("male", "adult", 1),
    "Sandy": ("female", "adult", 1), "Shelley": ("female", "adult", 1),
    # Downloadable Enhanced / Premium voices
    "Ava": ("female", "adult", 2), "Allison": ("female", "adult", 2), "Susan": ("female", "adult", 2),
    "Zoe": ("female", "young", 2), "Joelle": ("female", "young", 2), "Noelle": ("female", "adult", 2),
    "Evan": ("male", "adult", 2), "Nathan": ("male", "adult", 2), "Tom": ("male", "adult", 2),
    "Aaron": ("male", "adult", 2), "Nicky": ("female", "young", 2), "Jamie": ("male", "young", 2),
    "Serena": ("female", "adult", 2), "Kate": ("female", "adult", 2), "Oliver": ("male", "adult", 2),
    "Stephanie": ("female", "adult", 2), "Arthur": ("male", "adult", 2), "Martha": ("female", "old", 2),
    "Lee": ("male", "adult", 2), "Matilda": ("female", "adult", 2), "Gordon": ("male", "adult", 2),
    "Catherine": ("female", "adult", 2), "Isha": ("female", "adult", 2), "Sangeeta": ("female", "adult", 2),
    "Siobhan": ("female", "adult", 2), "Emily": ("female", "young", 2), "Malcolm": ("male", "adult", 2),
}
NOVELTY = {"Bad News", "Bahh", "Bells", "Boing", "Bubbles", "Cellos", "Wobble", "Good News", "Jester",
           "Organ", "Superstar", "Trinoids", "Whisper", "Zarvox", "Deranged", "Hysterical", "Pipe Organ"}

ACCENT_LOCALE = {
    "american": "en_US", "british": "en_GB", "scottish": "en-scotland", "irish": "en_IE",
    "australian": "en_AU", "indian": "en_IN", "south_african": "en_ZA",
    # Characters with a foreign accent in an English book: closest-sounding English voice.
    "french": "en_GB", "german": "en_GB", "italian": "en_GB", "spanish": "en_US",
}
LOCALE_NEIGHBOURS = {"en-scotland": ["en_GB", "en_IE"], "en_IE": ["en-scotland", "en_GB"], "en_GB": ["en_IE", "en_AU"],
                     "en_AU": ["en_GB", "en_ZA"], "en_ZA": ["en_GB", "en_AU"], "en_IN": ["en_GB"], "en_US": []}
DEFAULT_RATE = 180
# Accents Kokoro can't do. With "Apple voices for accents" on, these characters keep an
# Apple voice in their own accent when one is installed.
RARE_ACCENTS = {"scottish", "irish", "indian", "australian", "south_african"}


_voice_cache: tuple[float, list[dict]] = (0.0, [])


def installed_voices() -> list[dict]:
    """Installed voices, re-read every few seconds so new downloads show up without a restart."""
    global _voice_cache
    if time.monotonic() - _voice_cache[0] > 5:
        _voice_cache = (time.monotonic(), _read_voices())
    return _voice_cache[1]


def _read_voices() -> list[dict]:
    """Parse `say -v ?` into [{"name", "base", "locale", "gender", "age", "quality"}]."""
    if not system.MAC:
        return [{**v, "base": v["name"].replace("Microsoft ", "").replace(" Desktop", ""), "quality": 1,
                 "novelty": False, "engine": "system"} for v in system.system_voices()]
    out = subprocess.run(["say", "-v", "?"], capture_output=True, text=True, check=True).stdout
    voices = []
    seen = set()
    for line in out.splitlines():
        m = re.match(r"^(.+?)\s{2,}([a-zA-Z]{2}[_-][\w-]+)\s+#", line) or re.match(r"^(.+?\))\s+([a-zA-Z]{2}[_-][\w-]+)\s+#", line)
        if not m:
            continue
        name, locale = m.group(1).strip(), m.group(2)
        if name in seen:
            continue
        seen.add(name)
        base = re.sub(r"\s*\(.*\)$", "", name)
        variant = re.search(r"\((Premium|Enhanced)\)", name)
        gender, age, quality = KNOWN.get(base, ("unknown", "adult", 1))
        if variant:
            quality = 3 if variant.group(1) == "Premium" else max(quality, 2)
        voices.append({
            "name": name, "base": base, "locale": locale, "gender": gender, "age": age,
            "quality": quality, "novelty": base in NOVELTY, "engine": "apple",
        })
    return voices


def english_voices() -> list[dict]:
    """Apple voices worth casting: English, and not the novelty ones."""
    return [v for v in installed_voices() if v["locale"].lower().startswith("en") and not v["novelty"]]


def use_kokoro() -> bool:
    return kokoro_tts.installed() and store.settings().get("voice_engine", "kokoro") == "kokoro"


def use_qwen() -> bool:
    return qwen_tts.installed() and store.settings().get("voice_engine", "kokoro") == "qwen"


def selectable_voices() -> list[dict]:
    """Every voice offered in the voice menus: Kokoro (when installed) first, then Apple."""
    return kokoro_tts.catalog() + english_voices()


def lookup(name: str) -> dict | None:
    if name.startswith("kokoro:"):
        return kokoro_tts.describe(name)
    if name.startswith("qwen:"):
        return qwen_tts.describe(name)
    return next((v for v in installed_voices() if v["name"] == name), None)


def _components(name: str) -> list[str]:
    return name.split(":", 1)[1].split("+") if name.startswith("kokoro:") else [name]


def _usage_penalty(voice: dict, usage: dict[str, int]) -> float:
    """Reusing a voice costs points; so does a blend containing a voice that's already in use."""
    parts = _components(voice["name"])
    if len(parts) == 1:
        return usage.get(parts[0], 0) * 4.5
    return usage.get(voice["name"], 0) * 4.5 + sum(usage.get(p, 0) for p in parts) * 3


def _accent_score(voice_locale: str, wanted: str) -> float:
    if not wanted:
        # No accent in the book: keep to neutral US/UK voices rather than a regional one.
        return 1.0 if voice_locale in ("en_US", "en_GB") else -3.0
    if voice_locale == wanted:
        return 3.0
    if voice_locale in LOCALE_NEIGHBOURS.get(wanted, []):
        return 1.5
    return 0.0


def _score(voice: dict, char: dict) -> float:
    s = voice["quality"] * 1.5
    g = char.get("gender", "unknown")
    if g != "unknown":
        if voice["gender"] == g:
            s += 10
        elif voice["gender"] != "unknown":
            s -= 20
    age = char.get("age", "adult")
    if voice["age"] == age:
        s += 4 if age in ("old", "child") else 1
    elif age in ("old", "child") and voice["age"] in ("old", "child"):
        s -= 6
    elif voice["age"] in ("old", "child") and age in ("adult", "young"):
        s -= 3
    s += _accent_score(voice["locale"], ACCENT_LOCALE.get(char.get("accent", ""), ""))
    return s


def narrator_voice(voices: list[dict]) -> dict:
    """Best-sounding adult voice: Kokoro's best when installed, else a Premium Apple voice."""
    voices = [v for v in voices if not v.get("blend")]
    preferred = ["Heart", "Ava", "Zoe", "Evan", "Daniel", "Samantha", "Moira", "Karen"]
    def rank(v):
        bonus = (len(preferred) - preferred.index(v["base"])) if v["base"] in preferred else 0
        return (v["quality"], v["age"] == "adult", bonus)
    return max(voices, key=rank)


def cast(characters: list[dict], narrator: dict | None = None) -> tuple[dict, list[dict]]:
    """Assign {"voice", "rate", "pitch"} to the narrator and every character.

    Characters are cast in order of how much they speak, so main characters get the best
    fitting voices. A voice already in use costs points; when one must be shared, the
    characters are separated with different pitch and speed. With designed voices, everyone
    gets a voice of their own, made from their description.
    """
    if use_qwen():
        return _cast_designed(characters, narrator or {})
    apple = english_voices() or installed_voices()
    kokoro = ([v for v in kokoro_tts.catalog() if v["grade"] >= kokoro_tts.CAST_MIN_GRADE] + kokoro_tts.blends()
              if use_kokoro() else [])
    voices = kokoro or apple
    accents_on_apple = store.settings().get("apple_for_accents", True)
    narrator = narrator or {}
    if not (narrator.get("locked") and narrator.get("voice")):
        kept = {k: narrator[k] for k in ("voice_description", "voice_take") if k in narrator}  # for designed voices
        narrator = {**kept, "voice": narrator_voice(voices)["name"], "rate": DEFAULT_RATE, "pitch_shift": 0}
    usage: dict[str, int] = {}
    for part in _components(narrator["voice"]):
        usage[part] = 1
    pitch_used: dict[str, list[int]] = {narrator["voice"]: [narrator.get("pitch_shift", 0)]}
    cast_chars = []
    for char in sorted(characters, key=lambda c: -c.get("lines", 0)):
        if char.get("locked") and char.get("voice"):
            cast_chars.append(char)
            for part in _components(char["voice"]):
                usage[part] = usage.get(part, 0) + 1
            pitch_used.setdefault(char["voice"], []).append(char.get("pitch_shift", 0))
            continue
        candidates = voices
        if kokoro and accents_on_apple and char.get("accent") in RARE_ACCENTS:
            locale = ACCENT_LOCALE[char["accent"]]
            local = [v for v in apple if v["locale"] == locale and v["gender"] in (char.get("gender"), "unknown")]
            candidates = local or voices
        best = max(candidates, key=lambda v: _score(v, char) - _usage_penalty(v, usage))
        name = best["name"]

        # Pitch: description first (deep/high voice, age), then nudge away from others on this voice.
        base_pitch = {-1: -8, 0: 0, 1: 8}[char.get("pitch", 0)]
        if char.get("age") == "old" and best["age"] != "old":
            base_pitch -= 4
        if char.get("age") == "child" and best["age"] != "child":
            base_pitch += 10
        taken = pitch_used.setdefault(name, [])
        shift = base_pitch
        for offset in (0, -7, 7, -12, 12, -16, 16):
            if all(abs(base_pitch + offset - t) >= 6 for t in taken):
                shift = base_pitch + offset
                break
        taken.append(shift)

        rate = DEFAULT_RATE + 25 * char.get("pace", 0)
        if char.get("age") == "old":
            rate -= 15
        elif char.get("age") == "child":
            rate += 10
        for part in _components(name):
            usage[part] = usage.get(part, 0) + 1
        if len(_components(name)) > 1:
            usage[name] = usage.get(name, 0) + 1
        cast_chars.append({**char, "voice": name, "rate": rate, "pitch_shift": max(-20, min(20, shift))})
    order = {c["id"]: i for i, c in enumerate(characters)}
    cast_chars.sort(key=lambda c: order.get(c["id"], 0))
    return narrator, cast_chars


def _designed(person: dict, description: str, seed: str) -> dict:
    voice = qwen_tts.voice_for(description, seed=seed, take=person.get("voice_take", 0))
    return {**person, "voice": voice, "rate": DEFAULT_RATE, "pitch_shift": 0, "designed_from": description}


def _cast_designed(characters: list[dict], narrator: dict) -> tuple[dict, list[dict]]:
    if not (narrator.get("locked") and narrator.get("voice")):
        narrator = _designed(narrator, narrator.get("voice_description") or qwen_tts.NARRATOR_DESCRIPTION, "narrator")
    cast_chars = [c if c.get("locked") and c.get("voice") else _designed(c, qwen_tts.describe_character(c), c["id"])
                  for c in characters]
    return narrator, cast_chars
