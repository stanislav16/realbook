"""One line of a book as audio: what its voice says and how, wherever the line is asked for."""

from __future__ import annotations

from pathlib import Path

from . import heuristic, store, tts


def _spec(book: dict, segments: list[dict], seg: dict, styles: dict | None) -> tuple:
    v = store.voice_for(book, seg)
    if styles is None:
        styles = heuristic.line_styles(segments)
    style = styles.get(seg["q"], "") if seg["kind"] == "dialogue" and seg.get("speaker") else ""
    return (store.audio_dir(book["id"]), store.spoken(book, heuristic.as_said(segments, seg)), v["voice"], v["rate"], v.get("pitch_shift", 0)), {
        "style": style, "take": seg.get("take", 0)}


def path(book: dict, segments: list[dict], seg: dict, styles: dict | None = None) -> Path:
    """Where the line's audio is, or will be once it's made."""
    args, kw = _spec(book, segments, seg, styles)
    return tts.audio_path(*args, **kw)


def make(book: dict, segments: list[dict], seg: dict, urgent: bool = True, styles: dict | None = None) -> Path:
    """The line's audio, made now if it hasn't been yet."""
    args, kw = _spec(book, segments, seg, styles)
    return tts.synthesize(*args, urgent=urgent, **kw)


def can_group(book: dict, segments: list[dict], seg: dict, styles: dict | None = None) -> str | None:
    """The voice this line can be made together with others in, if it can."""
    args, kw = _spec(book, segments, seg, styles)
    return args[2] if tts.can_group(args[2], kw["style"]) else None


def make_many(book: dict, group: list[tuple[list[dict], dict]]) -> None:
    """Lines in the same voice, each (its chapter's segments, the line), made together."""
    specs = [_spec(book, segs, seg, None) for segs, seg in group]
    cache_dir, _, voice, rate, pitch_shift = specs[0][0]
    tts.synthesize_many(cache_dir, voice, rate, pitch_shift, [(args[1], kw["take"]) for args, kw in specs])
