"""Turn .txt / .epub files into a title, author, cover and a list of (chapter title, chapter text)."""

from __future__ import annotations

import posixpath
import re
import zipfile
from html.parser import HTMLParser
from io import BytesIO
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from xml.etree import ElementTree

CHAPTER_HEADING = re.compile(
    r"^\s*((chapter|book|part)\s+([0-9]+|[ivxlcdm]+|[a-z-]+)\b.*|prologue|epilogue)\s*$",
    re.IGNORECASE,
)
MAX_CHAPTER_CHARS = 120_000  # only split truly huge files (e.g. a book with no chapters)


@dataclass
class ImportedBook:
    title: str
    author: str
    chapters: list[tuple[str, str, str]]  # (title, text, section): section is the part it belongs to, or ""
    cover: tuple[bytes, str] | None = None  # (image bytes, file extension)


def read_book_path(path: Path) -> tuple[str, bytes]:
    """(filename, bytes) for a book on disk. An EPUB kept as a folder, which is how Apple Books
    stores and exports them, is zipped into a normal .epub first."""
    if not path.is_dir():
        return path.name, path.read_bytes()
    if not (path / "META-INF" / "container.xml").exists():
        raise ValueError(f"“{path.name}” is a folder, not a book")
    buf = BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        mimetype = path / "mimetype"
        z.writestr("mimetype", mimetype.read_bytes() if mimetype.exists() else b"application/epub+zip",
                   compress_type=zipfile.ZIP_STORED)
        for f in sorted(path.rglob("*")):
            if f.is_file() and f != mimetype and not f.name.startswith("."):
                z.write(f, f.relative_to(path).as_posix())
    name = path.name if path.name.lower().endswith(".epub") else f"{path.name}.epub"
    return name, buf.getvalue()


def import_book(filename: str, data: bytes) -> ImportedBook:
    name = filename.lower()
    if name.endswith(".epub"):
        return _import_epub(filename, data)
    if name.endswith((".txt", ".md", ".text")):
        title, author, chapters = _import_txt(filename, data)
        return ImportedBook(title, author, [(t, text, "") for t, text in chapters])
    raise ValueError("Unsupported file type. Use .epub or .txt")


# ---------------------------------------------------------------- plain text


def _decode(data: bytes) -> str:
    for enc in ("utf-8-sig", "cp1252", "latin-1"):
        try:
            return data.decode(enc)
        except UnicodeDecodeError:
            continue
    return data.decode("utf-8", errors="replace")


def _import_txt(filename: str, data: bytes) -> tuple[str, str, list[tuple[str, str]]]:
    text = _decode(data).replace("\r\n", "\n").replace("\r", "\n")
    text = _strip_gutenberg(text)
    title = PurePosixPath(filename).stem.replace("_", " ").replace("-", " ").strip().title()
    author = ""

    # A leading "Title\nby Author" block is common in plain-text books.
    top = text.strip().split("\n")
    head = [(i, ln.strip()) for i, ln in enumerate(top[:8]) if ln.strip()]
    if len(head) >= 2 and head[1][1].lower().startswith("by "):
        title, author = head[0][1], head[1][1][3:].strip()
        text = "\n".join(top[head[1][0] + 1:])

    lines = text.split("\n")
    chapters: list[tuple[str, list[str]]] = []
    current_title, current = "Opening", []
    for i, line in enumerate(lines):
        prev_blank = i == 0 or not lines[i - 1].strip()
        if prev_blank and len(line) < 80 and CHAPTER_HEADING.match(line):
            if "".join(current).strip():
                chapters.append((current_title, current))
            current_title, current = line.strip(), []
            continue
        current.append(line)
    if "".join(current).strip():
        chapters.append((current_title, current))

    result: list[tuple[str, str]] = []
    for ch_title, ch_lines in chapters:
        body = "\n".join(ch_lines).strip()
        first, _, rest = body.partition("\n")
        if first and len(first) < 60 and rest.startswith("\n") and not first.endswith((".", '"', "”")):
            ch_title = f"{ch_title}: {first.strip()}" if ch_title != "Opening" else first.strip()
            body = rest.strip()
        result.extend(_split_long(ch_title, body))
    if not result:
        raise ValueError("The file contains no text")
    return title, author, result


def _strip_gutenberg(text: str) -> str:
    start = re.search(r"\*\*\* ?START OF (THE|THIS) PROJECT GUTENBERG.*?\*\*\*", text)
    if start:
        text = text[start.end():]
    end = re.search(r"\*\*\* ?END OF (THE|THIS) PROJECT GUTENBERG", text)
    if end:
        text = text[: end.start()]
    return text


