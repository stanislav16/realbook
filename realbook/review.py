"""Have a stronger AI (e.g. Claude in a chat) check a book's speakers and characters.

Export: a ZIP of Markdown parts, each with instructions, the cast, and chapters in which every quote
is marked with its id and current speaker: {12:34 paul}“…”. A whole novel doesn't fit in one chat
message, so long books are split into parts that can each be reviewed on their own.

Import: the AI replies with a JSON block of corrections only. RealBook checks every id against
the book, applies what's valid, and protects corrected lines like lines set by hand.
"""

from __future__ import annotations

import io
import json
import re
import zipfile

from . import local_analyzer, store, voices

PART_WORDS = 70_000  # about 100k tokens with markup: fits a chat with room for the reply
ACCENTS = local_analyzer.ACCENTS


INSTRUCTIONS = """You are checking an audiobook script made by RealBook, an app that reads books aloud with a different voice for each character. A small offline model and some rules already decided who speaks each quotation; please correct their mistakes.

How the text is marked: every quotation starts with a tag like {{12:34 paul}}. "12:34" is the quotation's id (chapter 12, quote 34) and "paul" is the character id currently speaking it ("?" means unknown, so the narrator reads it). Several pieces of one quotation share an id.

What to check:
1. Speakers. For every quotation, is the current speaker right? Use speech tags, who is addressed, the flow of the conversation, and your knowledge of the book. Watch for: a name inside a quotation usually being the person spoken TO; one person speaking several times in a row; characters called by a title ("the Reverend Mother", "the Duke").
2. Characters. Are gender, age group and accent right? Is anyone listed twice (merge them)? Is a character's name a vague description ("The old woman") when the book gives a better one ("Reverend Mother")? Are there "characters" that aren't people (merge them into the right person, or set their lines to "?")?
3. Voices. For each main character, how does their voice sound? Give "sound": 2-3 words about the voice itself, from the book where it says (e.g. "sweet, musical tenor", "gravelly"), not about their personality or behaviour. Voices are read naturally; lines the book says are whispered, shouted or pleaded are read that way automatically, so don't describe acting. Avoid the words warm, soft, husky, rich, low, quiet, breathy and whisper (they make the voices muffled).
4. Pronunciation. A text-to-speech voice guesses at unusual words and may say them differently each time. This covers every unusual word in the book, not only characters: places and planets, families and houses, organisations, invented words and titles. For words it could get wrong, give a respelling that an English reader would say correctly: one word spelled with ordinary letters, no hyphens, capitals for stress or phonetic symbols. When the name sounds like a real English word, use that word: voices say real words the same way every time, but can still guess at a made-up spelling, above all a short one on its own (e.g. "Piter": "Peter", "Feyd": "Fade", "Atreides": "Atraydeez", "Gesserit": "Guesserit"). Give a hyphenated name its own entry if its parts are respelled differently ("Feyd-Rautha": "Fayd-Rawthuh"). Leave out words that are pronounced the way they look.
5. Narrator. Who tells the book: "author" (the author speaks to the reader in their own voice: non-fiction, a memoir), "character" (a character tells the story as "I") or "storyteller" (an unnamed voice tells a story about other people)? For an author or a character, are they a man or a woman? The narrator's voice follows this; it is listed under "Narrator" below the characters.
6. Time jumps. Does the story jump forward in time so far that a main character would sound different afterwards: a child grown into a teenager or an adult, a teenager into a grown man or woman, an adult grown old? Give "later" for them: the chapter they first appear older in (the number in the line ids, e.g. 40 for {{40:…}}), their age group then and their age in years if the book says or implies it. Don't list ageing of a year or two, or characters already listed with that later voice.

Reply with ONE JSON code block and nothing else needed. Include ONLY changes. Format:

```json
{{
  "realbook_review": 1,
  "book": "{book_id}",
  "speakers": {{"12:34": "jessica", "12:35": "?"}},
  "characters": {{
    "the-old-woman": {{"name": "Reverend Mother", "gender": "female", "age": "old", "accent": "", "pitch": "medium", "pace": "slow", "sound": "dry, cracked"}}
  }},
  "new_characters": {{
    "duncan": {{"name": "Duncan Idaho", "gender": "male", "age": "adult", "accent": "", "pitch": "medium", "pace": "normal", "sound": "bright, easy"}}
  }},
  "merge": {{"paul-s-mother": "jessica"}},
  "pronunciations": {{"Piter": "Peter"}},
  "narrator": {{"teller": "author", "gender": "male"}},
  "later": {{"mara": [{{"from": 12, "age": "adult", "years": 34}}]}}
}}
```

Rules for the reply:
- Speaker values must be a character id from the list, an id you add under "new_characters", or "?".
- "characters" entries may contain any of: name, gender (male/female/unknown), age (child = under 13, young = 13-29, adult = 30-59, old = 60+), accent (one of: {accents}; "" if the book gives none), pitch (low/medium/high), pace (slow/normal/fast), sound.
- "merge" maps a duplicate's id to the id of the same person; its lines move there.
- "pronunciations" maps a word as written in the book (a name, place, group or invented word) to how to say it.
- "later" maps a character id to a list of later voices: from (a chapter number), age (child/young/adult/old) and years (a number, if known).
- "narrator" has teller (author/character/storyteller) and gender (male/female/unknown); include it only if the listed narrator is wrong.
- Leave out everything that is already right. If nothing needs changing, reply with "speakers": {{}}.
"""


