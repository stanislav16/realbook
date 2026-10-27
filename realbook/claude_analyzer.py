"""Character analysis with Claude (optional; needs ANTHROPIC_API_KEY).

Pass 1 reads the whole book and builds the cast with a voice profile for each character.
Pass 2 goes chapter by chapter and attributes every numbered quote to a cast member.
"""

from __future__ import annotations

import json
import os
from collections import defaultdict
from typing import Callable

import anthropic

from . import store

MODEL = "claude-opus-5-5"
MAX_BOOK_CHARS = 2_500_000

ACCENTS = ["", "american", "british", "scottish", "irish", "australian", "indian", "south_african",
           "french", "german", "italian", "spanish"]

CAST_SCHEMA = {
    "type": "object",
    "properties": {
        "characters": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "id": {"type": "string", "description": "short lowercase slug, e.g. 'mara'"},
                    "name": {"type": "string"},
                    "aliases": {"type": "array", "items": {"type": "string"}},
                    "gender": {"type": "string", "enum": ["male", "female", "unknown"]},
                    "age": {"type": "string", "enum": ["child", "young", "adult", "old"]},
                    "accent": {"type": "string", "enum": ACCENTS},
                    "pitch": {"type": "string", "enum": ["low", "medium", "high"]},
                    "pace": {"type": "string", "enum": ["slow", "normal", "fast"]},
                    "summary": {"type": "string", "description": "one sentence describing how this character should sound"},
                    "evidence": {"type": "array", "items": {"type": "string"}, "description": "up to 3 short quotes from the book that describe the character"},
                },
                "required": ["id", "name", "aliases", "gender", "age", "accent", "pitch", "pace", "summary", "evidence"],
                "additionalProperties": False,
            },
        }
    },
    "required": ["characters"],
    "additionalProperties": False,
}

ATTRIBUTION_SCHEMA = {
    "type": "object",
    "properties": {
        "attributions": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"q": {"type": "integer"}, "speaker": {"type": "string"}},
                "required": ["q", "speaker"],
                "additionalProperties": False,
            },
        }
    },
    "required": ["attributions"],
    "additionalProperties": False,
}

CAST_PROMPT = """You are casting an audiobook. Read the book below and list every character who speaks at least one line of dialogue.

For each one, infer how they should sound from what the book says about them: gender, age group, accent or nationality (only if the book indicates one; otherwise ""), how high or low their voice is, and how fast they talk. Use explicit descriptions where they exist ("a gravelly voice", "the old fisherman", "her Glasgow accent") and reasonable inference otherwise. Merge different names for the same person (e.g. "Mrs. Quinn" and "Ellen" if they are the same woman) into one entry with aliases. Do not include the narrator unless the narrator is also a character who speaks in quotes."""

ATTRIBUTION_PROMPT = """You are preparing an audiobook script. Each quotation in the chapter below is marked with an id like [Q12]. Decide who speaks each quotation.

Cast (use these ids exactly):
{cast}

Use "unknown" only when the speaker genuinely cannot be determined. Quotes that are not spoken aloud (signs, letters, thoughts in quotes) still go to whoever wrote or thought them if known. Return an attribution for every id."""


class ClaudeUnavailable(RuntimeError):
    pass


def key_source() -> str | None:
    """Where Claude credentials come from: the environment, the in-app setting, or nowhere."""
    if os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("ANTHROPIC_AUTH_TOKEN"):
        return "env"
    if store.settings().get("anthropic_api_key"):
        return "settings"
    return None


def available() -> bool:
    return key_source() is not None


def _ask(client: anthropic.Anthropic, system: str, user: str, schema: dict) -> dict:
    with client.beta.messages.stream(
        model=MODEL,
        max_tokens=64000,
        system=system,
        messages=[{"role": "user", "content": user}],
        output_config={"effort": "medium", "format": {"type": "json_schema", "schema": schema}},
        betas=["server-side-fallback-2026-07-01"],
        fallbacks="default",
    ) as stream:
        message = stream.get_final_message()
    if message.stop_reason == "refusal":
        raise ClaudeUnavailable("Claude declined to analyse this text")
    if message.stop_reason == "max_tokens":
        raise ClaudeUnavailable("Claude's answer was cut off; the chapter may be too long")
    text = next((b.text for b in message.content if b.type == "text"), "")
    return json.loads(text)


def _chapter_text(chapter: dict, mark_quotes: bool) -> str:
    paras: dict[int, list[str]] = defaultdict(list)
    last_q = None
    for seg in chapter["segments"]:
        out = paras[seg["para"]]
        if seg["kind"] == "dialogue" and seg["q"] == last_q and out:
            out[-1] = f'{out[-1][:-1]} {seg["text"]}”'  # long quote split into several segments
        elif seg["kind"] == "dialogue":
            tag = f'[Q{seg["q"]}] ' if mark_quotes else ""
            out.append(f'{tag}“{seg["text"]}”')
        else:
            out.append(seg["text"])
        last_q = seg["q"] if seg["kind"] == "dialogue" else None
    return "\n\n".join(" ".join(p) for _, p in sorted(paras.items()))


def analyze(chapters: list[dict], progress: Callable[[str], None] = lambda _: None) -> dict:
    """Same contract as heuristic.analyze: fills seg["speaker"] and returns {"characters"}."""
    if not available():
        raise ClaudeUnavailable("Add an Anthropic API key in Settings to use Claude")
    if key_source() == "settings":
        client = anthropic.Anthropic(api_key=store.settings()["anthropic_api_key"])
    else:
        client = anthropic.Anthropic()

    book = "\n\n".join(f"## {ch['title']}\n\n{_chapter_text(ch, False)}" for ch in chapters)
    if len(book) > MAX_BOOK_CHARS:
        raise ClaudeUnavailable("This book is too long to analyse in one pass")

    progress("Reading the whole book to find the characters…")
    cast = _ask(client, CAST_PROMPT, f"<book>\n{book}\n</book>", CAST_SCHEMA)["characters"]
    ids = {c["id"] for c in cast}
    cast_lines = "\n".join(f'- {c["id"]}: {c["name"]} ({", ".join(c["aliases"]) or "no aliases"}) — {c["summary"]}' for c in cast)
    system = ATTRIBUTION_PROMPT.format(cast=cast_lines)

    lines: dict[str, int] = defaultdict(int)
    for i, ch in enumerate(chapters):
        if not any(s["kind"] == "dialogue" for s in ch["segments"]):
            continue
        progress(f"Working out who speaks in chapter {i + 1} of {len(chapters)}…")
        result = _ask(client, system, f"<chapter>\n{_chapter_text(ch, True)}\n</chapter>", ATTRIBUTION_SCHEMA)
        by_q = {a["q"]: a["speaker"] for a in result["attributions"] if a["speaker"] in ids}
        for seg in ch["segments"]:
            if seg["kind"] == "dialogue":
                seg["speaker"] = by_q.get(seg["q"])
        for q, speaker in by_q.items():
            lines[speaker] += 1

    pitch = {"low": -1, "medium": 0, "high": 1}
    pace = {"slow": -1, "normal": 0, "fast": 1}
    characters = [
        {**c, "pitch": pitch[c["pitch"]], "pace": pace[c["pace"]], "lines": lines.get(c["id"], 0)}
        for c in cast
    ]
    characters.sort(key=lambda c: -c["lines"])
    return {"characters": [c for c in characters if c["lines"] > 0]}