def _split_long(title: str, body: str) -> list[tuple[str, str]]:
    """Split huge chapters (or chapterless books) into readable parts at paragraph breaks."""
    if len(body) <= MAX_CHAPTER_CHARS:
        return [(title, body)]
    paras = re.split(r"\n\s*\n", body)
    parts: list[str] = []
    buf: list[str] = []
    size = 0
    for p in paras:
        if size + len(p) > MAX_CHAPTER_CHARS and buf:
            parts.append("\n\n".join(buf))
            buf, size = [], 0
        buf.append(p)
        size += len(p)
    if buf:
        parts.append("\n\n".join(buf))
    return [(f"{title} (part {i + 1})", part) for i, part in enumerate(parts)]


# ---------------------------------------------------------------------- epub


class _HTMLText(HTMLParser):
    BLOCK = {"p", "div", "br", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "tr", "section"}
    SKIP = {"script", "style", "head", "title"}

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.out: list[str] = []
        self.headings: list[str] = []
        self._skip = 0
        self._in_heading = False
        self._heading_buf: list[str] = []

    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP:
            self._skip += 1
        if tag in self.BLOCK:
            self.out.append("\n\n")
        if tag in {"h1", "h2", "h3"}:
            self._in_heading = True
            self._heading_buf = []

    def handle_endtag(self, tag):
        if tag in self.SKIP and self._skip:
            self._skip -= 1
        if tag in self.BLOCK:
            self.out.append("\n\n")
        if tag in {"h1", "h2", "h3"} and self._in_heading:
            self._in_heading = False
            heading = " ".join("".join(self._heading_buf).split())
            if heading:
                self.headings.append(heading)

    def handle_data(self, data):
        if self._skip:
            return
        if self._in_heading:
            self._heading_buf.append(data)
        self.out.append(data)

    def text(self) -> str:
        raw = "".join(self.out)
        paras = [" ".join(p.split()) for p in re.split(r"\n\s*\n", raw)]
        return "\n\n".join(p for p in paras if p)


def _check_drm(zf: zipfile.ZipFile) -> None:
    """Refuse copy-protected books: their text is encrypted, so we'd read gibberish."""
    names = set(zf.namelist())
    if "META-INF/sinf.xml" in names or "META-INF/rights.xml" in names:
        raise ValueError("This book is copy-protected (DRM), like books bought in the Apple Books store. RealBook can only read DRM-free books.")
    if "META-INF/encryption.xml" in names:
        # Font obfuscation also lives here and is harmless; encrypted chapters are not.
        refs = re.findall(r'URI="([^"]+)"', zf.read("META-INF/encryption.xml").decode("utf-8", "replace"))
        if any(r.lower().split("#")[0].endswith((".html", ".xhtml", ".htm")) for r in refs):
            raise ValueError("This book is copy-protected (DRM), so its text can't be read. RealBook can only read DRM-free books.")


def _import_epub(filename: str, data: bytes) -> ImportedBook:
    zf = zipfile.ZipFile(BytesIO(data))
    _check_drm(zf)
    container = ElementTree.fromstring(zf.read("META-INF/container.xml"))
    ns = {"c": "urn:oasis:names:tc:opendocument:xmlns:container"}
    opf_path = container.find(".//c:rootfile", ns).attrib["full-path"]
    opf = ElementTree.fromstring(zf.read(opf_path))
    opf_dir = posixpath.dirname(opf_path)

    def find_text(tag: str) -> str:
        for el in opf.iter():
            if el.tag.endswith("}" + tag) and (el.text or "").strip():
                return el.text.strip()
        return ""

    def resolve(href: str, base: str = opf_dir) -> str:
        return posixpath.normpath(posixpath.join(base, href.split("#")[0]))

    title = find_text("title") or PurePosixPath(filename).stem
    author = find_text("creator")

    manifest: dict[str, dict] = {}
    for el in opf.iter():
        if el.tag.endswith("}item"):
            manifest[el.attrib.get("id")] = el.attrib
    spine_el = next((el for el in opf.iter() if el.tag.endswith("}spine")), None)
    spine = [el.attrib.get("idref") for el in opf.iter() if el.tag.endswith("}itemref")]
    toc = _epub_toc(zf, manifest, spine_el, resolve)

    chapters: list[tuple[str, str, str]] = []
    # Top-level table-of-contents entries are sections ("Book One - DUNE"). A section whose page
    # is just a title is a part, so the untitled files after it are numbered chapters; otherwise
    # untitled files continue the previous entry.
    section, section_is_part, untitled = "", False, 0
    for idref in spine:
        item = manifest.get(idref, {})
        href, media = item.get("href", ""), item.get("media-type", "")
        if not href or "html" not in media:
            continue
        path = resolve(href)
        try:
            html = zf.read(path).decode("utf-8", errors="replace")
        except KeyError:
            continue
        parser = _HTMLText()
        parser.feed(html)
        body = parser.text()
        entry = toc.get(path)
        short = len(body) < 200  # covers, part title pages
        if entry and entry[1] == 0:
            section, section_is_part, untitled = entry[0], short, 0
        if short or _is_contents_page(body):
            continue
        heading = parser.headings[0] if parser.headings and len(parser.headings[0]) <= 80 else ""
        if entry:
            ch_title = entry[0]
        elif heading:
            ch_title = heading
        elif section and section_is_part:
            untitled += 1
            ch_title = f"Chapter {untitled}"
        elif section:
            ch_title = f"{section} (continued)"
        else:
            untitled += 1
            ch_title = "Front Matter" if untitled == 1 else f"Front Matter ({untitled})"
        for known in (entry[0] if entry else None, heading):
            if known and body.startswith(known):
                body = body[len(known):].strip()
        chapters.extend((t, text, section) for t, text in _split_long(ch_title[:80], body))
    if not chapters:
        raise ValueError("Could not find any readable chapters in this EPUB")
    return ImportedBook(title, author, chapters, _epub_cover(zf, opf, manifest, resolve))