def _cast_table(book: dict) -> str:
    rows = ["| id | name | also called | lines | gender | age | accent | sound | manner | later voices |", "|---|---|---|---|---|---|---|---|---|---|"]
    for c in sorted(book["characters"], key=lambda c: -c.get("lines", 0)):
        aka = ", ".join(dict.fromkeys([*c.get("other_names", []), *c.get("aliases", [])]))[:80]
        later = "; ".join(f"from {st['from']}: {st['age']}" + (f", {st['years']}" if st.get("years") else "") for st in c.get("later", []))
        rows.append(f"| {c['id']} | {c['name']} | {aka} | {c.get('lines', 0)} | {c.get('gender', '')} | {c.get('age', '')} | "
                    f"{c.get('accent', '')} | {c.get('sound', '')} | {c.get('manner', '')} | {later} |")
    return "\n".join(rows)


def _narrator_line(book: dict) -> str:
    n = book.get("narrator") or {}
    teller = n.get("teller") or local_analyzer.teller_of(book)
    return f"teller: {teller}, gender: {n.get('gender', 'unknown')}"


def _chapter_text(book: dict, ci: int) -> str:
    ch = book["chapters"][ci]
    who = {s["q"]: s.get("speaker") or "?" for s in ch["segments"] if s["kind"] == "dialogue"}
    out = [f"## {ch['title']} (line ids {ci}:…)"]
    for p in local_analyzer.paragraphs(ch):
        bits = []
        for part in p["parts"]:
            bits.append(part[1] if part[0] == "n" else f"{{{ci}:{part[1]} {who.get(part[1], '?')}}}“{part[2]}”")
        out.append(" ".join(bits))
    return "\n\n".join(out)


def parts(book: dict) -> list[tuple[str, str]]:
    """[(file name, Markdown)] — the book split into parts small enough for one chat each."""
    chapters = [i for i, ch in enumerate(book["chapters"]) if any(s["kind"] == "dialogue" for s in ch["segments"])]
    groups, current, words = [], [], 0
    for ci in chapters:
        n = sum(len(s["text"].split()) for s in book["chapters"][ci]["segments"])
        if current and words + n > PART_WORDS:
            groups.append(current)
            current, words = [], 0
        current.append(ci)
        words += n
    if current:
        groups.append(current)
    instructions = INSTRUCTIONS.format(book_id=book["id"], accents=", ".join(f'"{a}"' for a in ACCENTS))
    out = []
    for k, group in enumerate(groups, 1):
        head = (f"# {book['title']}: RealBook review, part {k} of {len(groups)} (chapters {group[0]}–{group[-1]})\n\n"
                f"{instructions}\n## Characters\n\n{_cast_table(book)}\n\n## Narrator\n\n{_narrator_line(book)}\n\n# The text\n\n")
        out.append((f"Part {k} of {len(groups)}.md", head + "\n\n".join(_chapter_text(book, ci) for ci in group)))
    return out


