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


def _ends_quote(p: str, j: int, style: str) -> bool:
    # A “ inside a “…” quote is a closing mark printed the wrong way round ("‘namely?’ “asked the
    # bird"): double quotes don't nest, so the quote ends there instead of swallowing the narration.
    return _is_close(p, j, style) or (style == "double" and p[j] == "“")


def quote_spans(p: str, style: str) -> tuple[list[tuple[int, int]], bool]:
    """Return [(start, end)] spans including the marks, and whether the last quote was left open."""
    spans: list[tuple[int, int]] = []
    i, n = 0, len(p)
    left_open = False
    while i < n:
        if _is_open(p, i, style):
            j = i + 1
            while j < n and not _ends_quote(p, j, style):
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


# A quote left open at the end of a paragraph usually goes on in the next one, which opens with
# another “. A poem or song is often printed as one quote over many lines instead: “ on the first
# line, ” on the last, nothing between (Jessica's recital in Dune). When a ” comes within this many
# paragraphs, before any “, the lines between belong to the quote.
MAX_UNMARKED_LINES = 30


def _first_mark(p: str, style: str) -> str | None:
    """"open" or "close": the paragraph's first quotation mark, if it has any."""
    for i in range(len(p)):
        if _is_open(p, i, style):
            return "open"
        if _is_close(p, i, style):
            return "close"
    return None


def _unmarked_until(paragraphs: list[str], i: int, style: str) -> int | None:
    """The paragraph whose ” closes a quote left open in paragraph `i`, when every one between has no marks."""
    if style != "double":  # with ‘…’, apostrophes look like closing marks
        return None
    for j in range(i + 1, min(i + 1 + MAX_UNMARKED_LINES, len(paragraphs))):
        mark = _first_mark(paragraphs[j], style)
        if mark:
            return j if mark == "close" else None
    return None


def segment_chapter(text: str, style: str) -> list[dict]:
    paragraphs = [p.strip() for p in re.split(r"\n\s*\n", text) if p.strip()]
    if len(paragraphs) == 1 and "\n" in paragraphs[0]:
        # Some text files use single newlines between paragraphs.
        paragraphs = [p.strip() for p in paragraphs[0].split("\n") if p.strip()]
    paragraphs = [" ".join(raw.split()) for raw in paragraphs]

    segments: list[dict] = []
    q = 0
    prev_open = False
    carry_q, carry_until = None, -1  # a quote going on through unmarked lines, and where it closes
    for para_idx, p in enumerate(paragraphs):
        # (kind, text, cont, quote id when it continues an earlier one)
        pieces: list[tuple[str, str, bool, int | None]] = []
        if carry_q is not None and para_idx < carry_until:
            pieces.append(("dialogue", p, True, carry_q))
            p = ""
        elif carry_q is not None:
            close = next(i for i in range(len(p)) if _is_close(p, i, style))
            pieces.append(("dialogue", p[:close], True, carry_q))
            p = p[close + 1:]
            prev_open, carry_q = False, None
        spans, left_open = quote_spans(p, style)
        cursor = 0
        first_quote = True
        for start, end in spans:
            pieces.append(("narration", p[cursor:start], False, None))
            inner = p[start + 1 : end - 1] if end - start >= 2 and _ends_quote(p, end - 1, style) else p[start + 1 : end]
            pieces.append(("dialogue", inner, prev_open and first_quote, None))
            first_quote = False
            cursor = end
        pieces.append(("narration", p[cursor:], False, None))

        for kind, chunk_text, cont, same_q in pieces:
            chunk_text = chunk_text.strip()
            if not _speakable(chunk_text):
                continue
            quote_id = None
            if same_q is not None:
                quote_id = same_q
            elif kind == "dialogue":
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
        if carry_q is None and left_open and spans:
            until = _unmarked_until(paragraphs, para_idx, style)
            if until is not None:
                carry_q, carry_until = q - 1, until
        if carry_q is None:
            prev_open = left_open
    return segments
