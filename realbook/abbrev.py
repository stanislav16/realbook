"""Abbreviations that end in a period but don't end a sentence ("Dr. Raman", "J. R. R. Tolkien").

Speech engines pause after a period, and the segmenter splits long passages at periods, so both
need to know these aren't sentence ends.
"""

from __future__ import annotations

import re

# Spoken forms. Titles never end a sentence, so they are always expanded.
TITLES = {
    "Mr": "Mister", "Mrs": "Missus", "Ms": "Miz", "Messrs": "Messieurs", "Dr": "Doctor", "Prof": "Professor",
    "Capt": "Captain", "Col": "Colonel", "Gen": "General", "Lt": "Lieutenant", "Sgt": "Sergeant",
    "Cpl": "Corporal", "Maj": "Major", "Adm": "Admiral", "Cmdr": "Commander", "Rev": "Reverend",
    "Fr": "Father", "Hon": "Honourable", "Gov": "Governor", "Sen": "Senator", "Rep": "Representative",
    "Pres": "President", "Supt": "Superintendent", "Insp": "Inspector", "Det": "Detective", "Mt": "Mount",
    "Ft": "Fort", "vs": "versus", "approx": "approximately", "Dept": "Department", "Bros": "Brothers",
}
# Words that may or may not end the sentence: expanded, keeping the period only before a new sentence.
OTHERS = {"etc": "et cetera", "Jr": "Junior", "Sr": "Senior"}

_titles = "|".join(sorted(TITLES, key=len, reverse=True))
_TITLE = re.compile(rf"\b({_titles})\.(?=\s|$)")
_OTHER = re.compile(rf"\b({'|'.join(OTHERS)})\.")
_SAINT = re.compile(r"\bSt\.(?=\s+[A-Z])")
_STREET = re.compile(r"\bSt\.")
_NUMBER = re.compile(r"\bNo\.(?=\s*\d)")
_ACRONYM = re.compile(r"\b(?:[A-Z]\.){2,}")
_INITIAL = re.compile(r"\b([B-HJ-Z])\.(?=\s+[A-Z])")  # "J. Smith"; not "A." or "I.", which are usually words
_EG_IE = [(re.compile(r"\be\.g\.,?", re.I), "for example,"), (re.compile(r"\bi\.e\.,?", re.I), "that is,")]

# A chunk of text that ends in one of these must not be treated as a finished sentence.
ENDS_WITH_ABBREVIATION = re.compile(
    rf"(?:\b(?:{_titles}|St|No|e\.g|i\.e)|\b[B-HJ-Z]|(?:\b[A-Z]\.){{2,}}[A-Z]?)\.[\"”’']?$"
)


def _sentence_follows(text: str, end: int) -> bool:
    rest = text[end:].lstrip()
    return not rest or rest[0].isupper()


def expand(text: str) -> str:
    """Rewrite abbreviations into words so speech engines don't pause after them."""
    for rx, spoken in _EG_IE:
        text = rx.sub(spoken, text)
    text = _SAINT.sub("Saint", text)
    text = _STREET.sub("Street", text)
    text = _NUMBER.sub("Number", text)
    text = _TITLE.sub(lambda m: TITLES[m.group(1)], text)
    text = _OTHER.sub(lambda m: OTHERS[m.group(1)] + ("." if _sentence_follows(text, m.end()) else ""), text)
    text = _ACRONYM.sub(lambda m: " ".join(m.group(0).replace(".", "")), text)  # U.S.A. → "U S A"
    text = _INITIAL.sub(r"\1", text)
    return text