def _is_contents_page(body: str) -> bool:
    """The book's own printed table of contents: a list of titles, not something to read aloud."""
    return body.split("\n", 1)[0].strip().lower() in ("table of contents", "contents")


def _epub_toc(zf, manifest, spine_el, resolve) -> dict[str, tuple[str, int]]:
    """Map each content file to (title, nesting depth) of the first table-of-contents entry
    that points into it. Depth 0 is a top-level entry."""
    entries: dict[str, tuple[str, int]] = {}

    def add(path: str, label: str, depth: int) -> None:
        label = " ".join(label.split())
        if label and path not in entries:
            entries[path] = (label, depth)

    def children(el, name):
        return [c for c in el if c.tag.endswith("}" + name) or c.tag == name]

    # EPUB 3: the navigation document's nested <ol>/<li> lists.
    nav = next((i for i in manifest.values() if "nav" in (i.get("properties") or "").split()), None)
    if nav:
        try:
            nav_path = resolve(nav["href"])
            base = posixpath.dirname(nav_path)
            root = ElementTree.fromstring(zf.read(nav_path))

            def walk_ol(ol, depth):
                for li in children(ol, "li"):
                    a = next((c for c in li.iter() if (c.tag.endswith("}a") or c.tag == "a") and c.attrib.get("href")), None)
                    if a is not None:
                        add(resolve(a.attrib["href"], base), "".join(a.itertext()), depth)
                    for sub in children(li, "ol"):
                        walk_ol(sub, depth + 1)

            for el in root.iter():
                if el.tag.endswith("nav") and "toc" in " ".join(el.attrib.values()):
                    for ol in children(el, "ol"):
                        walk_ol(ol, 0)
        except (KeyError, ElementTree.ParseError):
            pass
    # EPUB 2: the NCX file's nested navPoints.
    ncx_id = spine_el.attrib.get("toc") if spine_el is not None else None
    ncx = manifest.get(ncx_id) if ncx_id else next((i for i in manifest.values() if i.get("media-type") == "application/x-dtbncx+xml"), None)
    if ncx:
        try:
            ncx_path = resolve(ncx["href"])
            base = posixpath.dirname(ncx_path)
            root = ElementTree.fromstring(zf.read(ncx_path))

            def walk_points(node, depth):
                for point in children(node, "navPoint"):
                    label_el = next((c for c in children(point, "navLabel")), None)
                    label = "".join(label_el.itertext()) if label_el is not None else ""
                    content = next(iter(children(point, "content")), None)
                    if content is not None and content.attrib.get("src"):
                        add(resolve(content.attrib["src"], base), label, depth)
                    walk_points(point, depth + 1)

            nav_map = next((el for el in root.iter() if el.tag.endswith("navMap")), None)
            if nav_map is not None:
                walk_points(nav_map, 0)
        except (KeyError, ElementTree.ParseError):
            pass
    return entries


def _epub_cover(zf, opf, manifest, resolve) -> tuple[bytes, str] | None:
    """The cover image, found the EPUB 3 way, the EPUB 2 way, or by name."""
    candidates = [i for i in manifest.values() if "cover-image" in (i.get("properties") or "").split()]
    for el in opf.iter():
        if el.tag.endswith("}meta") and el.attrib.get("name") == "cover" and el.attrib.get("content") in manifest:
            candidates.append(manifest[el.attrib["content"]])
    candidates += [i for i in manifest.values()
                   if i.get("media-type", "").startswith("image/") and "cover" in (i.get("id", "") + i.get("href", "")).lower()]
    for item in candidates:
        if not item.get("media-type", "").startswith("image/"):
            continue
        try:
            data = zf.read(resolve(item["href"]))
        except KeyError:
            continue
        ext = {"image/jpeg": "jpg", "image/png": "png", "image/gif": "gif", "image/webp": "webp"}.get(item["media-type"])
        if ext and len(data) > 1000:
            return data, ext
    return None
