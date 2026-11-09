"""Installed macOS voices and casting them to characters."""

from __future__ import annotations

import re
import subprocess
import time

from . import designed, kokoro_tts, store, system

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


def designed_engine() -> designed.Engine | None:
    """The designed-voice engine (Qwen3-TTS) books are read with, if it's chosen."""
    engine = designed.ENGINES.get(store.settings().get("voice_engine", "kokoro"))
    return engine if engine and designed.installed(engine) else None


def selectable_voices() -> list[dict]:
    """Every voice offered in the voice menus: Kokoro (when installed) first, then Apple."""
    return kokoro_tts.catalog() + english_voices()


def lookup(name: str) -> dict | None:
    if name.startswith("kokoro:"):
        return kokoro_tts.describe(name)
    if designed.engine_of(name):
        return designed.describe(name)
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


def narrator_voice(voices: list[dict], gender: str = "unknown") -> dict:
    """Best-sounding adult voice (of the teller's gender, when known): Kokoro's best when
    installed, else a Premium Apple voice."""
    voices = [v for v in voices if not v.get("blend")]
    voices = [v for v in voices if v.get("gender") == gender] or voices
    preferred = ["Heart", "Ava", "Zoe", "Michael", "Evan", "Daniel", "Samantha", "Moira", "Karen"]
    def rank(v):
        bonus = (len(preferred) - preferred.index(v["base"])) if v["base"] in preferred else 0
        return (v["quality"], v["age"] == "adult", bonus)
    return max(voices, key=rank)


def _same_here(person: dict) -> dict:
    """The Kokoro or Apple voice this person has in the author's other book, if it's here too."""
    same = person.get("voice_same") or {}
    if not same.get("voice") or designed.engine_of(same["voice"]) or not lookup(same["voice"]):
        return {}
    return {"voice": same["voice"], "rate": same.get("rate", DEFAULT_RATE), "pitch_shift": same.get("pitch_shift", 0)}


def cast(characters: list[dict], narrator: dict | None = None) -> tuple[dict, list[dict]]:
    """Assign {"voice", "rate", "pitch"} to the narrator and every character.

    Characters are cast in order of how much they speak, so main characters get the best
    fitting voices. A voice already in use costs points; when one must be shared, the
    characters are separated with different pitch and speed. With designed voices, everyone
    gets a voice of their own, made from their description.
    """
    engine = designed_engine()
    if engine:
        return _cast_designed(engine, characters, narrator or {})
    apple = english_voices() or installed_voices()
    kokoro = ([v for v in kokoro_tts.catalog() if v["grade"] >= kokoro_tts.CAST_MIN_GRADE] + kokoro_tts.blends()
              if use_kokoro() else [])
    voices = kokoro or apple
    accents_on_apple = store.settings().get("apple_for_accents", True)
    narrator = narrator or {}
    if not voices:  # Linux, before natural voices are downloaded: everyone is cast when they arrive (store.recast_all)
        return ({"rate": DEFAULT_RATE, "pitch_shift": 0, **narrator, "voice": narrator.get("voice", "")},
                [{"rate": DEFAULT_RATE, "pitch_shift": 0, **c, "voice": c.get("voice", "")} for c in characters])
    if (same := _same_here(narrator)) and not narrator.get("locked"):
        narrator = {**narrator, **same}
    elif not (narrator.get("locked") and narrator.get("voice")):
        # voice_description/take are for designed voices; teller and gender are who tells the book
        kept = {k: narrator[k] for k in ("voice_description", "voice_take", "teller", "gender", "profiled_by",
                                         "voice_same", "voice_from", "carry_checked") if k in narrator}
        narrator = {**kept, "voice": narrator_voice(voices, narrator.get("gender", "unknown"))["name"],
                    "rate": DEFAULT_RATE, "pitch_shift": 0}
    usage: dict[str, int] = {}
    for part in _components(narrator["voice"]):
        usage[part] = 1
    pitch_used: dict[str, list[int]] = {narrator["voice"]: [narrator.get("pitch_shift", 0)]}
    cast_chars = []
    for char in sorted(characters, key=lambda c: -c.get("lines", 0)):
        if (same := _same_here(char)) and not char.get("locked"):
            char = {**char, **same}
        if char.get("locked") and char.get("voice") or same:
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


