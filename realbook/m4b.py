"""Chapters and tags for an .m4b audiobook made by afconvert.

afconvert writes the audio but no chapters. This adds them twice: as a QuickTime chapter track
(what Apple Books and most iPhone players read) and as a Nero `chpl` list (what many Android and
Windows players read), plus title, author and cover tags.

The new `moov` box goes at the end of the file and the old one becomes `free` space, so the
audio's chunk offsets stay valid without rewriting them.
"""

from __future__ import annotations

import struct
from pathlib import Path

CONTAINERS = {b"moov", b"trak", b"mdia", b"minf", b"stbl", b"udta", b"edts", b"dinf"}


def box(kind: bytes, *payload: bytes) -> bytes:
    body = b"".join(payload)
    return struct.pack(">I4s", 8 + len(body), kind) + body


def full(kind: bytes, version: int, flags: int, *payload: bytes) -> bytes:
    return box(kind, struct.pack(">I", (version << 24) | flags), *payload)


def _children(data: bytes) -> list[tuple[bytes, bytes]]:
    """[(kind, whole box)] for the boxes directly inside `data`."""
    out, off = [], 0
    while off + 8 <= len(data):
        size, kind = struct.unpack(">I4s", data[off:off + 8])
        if size == 1:
            size = struct.unpack(">Q", data[off + 8:off + 16])[0]
        elif size == 0:
            size = len(data) - off
        out.append((kind, data[off:off + size]))
        off += size
    return out


def _top_level(path: Path) -> list[tuple[bytes, int, int]]:
    """[(kind, offset, size)] of the file's top-level boxes, without reading the audio."""
    out = []
    with open(path, "rb") as f:
        f.seek(0, 2)
        end, off = f.tell(), 0
        while off + 8 <= end:
            f.seek(off)
            size, kind = struct.unpack(">I4s", f.read(8))
            if size == 1:
                size = struct.unpack(">Q", f.read(8))[0]
            elif size == 0:
                size = end - off
            out.append((kind, off, size))
            off += size
    return out


IDENTITY = struct.pack(">9I", 0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000)