GUIDE = """How to use this review package
==============================

1. Open a strong AI chat, for example Claude (claude.ai).
2. Attach "Part 1 of N.md" (drag it into the chat) and send it. The file contains its own
   instructions, so you don't need to type anything; you can add "Please review this."
3. The AI replies with a block of JSON corrections. Copy the whole reply.
4. In RealBook: Cast panel → ••• → Import AI Review… → paste → Import.
5. Repeat for each part (a new chat per part works best).

Corrected lines are protected like lines you fix by hand: later runs of the local AI won't change them.
"""


def zip_bytes(book: dict) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("How to use.txt", GUIDE)
        for name, text in parts(book):
            z.writestr(name, text)
    return buf.getvalue()


# ------------------------------------------------------------------ import


def _parse(text: str) -> dict:
    """The JSON object in an AI reply (inside a ```json block, or bare)."""
    m = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.S) or re.search(r"(\{.*\})", text, re.S)
    if not m:
        raise ValueError("No JSON found in the reply. Paste the AI's whole answer, including the ```json block.")
    try:
        data = json.loads(m.group(1))
    except json.JSONDecodeError as e:
        raise ValueError(f"The reply's JSON is incomplete or malformed ({e.msg}). Ask the AI to send it again.")
    if not isinstance(data, dict):
        raise ValueError("The reply isn't a RealBook review.")
    return data


def _profile(raw: dict) -> dict:
    """Validated character fields from the reply."""
    out = {}
    if isinstance(raw.get("name"), str) and raw["name"].strip():
        out["name"] = " ".join(raw["name"].split())[:80]
    if raw.get("gender") in ("male", "female", "unknown"):
        out["gender"] = raw["gender"]
    if raw.get("age") in ("child", "young", "adult", "old"):
        out["age"] = raw["age"]
    if raw.get("accent") in ACCENTS:
        out["accent"] = raw["accent"]
    if raw.get("pitch") in ("low", "medium", "high"):
        out["pitch"] = {"low": -1, "medium": 0, "high": 1}[raw["pitch"]]
    if raw.get("pace") in ("slow", "normal", "fast"):
        out["pace"] = {"slow": -1, "normal": 0, "fast": 1}[raw["pace"]]
    for k, words in (("sound", 4), ("manner", 9)):
        if isinstance(raw.get(k), str):
            out[k] = local_analyzer._tidy(raw[k], words)
    if out.get("manner") and not re.match(r"(with|in|like|as if|\w+ly)\b", out["manner"]):
        out["manner"] = f"with {out['manner']}"
    return out


