"""Character profiles from a small language model running offline on this Mac.

The free analyzer guesses gender and age from words near a name, which goes wrong in long novels
(Dune's Chani came out a man, Alia an old man). This reads, for each character, the passages
that mention them and some of their lines, and asks a local model (via MLX) who they are and
how they should sound. It changes only the voice profile, never who says which line.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from . import designed, store

ACCENTS = ["", "american", "british", "scottish", "irish", "australian", "indian", "south_african",
           "french", "german", "italian", "spanish"]
MAX_CHARACTERS = 40  # the main cast; minor characters keep the free analyzer's guess
MAX_PASSAGES = 28
MAX_LINES = 8
DARK_WORDS = re.compile(r"\b(warm|soft|husky|rich|low|breathy|muffled|whisper\w*|hushed|quiet|quietly)\b,?\s*", re.I)


@dataclass(frozen=True)
class Model:
    name: str
    label: str
    repo: str
    revision: str
    files: dict[str, tuple[int, str]]  # file -> (bytes, sha256)
    install: dict = field(default_factory=lambda: {"state": "idle", "progress": 0.0, "message": ""})

    @property
    def download_bytes(self) -> int:
        return sum(size for size, _ in self.files.values())


# Qwen3-4B-Instruct (4-bit MLX). On Dune's 22 main characters it got every gender and 21 ages
# right (the free analyzer: 17 and 12), at about 2.7 s per character on an M5. Apache 2.0.
MODEL = Model(
    name="qwen3-4b", label="Qwen3-4B", repo="mlx-community/Qwen3-4B-Instruct-2507-4bit",
    revision="50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b",
    files={
        "added_tokens.json": (707, "c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680"),
        "chat_template.jinja": (4040, "40c21f34cf67d8c760ef72f8ad3ae5afad514299d4b06e91dd9a8d705af7b541"),
        "config.json": (938, "574349e5a343236546fda55e4744a76e181f534182d7dc60ff1bad7e7a502849"),
        "generation_config.json": (238, "835fffe355c9438e7a25be099b3fccaa98350b83451f9fd2d99512e74f1ade48"),
        "merges.txt": (1671853, "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
        "model.safetensors": (2263022417, "2a73c6c248601ab904e035548abd8e6abb65ea27dcb5f342fb0a8910eb44173f"),
        "model.safetensors.index.json": (63964, "388d811b8b7c2608dd04cce1bcb04a8bf715d19b42790894e6d3427ff429a777"),
        "special_tokens_map.json": (613, "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd"),
        "tokenizer.json": (11422654, "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
        "tokenizer_config.json": (5440, "4397cc477eb6d79715ccd2000accd6b3531928f30029665832fa1b255f24d2b9"),
        "vocab.json": (2776833, "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
    },
)


def model_dir(m: Model = MODEL) -> Path:
    return store.DATA_DIR / "models" / "llm" / m.name


def installed(m: Model = MODEL) -> bool:
    return designed.supported() and all((model_dir(m) / f).exists() for f in m.files)


def status() -> dict:
    return {"supported": designed.supported(), "installed": installed(), "bytes": MODEL.download_bytes, "label": MODEL.label}


def install(progress: Callable[[str], None]) -> None:
    """Download the model (or link it from an earlier Hugging Face download), checking every file."""
    m, total, done = MODEL, MODEL.download_bytes, 0
    model_dir(m).mkdir(parents=True, exist_ok=True)
    status_ = {"progress": 0.0, "message": ""}
    for name, (size, sha) in m.files.items():
        target = model_dir(m) / name
        if not target.exists():
            source = designed._hf_cache_copy(m.repo, m.revision, name, size, sha)
            if source and source.stat().st_dev == target.parent.stat().st_dev:
                os.link(source, target)
            elif source:
                shutil.copy(source, target)
            else:
                stop = threading.Event()

                def report():
                    while not stop.wait(1.0):
                        progress(f"Downloading the AI model ({MODEL.label})… {int(100 * status_['progress'])}%")

                threading.Thread(target=report, daemon=True).start()
                try:
                    designed._fetch(status_, f"{designed.HF}/{m.repo}/resolve/{m.revision}/{name}", target, size, sha, done, total)
                finally:
                    stop.set()
        done += size
        status_["progress"] = done / total


def apply(book: dict, results: dict[str, dict]) -> int:
    """Put the model's profiles on the book's characters and re-cast them. Returns how many changed."""
    from . import voices

    changed = 0
    for c in book["characters"]:
        p = results.get(c["id"])
        if not p:
            continue
        # Always the latest reading (e.g. with speakers corrected): a changed description gets a new
        # voice. Voices the user kept (pinned) stay, and so do descriptions they wrote themselves.
        for k in ("gender", "age", "accent", "pitch", "pace", "sound", "manner"):
            c[k] = p[k]
        c["not_person"] = not p["is_person"]
        c["other_names"] = p.get("other_names", [])
        bits = [p["age"] if p["age"] != "adult" else "", p["gender"] if p["gender"] != "unknown" else "",
                p["accent"].replace("_", " "), p["sound"]]
        c["summary"] = ", ".join(b for b in bits if b) + (f"; speaks {p['manner']}" if p["manner"] else "")
        c["profiled_by"] = "local-ai"
        changed += 1
    book["narrator"], book["characters"] = voices.cast(book["characters"], book["narrator"])
    return changed


# ------------------------------------------------------------------ evidence


def _names(char: dict) -> list[str]:
    """The character's name and the aliases that look like names (not "The old woman")."""
    names = [char["name"]] + [a for a in char.get("aliases", []) if not a.lower().startswith(("the ", "a "))]
    return [n for n in dict.fromkeys(names) if len(n) > 2 and n.lower() not in ("she", "he", "her", "him")]