def _chapter_trak(track_id: int, movie_timescale: int, chapters: list[tuple[int, str]], total_ms: int,
                  offsets: list[int], sizes: list[int]) -> bytes:
    durations = [b - a for (a, _), (b, _) in zip(chapters, chapters[1:] + [(total_ms, "")])]
    co64 = offsets[-1] > 0xFFFFFFFF
    tkhd = full(b"tkhd", 0, 0, struct.pack(">IIIII", 0, 0, track_id, 0, total_ms * movie_timescale // 1000),
                bytes(8), struct.pack(">hhhh", 0, 0, 0, 0), IDENTITY, struct.pack(">II", 0, 0))
    mdhd = full(b"mdhd", 0, 0, struct.pack(">IIII", 0, 0, 1000, total_ms), struct.pack(">HH", 0x55C4, 0))
    hdlr = full(b"hdlr", 0, 0, struct.pack(">I4s", 0, b"text"), bytes(12), b"Chapters\0")
    gmin = full(b"gmin", 0, 0, struct.pack(">HHHHhH", 0x40, 0x8000, 0x8000, 0x8000, 0, 0))
    gmhd = box(b"gmhd", gmin, box(b"text", IDENTITY))
    dinf = box(b"dinf", full(b"dref", 0, 0, struct.pack(">I", 1), full(b"url ", 0, 1)))
    text_entry = box(b"text", bytes(6), struct.pack(">H", 1),  # data reference 1
                     struct.pack(">II", 0, 0), bytes(6), bytes(8), bytes(8),  # display, justify, colours, box
                     struct.pack(">HHBH", 0, 0, 0, 0), bytes(6), b"\0")  # font, face, reserved, colour, name
    stbl = box(
        b"stbl",
        full(b"stsd", 0, 0, struct.pack(">I", 1), text_entry),
        full(b"stts", 0, 0, struct.pack(">I", len(durations)), *(struct.pack(">II", 1, max(1, d)) for d in durations)),
        full(b"stsc", 0, 0, struct.pack(">IIII", 1, 1, 1, 1)),
        full(b"stsz", 0, 0, struct.pack(">II", 0, len(sizes)), *(struct.pack(">I", s) for s in sizes)),
        full(b"co64", 0, 0, struct.pack(">I", len(offsets)), *(struct.pack(">Q", o) for o in offsets)) if co64 else
        full(b"stco", 0, 0, struct.pack(">I", len(offsets)), *(struct.pack(">I", o) for o in offsets)),
    )
    return box(b"trak", tkhd, box(b"mdia", mdhd, hdlr, box(b"minf", gmhd, dinf, stbl)))


def _text(kind: bytes, value: str) -> bytes:
    return box(kind, full(b"data", 0, 1, bytes(4), value.encode()))


def _tags(title: str, author: str, cover: tuple[bytes, str] | None) -> list[bytes]:
    items = [_text(b"\xa9nam", title), _text(b"\xa9alb", title), _text(b"\xa9gen", "Audiobook")]
    if author:
        items += [_text(b"\xa9ART", author), _text(b"aART", author)]
    if cover:
        kind = 14 if cover[1] == "png" else 13
        items.append(box(b"covr", full(b"data", 0, kind, bytes(4), cover[0])))
    return items


def _with_tags(udta: bytes, tags: list[bytes], chpl: bytes) -> bytes:
    """udta with our tags merged into its meta/ilst (afconvert puts an encoder tag there)."""
    parts = []
    found_meta = False
    for kind, b in _children(udta[8:]):
        if kind == b"meta":
            found_meta = True
            inner = b[12:]  # meta is a full box
            kids = []
            have_ilst = False
            for k, c in _children(inner):
                if k == b"ilst":
                    have_ilst = True
                    ours = {t[4:8] for t in tags}
                    kept = [x for kk, x in _children(c[8:]) if kk not in ours]
                    c = box(b"ilst", *kept, *tags)
                kids.append(c)
            if not have_ilst:
                kids.append(box(b"ilst", *tags))
            b = full(b"meta", 0, 0, *kids)
        if kind != b"chpl":
            parts.append(b)
    if not found_meta:
        hdlr = full(b"hdlr", 0, 0, struct.pack(">I4s", 0, b"mdir"), b"appl", bytes(8), b"\0")
        parts.append(full(b"meta", 0, 0, hdlr, box(b"ilst", *tags)))
    return box(b"udta", *parts, chpl)


def add_chapters(path: Path, chapters: list[tuple[int, str]], title: str, author: str,
                 cover: tuple[bytes, str] | None = None) -> None:
    """Add chapters ([(start in ms, title)], first at 0) and tags to the .m4b at `path`."""
    top = _top_level(path)
    moov_kind, moov_off, moov_size = next(t for t in top if t[0] == b"moov")
    with open(path, "rb") as f:
        f.seek(moov_off)
        moov = f.read(moov_size)

    kids = _children(moov[8:])
    mvhd = next(b for k, b in kids if k == b"mvhd")
    version = mvhd[8]
    if version == 1:
        timescale, duration = struct.unpack(">IQ", mvhd[28:40])
    else:
        timescale, duration = struct.unpack(">II", mvhd[20:28])
    total_ms = duration * 1000 // timescale
    audio_traks = [b for k, b in kids if k == b"trak"]
    chapter_id = len(audio_traks) + 1

    # Chapter titles are the samples of the text track, in a new mdat at the end of the file.
    samples = [struct.pack(">H", len(t.encode())) + t.encode() + box(b"encd", struct.pack(">I", 0x100))
               for _, t in chapters]
    end = top[-1][1] + top[-1][2]
    mdat_header = 16  # 64-bit size header, in case the samples land past 4 GB
    offsets, at = [], end + mdat_header
    for s in samples:
        offsets.append(at)
        at += len(s)
    mdat = struct.pack(">I4sQ", 1, b"mdat", mdat_header + sum(map(len, samples))) + b"".join(samples)

    chpl = full(b"chpl", 1, 0, bytes(4), struct.pack(">B", len(chapters)), *(
        struct.pack(">QB", start * 10_000, len(t.encode()[:255])) + t.encode()[:255] for start, t in chapters))

    new_kids = []
    for kind, b in kids:
        if kind == b"mvhd":
            # next_track_ID is the last 4 bytes of mvhd
            b = b[:-4] + struct.pack(">I", chapter_id + 1)
        elif kind == b"trak":
            parts = []
            for k, c in _children(b[8:]):
                if k != b"tref":
                    parts.append(c)
                if k == b"tkhd":  # the audio track points at its chapter track
                    parts.append(box(b"tref", box(b"chap", struct.pack(">I", chapter_id))))
            b = box(b"trak", *parts)
        elif kind == b"udta":
            continue
        new_kids.append(b)
    udta = next((b for k, b in kids if k == b"udta"), box(b"udta"))
    new_kids.append(_chapter_trak(chapter_id, timescale, chapters, total_ms, offsets, [len(s) for s in samples]))
    new_kids.append(_with_tags(udta, _tags(title, author, cover), chpl))
    new_moov = box(b"moov", *new_kids)

    with open(path, "r+b") as f:
        f.seek(moov_off + 4)
        f.write(b"free")  # the old moov's space is left as padding
        f.seek(end)
        f.write(mdat)
        f.write(new_moov)