def apply(book: dict, text: str) -> dict:
    """Apply a pasted review to `book` (in place). Returns counts, and anything skipped."""
    data = _parse(text)
    if data.get("book") and data["book"] != book["id"]:
        raise ValueError("This review is for a different book.")
    skipped: list[str] = []
    ids = {c["id"] for c in book["characters"]}

    new = data.get("new_characters") or {}
    added = 0
    for cid, raw in (new.items() if isinstance(new, dict) else []):
        cid = re.sub(r"[^a-z0-9-]+", "-", str(cid).lower()).strip("-")
        if not cid or cid in ids or not isinstance(raw, dict):
            continue
        prof = _profile(raw)
        book["characters"].append({"id": cid, "name": prof.pop("name", cid.replace("-", " ").title()), "aliases": [],
                                   "gender": "unknown", "age": "adult", "accent": "", "pitch": 0, "pace": 0,
                                   "summary": "added by AI review", "evidence": [], "lines": 0, **prof,
                                   "profiled_by": "review"})
        ids.add(cid)
        added += 1

    profiles = 0
    for cid, raw in (data.get("characters") or {}).items():
        c = next((x for x in book["characters"] if x["id"] == cid), None)
        if c is None or not isinstance(raw, dict):
            skipped.append(f"unknown character {cid}")
            continue
        prof = _profile(raw)
        if "name" in prof and prof["name"] != c["name"]:
            c["aliases"] = list(dict.fromkeys([*c.get("aliases", []), c["name"]]))
        c.update(prof)
        c["profiled_by"] = "review"
        profiles += 1

    speakers = 0
    where = {}
    for ci, ch in enumerate(book["chapters"]):
        for seg in ch["segments"]:
            if seg["kind"] == "dialogue":
                where.setdefault(f"{ci}:{seg['q']}", []).append(seg)
    for key, who in (data.get("speakers") or {}).items():
        segs = where.get(str(key).strip())
        target = None if who in ("?", None, "") else who
        if not segs or (target is not None and target not in ids):
            skipped.append(f"line {key} → {who}")
            continue
        for seg in segs:
            if seg.get("speaker") != target:
                seg["speaker"] = target
            seg["by_hand"] = True  # reviewed: later local-AI runs leave it alone
        speakers += 1

    merged = 0
    for src, dst in (data.get("merge") or {}).items():
        if src == dst or src not in ids or dst not in ids:
            skipped.append(f"merge {src} → {dst}")
            continue
        gone = next(c for c in book["characters"] if c["id"] == src)
        target = next(c for c in book["characters"] if c["id"] == dst)
        for ch in book["chapters"]:
            for seg in ch["segments"]:
                if seg.get("speaker") == src:
                    seg["speaker"] = dst
        target["aliases"] = list(dict.fromkeys([*target.get("aliases", []), gone["name"], *gone.get("aliases", [])]))
        book["characters"] = [c for c in book["characters"] if c["id"] != src]
        ids.discard(src)
        merged += 1

    said = store.clean_pronunciations(data.get("pronunciations") if isinstance(data.get("pronunciations"), dict) else {})
    if said:
        book["pronunciations"] = {**book.get("pronunciations", {}), **said}

    told = data.get("narrator") if isinstance(data.get("narrator"), dict) else {}
    narrator = 0
    if told.get("teller") in ("author", "character", "storyteller"):
        gender = told.get("gender") if told.get("gender") in ("male", "female") and told["teller"] != "storyteller" else "unknown"
        local_analyzer.set_teller(book, {"teller": told["teller"], "gender": gender}, "review")
        narrator = 1

    older = 0
    for cid, stages in (data.get("later") or {}).items():
        c = next((x for x in book["characters"] if x["id"] == cid), None)
        if c is None or not isinstance(stages, list):
            skipped.append(f"later voice of {cid}")
            continue
        for raw in stages:
            start = raw.get("from") if isinstance(raw, dict) else None
            years = raw.get("years") if isinstance(raw, dict) and isinstance(raw.get("years"), int) and 0 < raw["years"] <= 120 else None
            if not isinstance(start, int) or not 0 < start < len(book["chapters"]) or raw.get("age") not in voices.AGES:
                skipped.append(f"later voice of {cid}")
                continue
            ch = book["chapters"][start]
            kept = next((st for st in c.get("later", []) if st["from"] == start), {})
            stage = {**kept, "id": f"{cid}@{start}", "name": c["name"], "from": start, "age": raw["age"], "by": "review",
                     "chapter": " · ".join(x for x in (ch.get("section"), ch["title"]) if x)}
            stage.pop("years", None)
            if years:
                stage["years"] = years
            c["later"] = sorted([st for st in c.get("later", []) if st["from"] != start] + [stage], key=lambda st: st["from"])
            older += 1

    store.recount_lines(book)
    voices.cast_book(book)
    import time

    book.setdefault("ai_done", {})["review"] = time.time()
    return {"speakers": speakers, "characters": profiles, "added": added, "merged": merged, "said": len(said), "narrator": narrator, "later": older, "skipped": skipped[:20],
            "skipped_count": len(skipped)}