def evidence(book: dict, char: dict) -> tuple[list[str], list[str]]:
    """(passages that mention the character, lines they speak), spread across the whole book."""
    names = _names(char) or [char["name"]]
    name_re = re.compile(r"\b(?:%s)\b" % "|".join(re.escape(n) for n in sorted(names, key=len, reverse=True)))
    passages: list[str] = []
    lines: list[str] = []
    for ch in book["chapters"]:
        narration = " ".join(s["text"] for s in ch["segments"] if s["kind"] == "narration")
        sentences = re.split(r"(?<=[.!?…])\s+", narration)
        for i, sent in enumerate(sentences):
            if name_re.search(sent) and 20 < len(sent) < 500:
                follow = sentences[i + 1] if i + 1 < len(sentences) else ""
                # "He/She ..." right after a mention is usually about them too, and tells the gender.
                if re.match(r"\s*(He|She|His|Her)\b", follow) and len(follow) < 300:
                    sent = f"{sent} {follow}"
                passages.append(sent)
        for s in ch["segments"]:
            if s["kind"] == "dialogue" and s.get("speaker") == char["id"] and len(s["text"]) > 25:
                lines.append(s["text"])
    return _spread(passages, MAX_PASSAGES), _spread(lines, MAX_LINES)


def _spread(items: list[str], n: int) -> list[str]:
    """The first few (where characters are introduced) plus an even sample of the rest."""
    if len(items) <= n:
        return items
    head = items[: n // 3]
    rest = items[n // 3:]
    step = len(rest) / (n - len(head))
    return head + [rest[int(i * step)] for i in range(n - len(head))]


def _real_names(names: list[str], passages: list[str], char: dict) -> list[str]:
    """Other names the model gave that the book really uses near this character (no inventions,
    no pronouns or bare words like "the woman" that would match anyone)."""
    from .heuristic import PRONOUNS, PERSON_WORDS

    text = " ".join(passages)
    out = []
    for name in names:
        name = name.strip(" \"'.,")
        bare = re.sub(r"^(the|a|an)\s+", "", name, flags=re.I)
        if (len(bare) < 3 or bare.lower() in PRONOUNS or bare.lower() in PERSON_WORDS
                or name.lower() == char["name"].lower() or not re.search(r"\b%s\b" % re.escape(bare), text, re.I)):
            continue
        out.append(name[0].upper() + name[1:])
    return list(dict.fromkeys(out))


def _book_mentions_accent(accent: str, texts: list[str]) -> bool:
    from .heuristic import ACCENT_WORDS

    text = " ".join(texts).lower()
    return any(re.search(r"\b%s\b" % re.escape(w), text) for w in ACCENT_WORDS.get(accent, [accent]))


# ------------------------------------------------------------------- prompt

PROMPT = """You are casting an audiobook. Below is what the novel says about one character, and some of their lines. Decide who they are and how their voice should sound.

Character: {name}{aliases}

Passages that mention them:
{passages}

Lines they speak:
{lines}

Reply with JSON only, no other text:
{{"is_person": true or false, "gender": "male" | "female" | "unknown", "age": "child" | "young" | "adult" | "old", "accent": {accents}, "pitch": "low" | "medium" | "high", "pace": "slow" | "normal" | "fast", "sound": "<2 or 3 words>", "manner": "<a few words>", "other_names": ["<name or title>", ...]}}

- "is_person" is false if this "character" is really a group, an object, or a mistake (e.g. "The table", "Fremen").
- Age: "child" under 13, "young" 13-29, "adult" 30-59, "old" 60 and over.
- Accent: only if the passages say where the character is from or how they speak (e.g. "his Scottish brogue"). Otherwise "". Never assume British.
- "sound": how this character's voice itself sounds, in 2 or 3 words of your own (for instance "gravelly, commanding", "bright, quick", "thin, nervous", "booming, jovial"). Do not use warm, soft, husky, rich, low, quiet, breathy or whisper.
- "other_names": other names or titles the passages use for this same person (e.g. "the Reverend Mother", "the Duke", a surname), exactly as written in the book; [] if none.
- "manner": how this character speaks, at most 8 words of your own (for instance "with clipped military precision", "in excited bursts", "with weary patience", "with sly amusement"). Describe this character specifically; don't just reuse these examples."""


def build_prompt(char: dict, passages: list[str], lines: list[str]) -> str:
    aliases = [a for a in _names(char) if a != char["name"]]
    return PROMPT.format(
        name=char["name"], aliases=f" (also called {', '.join(aliases)})" if aliases else "",
        passages="\n".join(f"- {p}" for p in passages) or "- (none found)",
        lines="\n".join(f'- "{l}"' for l in lines) or "- (none)",
        accents=" | ".join(f'"{a}"' for a in ACCENTS))


def parse(reply: str) -> dict | None:
    """The model's JSON answer, checked and tidied; None if it isn't usable."""
    m = re.search(r"\{.*\}", reply, re.S)
    if not m:
        return None
    try:
        data = json.loads(m.group(0))
    except json.JSONDecodeError:
        return None
    out = {
        "is_person": bool(data.get("is_person", True)),
        "gender": data.get("gender") if data.get("gender") in ("male", "female", "unknown") else "unknown",
        "age": data.get("age") if data.get("age") in ("child", "young", "adult", "old") else "adult",
        "accent": data.get("accent") if data.get("accent") in ACCENTS else "",
        "pitch": {"low": -1, "medium": 0, "high": 1}.get(data.get("pitch"), 0),
        "pace": {"slow": -1, "normal": 0, "fast": 1}.get(data.get("pace"), 0),
        "sound": _tidy(data.get("sound", ""), 4),
        "other_names": [str(n).strip() for n in data.get("other_names", []) if isinstance(n, str)][:6]
                       if isinstance(data.get("other_names"), list) else [],
        "manner": _tidy(data.get("manner", ""), 9),
    }
    out["manner"] = re.sub(r"^(speaking|speaks|talking)\s+", "", out["manner"], flags=re.I)
    if out["manner"] and not re.match(r"(with|in|like|as if|quickly|slowly)\b", out["manner"]):
        out["manner"] = f"with {out['manner']}"  # reads as "speaking with calm authority"
    return out


def _tidy(text, max_words: int) -> str:
    """Words safe to put in a voice description: no darkening words, no accent, no "voice".

    A phrase containing a darkening word is dropped whole; cutting just the word out of
    "with sharp, quiet transitions" leaves "with sharp then transitions".
    """
    text = ", ".join(part for part in str(text).split(",") if not DARK_WORDS.search(part))
    text = re.sub(r"\b(\w+ accent|[\w-]*accent\w*|voice|voiced|tone|masculine|feminine)\b", "", text, flags=re.I)
    text = re.sub(r"\s*,\s*(,\s*)+", ", ", re.sub(r"\s{2,}", " ", text)).strip(" ,.;")
    return " ".join(text.split()[:max_words]).strip(" ,.;").lower()


# ------------------------------------------------------------------ running


_loaded: dict[str, tuple] = {}


def _load(path: Path) -> tuple:
    from mlx_lm import load

    key = str(path)
    if key not in _loaded:
        _loaded.clear()
        _loaded[key] = load(key)
    return _loaded[key]


def ask(path: Path, prompt: str, max_tokens: int = 220) -> str:
    """One answer from the model at `path` (greedy, so the same book gives the same cast)."""
    from mlx_lm import generate
    from mlx_lm.sample_utils import make_sampler

    model, tokenizer = _load(path)
    messages = [{"role": "user", "content": prompt}]
    try:
        text = tokenizer.apply_chat_template(messages, add_generation_prompt=True, tokenize=False, enable_thinking=False)
    except TypeError:
        text = tokenizer.apply_chat_template(messages, add_generation_prompt=True, tokenize=False)
    return generate(model, tokenizer, prompt=text, max_tokens=max_tokens, sampler=make_sampler(temp=0.0), verbose=False)


def unload() -> None:
    import mlx.core as mx

    _loaded.clear()
    mx.clear_cache()


def profile_book(book: dict, path: Path, progress: Callable[[str], None] = lambda _: None,
                 cancelled: Callable[[], bool] = lambda: False) -> dict[str, dict]:
    """{character id: profile} for the main cast. Runs on the designed-voices worker thread."""
    cast = sorted(book["characters"], key=lambda c: -c.get("lines", 0))[:MAX_CHARACTERS]
    results: dict[str, dict] = {}
    for i, char in enumerate(cast, 1):
        if cancelled():
            break
        progress(f"Reading about {char['name']} ({i} of {len(cast)})…")
        passages, lines = evidence(book, char)
        reply = designed._submit(designed.BACKGROUND, ask, path, build_prompt(char, passages, lines)).result()
        profile = parse(reply)
        if profile and profile["accent"] and not _book_mentions_accent(profile["accent"], passages + lines):
            profile["accent"] = ""  # small models like to invent accents; keep only ones the book names
        if profile:
            profile["other_names"] = _real_names(profile["other_names"], passages, char)
        if profile:
            results[char["id"]] = profile
    designed._submit(designed.BACKGROUND, unload).result()
    return results



# ------------------------------------------------------------- who says what
#
# The free analyzer only knows who speaks a quote when a speech tag names them ("said Paul");
# otherwise it assumes speakers take turns, which fails when one person speaks twice in a row.
# Here the model reads a scene with every quote numbered and says who speaks each.

WINDOW_QUOTES = 24  # quotes per request
CONTEXT_PARAS = 6  # paragraphs before them, so the model knows who's in the scene

SPEAKER_PROMPT = """You are preparing an audiobook of a novel. In the passage below, each quotation is marked with an id like [Q12]. Decide who speaks each marked quotation.

Characters (use these ids exactly):
{cast}

Earlier in the scene (for context; already attributed):
{context}

Passage:
{passage}

How to decide:
- A speech tag ("said Paul", "she asked") names the speaker; "she"/"he" means the woman/man just mentioned.
- The narration may call a character by a title or description that isn't in the list ("the Reverend Mother", "the Duke", "the boy"). Work out from the scene which listed character that is, and use their id.
- A character whose action is described in the same paragraph as a quotation ("Paul nodded.", "Jessica turned to him.") is usually the one speaking it.
- A name inside a quotation is usually the person being spoken TO ("You do not drool, Baron" is said to the Baron, not by him).
- In a back-and-forth, speakers usually alternate, but one person often speaks several times in a row when the other only acts or stays silent.
- Use "unknown" only if it truly cannot be determined.
Reply with JSON only, mapping every marked id to a character id, like {{"Q12": "paul", "Q13": "jessica"}}."""


def paragraphs(chapter: dict) -> list[dict]:
    """The chapter as paragraphs: {"para", "parts": [("n", text) | ("q", q, text)]} in reading order."""
    out: dict[int, dict] = {}
    for seg in chapter["segments"]:
        p = out.setdefault(seg["para"], {"para": seg["para"], "parts": []})
        if seg["kind"] == "dialogue":
            if p["parts"] and p["parts"][-1][0] == "q" and p["parts"][-1][1] == seg["q"]:
                p["parts"][-1] = ("q", seg["q"], p["parts"][-1][2] + " " + seg["text"])
            else:
                p["parts"].append(("q", seg["q"], seg["text"]))
        else:
            p["parts"].append(("n", seg["text"]))
    return [out[k] for k in sorted(out)]


def _render(para: dict, marked: bool, speakers: dict[int, str], names: dict[str, str], hide_tags: bool = False) -> str:
    from .heuristic import TAG_AFTER, TAG_BEFORE

    bits = []
    for part in para["parts"]:
        if part[0] == "n":
            text = part[1]
            if hide_tags:  # testing: take the speech tag away, keep the rest of the narration
                text = TAG_BEFORE.sub("", TAG_AFTER.sub("", text))
            if text.strip(" ,.;:"):
                bits.append(text.strip())
        elif marked:
            bits.append(f"[Q{part[1]}] “{part[2]}”")
        else:
            who = names.get(speakers.get(part[1], ""), "")
            bits.append(f"{who + ': ' if who else ''}“{part[2]}”")
    return " ".join(bits)


def cast_list(book: dict, limit: int = 45) -> tuple[str, dict[str, str]]:
    cast = [c for c in sorted(book["characters"], key=lambda c: -c.get("lines", 0)) if not c.get("not_person")][:limit]
    lines, names = [], {}
    for c in cast:
        aka = list(dict.fromkeys(c.get("other_names", []) + [a for a in c.get("aliases", []) if a != c["name"]]))[:4]
        lines.append(f'- {c["id"]}: {c["name"]}' + (f' (also: {", ".join(aka)})' if aka else ""))
        names[c["id"]] = c["name"]
    return "\n".join(lines), names


def attribute_chapter(chapter: dict, cast_text: str, names: dict[str, str], ask_fn,
                      hide: set[int] = frozenset()) -> dict[int, str]:
    """{quote number: character id} for every quote in the chapter. `hide`: paragraphs shown without
    their speech tags (used to test the model on quotes whose tag has been taken away)."""
    paras = paragraphs(chapter)
    speakers: dict[int, str] = {}
    i = 0
    while i < len(paras):
        j, count = i, 0
        while j < len(paras) and count < WINDOW_QUOTES:
            count += sum(1 for p in paras[j]["parts"] if p[0] == "q")
            j += 1
        if count:
            context = "\n".join(_render(p, False, speakers, names) for p in paras[max(0, i - CONTEXT_PARAS):i]) or "(start of chapter)"
            passage = "\n".join(_render(p, True, speakers, names, p["para"] in hide) for p in paras[i:j])
            reply = ask_fn(SPEAKER_PROMPT.format(cast=cast_text, context=context, passage=passage),
                           max_tokens=16 * count + 40)
            m = re.search(r"\{.*\}", reply, re.S)
            try:
                got = json.loads(m.group(0)) if m else {}
            except json.JSONDecodeError:
                got = {}
            for key, who in got.items():
                if isinstance(key, str) and key.upper().startswith("Q") and key[1:].isdigit() and who in names:
                    speakers[int(key[1:])] = who
        i = j
    return speakers


def quotes_to_decide(chapter: dict) -> set[int]:
    """Quotes whose speaker isn't named by a tag: no tag at all, or only "she said" / "he asked".

    Rules work out "she" as the woman named last, which goes wrong when she's named differently
    ("the Reverend Mother" for "the old woman"); with characters' other names the AI does better.
    Tags that name the speaker ("said Paul", "the old man said") are left to the rules.
    """
    from .heuristic import TAG_AFTER, TAG_BEFORE, TAG_NOMINAL

    out = set()
    for p in paragraphs(chapter):
        narration = " ".join(x[1] for x in p["parts"] if x[0] == "n")
        if not any(rx.search(narration) for rx in (TAG_AFTER, TAG_BEFORE, TAG_NOMINAL)):
            out |= {x[1] for x in p["parts"] if x[0] == "q"}
    return out


def one_speaker_per_paragraph(chapter: dict, got: dict[int, str], todo: set[int], cast: list[dict]) -> dict[int, str]:
    """A new speaker starts a new paragraph. When the model splits a paragraph's quotes between
    people but the narration around them names nobody else, they're all the first quote's speaker
    (usually the one with the "he said"). A paragraph that names a second character may really
    have two speakers ("Idaho mumbled. Jessica looked down…"), so it's left alone."""
    names = {}
    for c in cast:
        for n in [c["name"], *c.get("aliases", []), *c.get("other_names", [])]:
            if len(n) > 2 and n.lower() not in ("she", "he"):
                names[n] = c["id"]
    name_re = re.compile(r"\b(%s)\b" % "|".join(re.escape(n) for n in sorted(names, key=len, reverse=True))) if names else None
    fixed = dict(got)
    for p in paragraphs(chapter):
        qs = [x[1] for x in p["parts"] if x[0] == "q" and x[1] in todo]
        said = [fixed.get(q) for q in qs if fixed.get(q)]
        if len(qs) < 2 or len(set(said)) < 2:
            continue
        first = said[0]
        narration = " ".join(x[1] for x in p["parts"] if x[0] == "n")
        mentioned = {names[m.group(1)] for m in name_re.finditer(narration)} if name_re else set()
        if not (mentioned - {first}):
            for q in qs:
                fixed[q] = first
    return fixed


def find_speakers(book_id: str, progress: Callable[[str], None] = lambda _: None) -> int:
    """Decide who speaks every untagged quote in the book, chapter by chapter. Returns lines changed.

    Lines whose tag names the speaker keep the free analyzer's answer (it's right on those), and
    lines you assigned by hand are never touched. Each request waits its turn behind lines being
    read aloud. On two hand-labelled Dune chapters: 96% of all lines right (rules alone: 89%).
    """
    import copy

    book = store.load(book_id)
    cast_text, names = cast_list(book)
    path = model_dir()
    ask_queued = lambda prompt, max_tokens: designed._submit(designed.BACKGROUND, ask, path, prompt, max_tokens).result()
    changed = 0
    chapters = [i for i, ch in enumerate(book["chapters"]) if any(s["kind"] == "dialogue" for s in ch["segments"])]
    for n, ci in enumerate(chapters, 1):
        progress(f"Working out who speaks… chapter {n} of {len(chapters)}")
        chapter = copy.deepcopy(store.load(book_id)["chapters"][ci])
        todo = quotes_to_decide(chapter)
        if not todo:
            continue
        got = attribute_chapter(chapter, cast_text, names, ask_queued)
        got = one_speaker_per_paragraph(chapter, got, todo, book["characters"])
        with store.lock(book_id):
            book = store.load(book_id)
            for seg in book["chapters"][ci]["segments"]:
                who = got.get(seg.get("q"))
                if seg["kind"] == "dialogue" and seg["q"] in todo and who and not seg.get("by_hand") and seg.get("speaker") != who:
                    seg["speaker"] = who
                    changed += 1
            store.recount_lines(book)
            store.save(book)
    designed._submit(designed.BACKGROUND, unload).result()
    return changed