def _designed(engine: designed.Engine, person: dict, description: str, seed: str, take: int | None = None) -> dict:
    voice = designed.voice_for(engine, description, seed=seed, take=person.get("voice_take", 0) if take is None else take)
    return {**person, "voice": voice, "rate": DEFAULT_RATE, "pitch_shift": 0, "designed_from": description}


def _cast_designed(engine: designed.Engine, characters: list[dict], narrator: dict) -> tuple[dict, list[dict]]:
    def voiced(person: dict, description: str, seed: str) -> dict:
        if person.get("locked") and person.get("voice"):
            return person
        same = person.get("voice_same")
        if same and same.get("kept") and designed.engine_of(same["voice"]) is engine:
            return {**person, "voice": same["voice"], "rate": DEFAULT_RATE, "pitch_shift": 0, "designed_from": same["description"]}
        if same:  # the voice they have in the author's other book (see carry_over)
            return _designed(engine, person, same["description"], same["seed"], same["take"])
        return _designed(engine, person, description, seed)

    narrator = voiced(narrator, narrator.get("voice_description") or designed.narrator_description(narrator), "narrator")
    return narrator, [voiced(c, designed.describe_character(c), c["id"]) for c in characters]


# ------------------------------------------------------------------ the same voice in every book

def _author(book: dict) -> frozenset[str]:
    """The author's name as a set of words, so "Frank Herbert" and "Herbert, Frank" match."""
    words = frozenset(re.findall(r"\w+", (book.get("author") or "").lower()))
    return frozenset() if words <= {"unknown", "author", "anonymous"} else words


def _names(c: dict) -> set[str]:
    return {" ".join(n.lower().split()) for n in [c.get("name", "")] + c.get("aliases", []) + c.get("other_names", []) if n.strip()}


def _same_person(c: dict, other: dict) -> int:
    """2 when they have the same name, 1 when one's name is among the other's names, else 0."""
    if c.get("not_person") or other.get("not_person"):
        return 0
    genders = {c.get("gender", "unknown"), other.get("gender", "unknown")} - {"unknown"}
    if len(genders) > 1:
        return 0
    mine, theirs = " ".join(c.get("name", "").lower().split()), " ".join(other.get("name", "").lower().split())
    if mine and mine == theirs:
        return 2
    return 1 if mine in _names(other) or theirs in _names(c) else 0


def _source(book_id: str, who: str) -> dict | None:
    """The narrator or a character in another book, as they are now."""
    try:
        other = store.load(book_id)
    except KeyError:
        return None
    return other.get("narrator") if who == "narrator" else next((c for c in other["characters"] if c["id"] == who), None)


def _voice_of(person: dict, narrator: bool, depth: int = 0) -> dict:
    """What it takes to give someone else exactly this person's voice, as it is now: when theirs comes
    from a book before that one, from there."""
    kept = bool(person.get("locked") and person.get("voice"))
    if not kept and not person.get("voice_description") and (where := person.get("voice_from")):
        source = _source(where["book"], where["character"]) if depth < 5 else None
        if source:
            return _voice_of(source, narrator, depth + 1)
        if person.get("voice_same"):  # that book is gone: as it was
            return person["voice_same"]
    automatic = designed.narrator_description(person) if narrator else designed.describe_character(person)
    return {"voice": person.get("voice", ""), "rate": person.get("rate", DEFAULT_RATE), "pitch_shift": person.get("pitch_shift", 0),
            "kept": kept, "seed": "narrator" if narrator else person["id"], "take": person.get("voice_take", 0),
            "description": (person.get("designed_from") if kept else None) or person.get("voice_description") or automatic,
            "gender": person.get("gender", "unknown"), **({"teller": person.get("teller", "author")} if narrator else {})}


def _fits(person: dict, same: dict, narrator: bool) -> bool:
    """Whether a voice still suits them: the book may say later (its AI reading, a review) that this
    one is a woman where the other book's was a man, or that a character tells this book."""
    genders = {person.get("gender", "unknown"), same.get("gender", "unknown")} - {"unknown"}
    return len(genders) < 2 and (not narrator or person.get("teller", "author") == same.get("teller", "author"))


