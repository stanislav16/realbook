"""Words a book makes by joining two English words ("wormsign", "stillsuit", "glowglobe").

Designed voices guess at a word they don't know and may say it differently each time; split into
its two words ("worm sign") it's said the same way every time. A word counts as English when the
reading model has it as a word of its own (its vocabulary) or the system's word list has it.
"""

from __future__ import annotations

import json
import re
from collections import Counter
from pathlib import Path

from . import designed

SYSTEM_WORDS = Path("/usr/share/dict/words")  # macOS; designed voices are Mac-only
ENDINGS = ("s", "es", "ed", "d", "ing", "er", "ers", "est", "ly", "ness", "ment", "ments", "ies", "ied", "ier", "iest", "ily",
           "able", "ful", "less")
# Parts that make ordinary English words rather than invented ones ("overcame", "workmen", "buglike"),
# and short words that split a word wrongly ("drumsand" isn't "drums and").
NOT_FIRST = {"over", "under", "out", "down", "up", "non", "pre", "counter", "fore", "with", "semi", "hyper", "anti", "self",
             "after", "for", "off", "mis", "sub", "super", "inter", "trans", "multi"}
NOT_LAST = {"men", "man", "like", "ness", "and", "the", "her", "his", "him", "its", "our", "you", "are", "was", "who", "one", "ever"}
MIN_USES = 2  # a word used once is often a typo ("eventhe")

_words: set[str] | None = None


def _english() -> set[str]:
    global _words
    if _words is None:
        words: set[str] = set()
        vocab = designed.model_dir(designed.QWEN) / designed.QWEN.read_role / "vocab.json"
        try:
            words |= {t[1:] for t in json.loads(vocab.read_text()) if t.startswith("Ġ") and t[1:].isalpha() and t[1:].islower()}
        except (OSError, ValueError):
            pass
        try:
            words |= {w.strip().lower() for w in SYSTEM_WORDS.read_text().split() if w.isalpha()}
        except OSError:
            pass
        _words = words
    return _words


def available() -> bool:
    return bool(_english())


def _known(w: str) -> bool:
    words = _english()
    if w in words:
        return True
    for e in ENDINGS:
        stem = w[: -len(e)]
        if w.endswith(e) and len(stem) >= 3:
            if (stem in words or stem + "e" in words or (e[0] == "i" and stem + "y" in words)
                    or (len(stem) > 3 and stem[-1] == stem[-2] and stem[:-1] in words)  # "dropped"
                    or (stem.endswith("ck") and stem[:-1] in words)):  # "mimicking"
                return True
    return False


def find(book: dict) -> dict[str, str]:
    """{joined word: its two words}, for the joined words this book uses in lower case."""
    if not available():
        return {}
    counts: Counter[str] = Counter()
    lower: set[str] = set()
    for ch in book["chapters"]:
        for s in ch["segments"]:
            for w in re.findall(r"[A-Za-z]+(?:['’][A-Za-z]+)?", s["text"]):
                counts[w.lower()] += 1
                if w.islower():
                    lower.add(w)
    out = {}
    for w in sorted(lower):
        if len(w) < 6 or counts[w] < MIN_USES or "'" in w or "’" in w or _known(w):
            continue
        splits = [(counts[w[:i]] * counts[w[i:]], w[:i], w[i:]) for i in range(3, len(w) - 2)
                  if w[:i] not in NOT_FIRST and w[i:] not in NOT_LAST
                  and _known(w[:i]) and _known(w[i:]) and counts[w[:i]] and counts[w[i:]]]
        if splits:
            _, a, b = max(splits)
            out[w] = f"{a} {b}"
    # "stillsuits" is said like "stillsuit" with an s anyway (store.spoken)
    return {w: s for w, s in out.items() if not (w.endswith("s") and w[:-1] in out)}


def add_to(book: dict) -> int:
    """Adds the book's joined words to its pronunciations, keeping any set already. Returns how many."""
    if not available():
        return 0
    say = book.setdefault("pronunciations", {})
    have = {w.lower() for w in say}
    found = {w: s for w, s in find(book).items() if w not in have}
    say.update(found)
    book["compounds_checked"] = 1
    return len(found)
