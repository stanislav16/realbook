"""Split chapter text into narration and dialogue segments.

A segment is the unit that gets spoken by one voice and highlighted in the reader:
    {"id", "kind": "narration"|"dialogue", "text", "para", "q", "cont", "speaker"}
`q` numbers each quotation within the chapter (dialogue only), and `cont` marks a
quote that continues one left open at the end of the previous paragraph.
"""

from __future__ import annotations

import re

from .abbrev import ENDS_WITH_ABBREVIATION

MAX_SEGMENT_CHARS = 320
SENTENCE_END = re.compile(r"(?<=[.!?…])[\"”’']?\s+(?=[\"“‘'(]?[A-Z0-9])")
DASHES = " \t([—–-"


def detect_quote_style(text: str) -> str:
    """'double' for “…”/"…" dialogue, 'single' for British-style ‘…’."""
    doubles = text.count("“") + len(re.findall(r'(^|\s)"', text))
    singles = text.count("‘") + len(re.findall(r"(^|\s)'(?=[A-Z])", text))
    return "single" if singles > doubles * 2 and singles > 5 else "double"


def _is_open(p: str, i: int, style: str) -> bool:
    c = p[i]
    if style == "double":
        return c == "“" or (c == '"' and (i == 0 or p[i - 1] in DASHES))
    return c == "‘" or (c == "'" and (i == 0 or p[i - 1] in DASHES))


def _is_close(p: str, j: int, style: str) -> bool:
    c = p[j]
    if style == "double":
        return c in "”\""
    if c not in "’'":
        return False
    nxt = p[j + 1] if j + 1 < len(p) else " "
    return not nxt.isalpha()


def quote_spans(p: str, style: str) -> tuple[list[tuple[int, int]], bool]:
    """Return [(start, end)] spans including the marks, and whether the last quote was left open."""
    spans: list[tuple[int, int]] = []
    i, n = 0, len(p)
    left_open = False
    while i < n:
        if _is_open(p, i, style):
            j = i + 1
            while j < n and not _is_close(p, j, style):
                j += 1
            if j >= n:
                left_open = True
            spans.append((i, min(j + 1, n)))
            i = j + 1
        else:
            i += 1
    return spans, left_open


def _chunks(text: str) -> list[str]:
    """Split long text at sentence boundaries into speakable chunks."""
    text = " ".join(text.split())
    if len(text) <= MAX_SEGMENT_CHARS:
        return [text]
    # Rejoin "sentences" that only ended at an abbreviation: "Dr." | "Raman said…"
    sentences: list[str] = []
    for piece in SENTENCE_END.split(text):
        if sentences and ENDS_WITH_ABBREVIATION.search(sentences[-1]):
            sentences[-1] += " " + piece
        else:
            sentences.append(piece)
    out: list[str] = []
    buf = ""
    for sent in sentences:
        if buf and len(buf) + len(sent) + 1 > MAX_SEGMENT_CHARS:
            out.append(buf)
            buf = sent
        else:
            buf = f"{buf} {sent}".strip()
    if buf:
        out.append(buf)
    return out


def _speakable(s: str) -> bool:
    return any(ch.isalnum() for ch in s)


def segment_chapter(text: str, style: str) -> list[dict]:
    paragraphs = [p.strip() for p in re.split(r"\n\s*\n", text) if p.strip()]
    if len(paragraphs) == 1 and "\n" in paragraphs[0]:
        # Some text files use single newlines between paragraphs.
        paragraphs = [p.strip() for p in paragraphs[0].split("\n") if p.strip()]

    segments: list[dict] = []
    q = 0
    prev_open = False
    for para_idx, raw in enumerate(paragraphs):
        p = " ".join(raw.split())
        spans, left_open = quote_spans(p, style)
        cursor = 0
        first_quote = True
        pieces: list[tuple[str, str, bool]] = []
        for start, end in spans:
            pieces.append(("narration", p[cursor:start], False))
            inner = p[start + 1 : end - 1] if end - start >= 2 and _is_close(p, end - 1, style) else p[start + 1 : end]
            pieces.append(("dialogue", inner, prev_open and first_quote))
            first_quote = False
            cursor = end
        pieces.append(("narration", p[cursor:], False))

        for kind, chunk_text, cont in pieces:
            chunk_text = chunk_text.strip()
            if not _speakable(chunk_text):
                continue
            quote_id = None
            if kind == "dialogue":
                quote_id = q
                q += 1
            for piece in _chunks(chunk_text):
                segments.append(
                    {
                        "id": len(segments),
                        "kind": kind,
                        "text": piece,
                        "para": para_idx,
                        "q": quote_id,
                        "cont": cont,
                        "speaker": None,
                    }
                )
        prev_open = left_open
    return segments