def follow(book: dict) -> bool:
    """Voices from the author's other books follow them there (a new description or take, a review
    of that book), unless kept by hand here; one that no longer suits the person here is let go.
    Returns whether anything changed (the book then needs casting)."""
    if not book.get("carry"):
        return False
    changed = False
    for who, person in [("narrator", book.get("narrator") or {})] + [(c["id"], c) for c in book["characters"]]:
        where = person.get("voice_from")
        if not where or person.get("locked"):
            continue
        source = _source(where["book"], where["character"])
        same = _voice_of(source, who == "narrator") if source else person.get("voice_same")
        if not same:
            continue
        if not _fits(person, same, who == "narrator"):
            person.pop("voice_same", None)
            person.pop("voice_from", None)
            person["carry_checked"] = False  # it may suit someone in another of the books
            changed = True
        elif same != person.get("voice_same"):
            person["voice_same"] = same
            changed = True
    return changed


def carry_over(book: dict) -> None:
    """Characters the author's other books already have get the same voice here, so a trilogy sounds
    the same all through: matched by name, the book opened most recently first. Each person is matched
    once, and not at all in books from before this (no "carry" in them) or in which they were given a
    voice of their own; after that their voice follows the other book's (see follow)."""
    if not book.get("carry") or not _author(book):
        return
    follow(book)
    todo = [c for c in book["characters"] if not c.get("carry_checked")]
    narrator = book.get("narrator") or {}
    if not todo and narrator.get("carry_checked"):
        return
    others = []
    for s in store.list_books():
        if s["id"] != book["id"] and _author(s) == _author(book):
            try:
                others.append(store.load(s["id"]))
            except KeyError:
                pass
    others.sort(key=lambda b: -max(b.get("opened", 0), b.get("created", 0)))
    taken = {f"{c['voice_from']['book']}/{c['voice_from']['character']}" for c in book["characters"] if c.get("voice_from")}
    own = set(book.get("own_voices", []))

    def give(person: dict, other: dict, source: dict, narrator: bool) -> bool:
        same = _voice_of(source, narrator)
        if not _fits(person, same, narrator) or _from(same, book["id"], other, source):
            return False
        person["voice_same"] = same
        person["voice_from"] = {"book": other["id"], "title": other["title"], "character": "narrator" if narrator else source["id"]}
        return True

    for c in sorted(todo, key=lambda c: -c.get("lines", 0)):
        c["carry_checked"] = True
        if c["id"] in own or c.get("voice_description") or c.get("locked"):
            continue
        for other in others:
            match = max(((_same_person(c, o), o.get("lines", 0), o) for o in other.get("characters", [])
                         if f"{other['id']}/{o['id']}" not in taken), key=lambda m: m[:2], default=(0, 0, None))
            if match[0] and give(c, other, match[2], narrator=False):
                taken.add(f"{other['id']}/{match[2]['id']}")
                break
    if not narrator.get("carry_checked"):
        narrator["carry_checked"] = True
        if "narrator" not in own and not narrator.get("voice_description") and not narrator.get("locked"):
            for other in others:
                if (other.get("narrator") or {}).get("voice") and give(narrator, other, other["narrator"], narrator=True):
                    break
        book["narrator"] = narrator


def _from(same: dict, book_id: str, other: dict, source: dict) -> bool:
    """Whether the source's voice comes, by way of other books, from this one (Re-cast of an older
    book whose people another book took): taking it back would go round in a circle."""
    seen, where = 0, source.get("voice_from")
    while where and seen < 5:
        if where["book"] == book_id:
            return True
        nxt = _source(where["book"], where["character"])
        where, seen = (nxt or {}).get("voice_from"), seen + 1
    return False


def own_voice(book: dict, who: str) -> None:
    """The narrator or this character gets a voice of their own here, not the one from the author's
    other book; it isn't carried over again."""
    person = book["narrator"] if who == "narrator" else next((c for c in book["characters"] if c["id"] == who), None)
    if person and (person.pop("voice_same", None) is not None) | (person.pop("voice_from", None) is not None):
        book["own_voices"] = sorted(set(book.get("own_voices", [])) | {who})


def cast_book(book: dict) -> None:
    """Give everyone in the book a voice (see cast), the same as in the author's other books where they're in them."""
    carry_over(book)
    book["narrator"], book["characters"] = cast(book["characters"], book["narrator"])
