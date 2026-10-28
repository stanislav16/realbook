"""Free, offline character analysis.

Finds who speaks (from speech tags like `said Tom` / `she whispered` / `the old man asked`),
works out each speaker's gender, age, accent and voice quality from the words the book
uses around them, and attributes every quote to a speaker. It is rule-based, so it gets
the common cases right and leaves some quotes unattributed. Claude does better when an
API key is configured (see claude_analyzer.py).
"""

from __future__ import annotations

import re
from collections import Counter, defaultdict

SPEECH_VERBS = (
    "said says asked asks replied replies answered cried shouted yelled whispered murmured "
    "muttered called exclaimed added continued began snapped growled laughed sighed protested "
    "insisted admitted agreed demanded declared observed remarked repeated interrupted offered "
    "suggested warned explained pleaded begged roared hissed breathed chuckled grumbled stammered "
    "whimpered sobbed announced piped drawled barked mumbled groaned retorted inquired enquired "
    "wondered gasped shrieked screamed bellowed conceded ventured teased scoffed grunted told "
    "corrected urged prompted countered mused stated noted joked"
).split()
VERB = r"(?:%s)" % "|".join(SPEECH_VERBS)

MALE_TITLES = {"mr", "sir", "lord", "king", "prince", "uncle", "father", "brother", "monsieur", "master", "grandpa", "grandad", "granddad", "señor", "herr", "duke", "count", "baron"}
FEMALE_TITLES = {"mrs", "miss", "ms", "lady", "queen", "princess", "aunt", "mother", "sister", "madame", "mistress", "dame", "granny", "grandma", "gran", "señora", "frau", "duchess", "countess", "baroness", "mademoiselle"}
NEUTRAL_TITLES = {"dr", "doctor", "captain", "capt", "professor", "prof", "old", "young", "little", "big", "officer", "detective", "inspector", "sergeant", "colonel", "general", "major", "judge", "nurse"}
TITLES = MALE_TITLES | FEMALE_TITLES | NEUTRAL_TITLES

MALE_NOUNS = {"man", "boy", "father", "husband", "king", "gentleman", "fellow", "lad", "son", "brother", "uncle", "grandfather", "sir", "lord", "prince", "monk", "priest", "keeper", "fisherman", "farmer", "sailor", "soldier", "landlord", "waiter", "butler", "postman", "policeman", "guy"}
FEMALE_NOUNS = {"woman", "girl", "mother", "wife", "queen", "lady", "lass", "daughter", "sister", "aunt", "grandmother", "princess", "nun", "landlady", "waitress", "maid", "widow", "witch", "nurse", "actress", "hostess"}
NOT_SPEAKERS = {"wind", "sea", "voice", "voices", "radio", "door", "sign", "clock", "fire", "rain", "waves", "phone", "telephone", "kettle", "bird", "birds", "letter", "note", "storm", "gulls", "television", "tv", "engine", "house", "same", "other", "first", "next", "last",
                "room", "book", "story", "text", "law", "rule", "proverb", "saying", "inscription", "article", "report", "headline", "newspaper", "paper", "message", "poem", "song", "legend", "verse", "line", "passage", "quote", "chapter", "court", "crowd", "world", "public", "press"}

STOP = set(
    """The Then But And So When While After Before Yesterday Today Tomorrow Now Still Yet Suddenly
    Finally At In On Of For If As Just Even Only Once Again Here There This That These Those Well Oh
    No Yes Why What Where Who How I He She They We You It His Her Their Our My Your Its A An Not
    Perhaps Maybe Instead Although Though Because Since Until Unless Meanwhile Later Soon Never
    Always Sometimes Every Each All Some Any None Nothing Something Everything Everyone Someone
    Chapter Part Book Prologue Epilogue Monday Tuesday Wednesday Thursday Friday Saturday Sunday
    January February March April May June July August September October November December
    God Lord Christmas Easter English French German Scottish Irish American British Sorry Please
    Thank Thanks Hello Hi Goodbye Look Listen Come Go Let Don't Can't Won't Did Do Does Is Are Was
    Were Will Would Could Should Have Has Had Mum Mom Dad By People Men Women Others Many Most Few
    Several Both Either Neither Nobody Somebody Anyone Anybody Everybody Such Like Unlike With Without
    From To Into Upon Over Under Through During Against Among Between Within Despite Indeed Therefore
    However Thus Hence Also Earlier Afterward Afterwards Years Days Months Centuries Law Laws Rule""".split()
)
# Words that can't be the noun in "the ___ said": catches "the execution and said", "the publisher the …".
FUNCTION_WORDS = set(
    """and but or nor then who whom whose that which what when where while as so if he she it they we you
    i this these those there here was is were be been had has have not no one ones all some more most
    other same first next last only very just also too again still even than with without from into
    the a an his her their its my our your of in on at to for by""".split()
)

MALE_NAMES = set(
    """james john robert michael william david richard joseph thomas charles christopher daniel matthew
    anthony mark donald steven paul andrew joshua kenneth kevin brian george timothy ronald edward
    jason jeffrey ryan jacob gary nicholas eric jonathan stephen larry justin scott brandon benjamin
    samuel gregory alexander frank patrick raymond jack dennis jerry tyler aaron jose adam nathan
    henry douglas zachary peter kyle noah ethan jeremy walter christian keith roger terry austin
    sean gerald carl harold dylan arthur lawrence jordan jesse bryan billy bruce gabriel joe logan
    albert willie alan eugene russell vincent philip bobby johnny bradley roy ralph louis harry
    fred frederick angus hamish callum duncan ewan alastair liam conor declan seamus finn oliver
    oscar leo hugo max felix theo jasper rupert edmund tom tim tommy ben sam jim jimmy bill bob
    dick ned ted ed will charlie archie alfie jake luke mike nick pete rob simon tony victor ivan
    dmitri sergei pierre jacques luis carlos juan pedro diego marco luca giovanni hans karl otto
    ahmed omar ali hassan raj ravi arjun rahul hiro kenji darcy bingley wickham heathcliff edgar
    hal hob bert silas jonas elias abel caleb gideon ezra isaac jasper magnus""".split()
)
FEMALE_NAMES = set(
    """mary patricia jennifer linda elizabeth barbara susan jessica sarah karen nancy lisa betty
    margaret sandra ashley kimberly emily donna michelle dorothy carol amanda melissa deborah
    stephanie rebecca sharon laura cynthia kathleen amy shirley angela helen anna brenda pamela
    nicole emma samantha katherine christine debra rachel catherine carolyn janet ruth maria heather
    diane virginia julie joyce victoria olivia kelly christina lauren joan evelyn judith megan cheryl
    andrea hannah martha jacqueline frances gloria ann teresa kathryn sara janice jean alice madison
    doris abigail julia judy grace denise amber marilyn beverly danielle theresa sophia marie diana
    brittany natalie isabella charlotte rose alexis kayla lily lucy ellie molly daisy poppy jane
    jenny kate katie annie beth meg jo amy elsie edith ethel mabel agnes bridget siobhan niamh aoife
    fiona morag isla eilidh kirsty mara clara cora nora flora iris ivy hazel violet esther miriam
    leah eve ava mia zoe chloe sophie amelia harriet matilda beatrice eleanor eliza georgiana lydia
    kitty catherine marianne elinor cathy isabel anne hermione luna ginny petunia minerva maya priya
    aisha fatima yuki sakura mei ling natasha olga irina sonia elena lucia sofia carmen rosa
    ingrid astrid greta heidi marta nell nan nettie""".split()
)

AGE_WORDS = {
    "old": ["old", "elderly", "aged", "ancient", "grey-haired", "gray-haired", "white-haired",
            "wrinkled", "grizzled", "weathered", "frail", "stooped", "grandfather", "grandmother",
            "granny", "grandpa", "grandma", "veteran", "retired", "white beard", "silver hair",
            "old man", "old woman", "old lady"],
    "child": ["child", "little girl", "little boy", "kid", "toddler", "small boy", "small girl",
              "schoolboy", "schoolgirl", "freckled", "pigtails", "boyish", "childish", "youngster"],
    "young": ["young", "youth", "teenage", "teenager", "youthful", "lad", "lass", "student",
              "young man", "young woman", "girl", "boy"],
}
ACCENT_WORDS = {
    "scottish": ["scottish", "scots", "scotsman", "scotswoman", "highland", "highlands", "glasgow", "edinburgh", "aberdeen", "brogue", "burr"],
    "irish": ["irish", "irishman", "irishwoman", "dublin", "cork", "galway", "belfast"],
    "british": ["british", "english", "englishman", "englishwoman", "london", "cockney", "posh", "oxford", "yorkshire"],
    "australian": ["australian", "aussie", "sydney", "melbourne"],
    "indian": ["indian", "delhi", "mumbai", "bombay", "calcutta", "bengali"],
    "south_african": ["south african", "johannesburg", "cape town"],
    "american": ["american", "yankee", "texan", "texas", "new york", "new yorker", "southern drawl", "brooklyn", "boston", "chicago", "california"],
    "french": ["french", "frenchman", "frenchwoman", "paris", "parisian"],
    "german": ["german", "berlin", "bavarian"],
    "italian": ["italian", "rome", "naples", "sicilian"],
    "spanish": ["spanish", "madrid", "mexican", "spaniard"],
}
# How a voice sounds. Words that only mean something about a voice when they describe one
# ("a deep voice", not "deep in thought") need a voice word right after them; "in a low voice"
# means quietly, so "low" doesn't count at all. Whole words only ("rough" is not "through").
VOICE_NOUN = r"(?:[\w-]+,? ){0,2}(?:voice|voices|tone|tones|laugh|baritone|bass)\b"
PITCH_WORDS = {
    -1: ["booming", "gravelly", "bass", "baritone", "thunderous", "rasping", "raspy", "hoarse", "growled", "gruffly"],
    1: ["high-pitched", "shrill", "squeaky", "piping", "soprano", "squeaked", "squeaking", "sing-song", "chirpy", "tinkling"],
}
PITCH_VOICE_WORDS = {  # count only when describing a voice
    -1: ["deep", "rough", "gruff", "husky", "rumbling", "resonant", "smoky", "gravel"],
    1: ["high", "thin", "bright", "breathy", "lilting", "light", "girlish", "boyish"],
}
PITCH_THRESHOLD = 2  # net votes needed before a character counts as deep- or high-voiced
PACE_WORDS = {
    -1: ["slow", "slowly", "drawl", "drawled", "measured", "deliberate", "ponderous", "unhurried", "languid", "lazily"],
    1: ["quick", "quickly", "rapid", "rapidly", "fast", "breathless", "nervous", "nervously", "chattering", "babbled", "gabbled", "jittery", "excitable", "hurried", "hurriedly", "eager"],
}
NUMBERS = {"five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
           "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
           "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
           "seventy": 70, "eighty": 80, "ninety": 90}

NAME = r"(?:(?:%s)\.?\s+)?[A-Z][a-zA-Z'’-]+(?:\s+[A-Z][a-zA-Z'’-]+)?" % "|".join(
    sorted((t.capitalize() for t in TITLES), key=len, reverse=True)
)
TAG_AFTER = re.compile(r"\b%s\s+(%s)" % (VERB, NAME))
TAG_BEFORE = re.compile(r"(%s)\s+(?:[a-z]+ly\s+)?%s\b" % (NAME, VERB))
TAG_PRONOUN = re.compile(r"\b(?:(he|she)\s+(?:[a-z]+ly\s+)?%s|%s\s+(he|she))\b" % (VERB, VERB), re.IGNORECASE)
TAG_NOMINAL = re.compile(r"\b(?:%s\s+the\s+(?:([a-z]+)\s+)?([a-z]+)|the\s+(?:([a-z]+)\s+)?([a-z]+)\s+(?:[a-z]+ly\s+)?%s)\b" % (VERB, VERB))
SENTENCES = re.compile(r"(?<=[.!?…])\s+")
PRONOUN_M = re.compile(r"\b(he|his|himself)\b", re.IGNORECASE)
PRONOUN_F = re.compile(r"\b(she|hers|herself)\b", re.IGNORECASE)


# "The ___ said" is only a character when ___ is a person: "the old woman", "the guard", not
# "the memory" or "the table". Nouns for people, plus words that usually name one by what they do.
PERSON_WORDS = set("""
    man woman men women boy boys girl girls lady ladies gentleman gentlemen child children kid kids lad lass fellow
    youth baby infant twin twins person people folk stranger visitor guest newcomer host hostess crowd
    mother father mum mom dad mama papa sister brother uncle aunt son daughter wife husband cousin
    grandmother grandfather granny grandpa grandma widow widower bride groom niece nephew parent parents
    king queen prince princess duke duchess baron baroness count countess earl lord emperor empress
    chief leader master mistress boss captain general colonel major sergeant lieutenant commander admiral
    soldier soldiers guard guards trooper troopers knight knights squire page warrior warriors officer officers
    priest priestess monk nun reverend bishop prophet witch wizard sorcerer sorceress crone hag
    servant servants maid butler footman slave slaves cook chef waiter waitress bartender clerk secretary
    doctor nurse surgeon teacher student professor scientist engineer mechanic pilot sailor sailors fisherman
    farmer hunter thief robber bandit pirate pirates prisoner captive assassin spy agent courier messenger herald
    judge lawyer banker merchant trader smuggler smugglers gladiator truthsayer mentat ecologist planetologist
    giant dwarf elf creature friend enemy rival companion partner mate
    male female redhead blonde blond brunette youngster elder elders veteran novice recruit cadet cadets
    czar tsar sultan shah pharaoh caliph khan bashar magnate delegate delegates envoy ambassador minister
    citizen citizens peasant peasants villager villagers native natives tribesman crew troop troops
    owl cat fox tortoise frog frogs dog wolf bear lion mouse rabbit hare crow raven horse donkey snake
    serpent dragon eagle hawk kite kites monkey ape goat sheep pig cow bull rat ant grasshopper parrot
    """.split())  # animals talk in fables and fantasy
PERSON_SUFFIX = re.compile(r"(?:er|or|ist|ess|ian|eer)s?$")
NOT_PEOPLE = set("""
    water paper letter corner matter number order power answer center centre danger river weather winter summer
    silver finger shoulder mirror door floor color colour error terror honor honour labor labour shelter border
    chamber cluster pattern feather leather thunder hunger anger
    """.split())


def _is_person_noun(noun: str) -> bool:
    noun = noun.lower()
    if noun in PERSON_WORDS or re.search(r"(?:man|men|woman|women|person|people)$", noun):  # "businessman"
        return True
    return len(noun) > 4 and bool(PERSON_SUFFIX.search(noun)) and noun not in NOT_PEOPLE


def _nominal(adj: str | None, noun: str | None) -> str | None:
    """Normalise "the old man" / "the cat finally" (→ "the cat") from a speech tag, or None if it isn't a person."""
    if not noun:
        return None
    if noun.endswith("ly"):
        if not adj:
            return None
        adj, noun = None, adj
    if noun in FUNCTION_WORDS or noun in NOT_SPEAKERS or len(noun) <= 2 or not _is_person_noun(noun):
        return None
    if adj and (adj in FUNCTION_WORDS or adj.endswith("ly")):
        adj = None
    return f"the {adj} {noun}" if adj else f"the {noun}"


def _after_the(narr: str, start: int) -> bool:
    """True for "the Incan Empire declared": a capitalised thing, not a person's name."""
    return narr[max(0, start - 4):start].lower() == "the "


def _slug(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") or "char"


PRONOUNS = {"i", "me", "he", "him", "she", "her", "it", "we", "us", "they", "them", "you", "one", "who"}


def _clean_name(raw: str) -> str | None:
    # Drop "'s", "'d", "'ll"… first: "She's" must be seen as "She", which is not a name.
    raw = re.sub(r"['’](?:s|d|ll|re|ve|m)\b", "", raw)
    words = raw.replace("’", "'").split()
    while words and words[0].rstrip(".") in STOP:
        words = words[1:]
    while words and words[-1] in STOP:
        words = words[:-1]
    if not words:
        return None
    if len(words) == 1 and words[0].rstrip(".").lower() in TITLES:
        return None
    name = " ".join(words)
    if name.endswith("'s"):
        name = name[:-2]
    if name.lower() in PRONOUNS:  # a pronoun is never a character
        return None
    return name


class _Char:
    def __init__(self, name: str, nominal: bool = False):
        self.name = name
        self.nominal = nominal
        self.aliases: set[str] = {name}
        self.votes = {"gender": Counter(), "age": Counter(), "accent": Counter(), "pitch": Counter(), "pace": Counter()}
        self.evidence: list[str] = []
        self.lines = 0

    @property
    def id(self) -> str:
        return _slug(self.name)


def analyze(chapters: list[dict]) -> dict:
    """chapters: [{"title", "segments"}]. Fills seg["speaker"] in place and returns {"characters": [...]}."""
    paragraphs = _paragraphs(chapters)

    # 1. Discover speakers from speech tags.
    named: Counter = Counter()
    nominal: Counter = Counter()
    for para in paragraphs:
        if not para["quotes"]:
            continue
        narr = para["narration"]
        for m in TAG_AFTER.finditer(narr):
            if (n := _clean_name(m.group(1))):
                named[n] += 1
        for m in TAG_BEFORE.finditer(narr):
            if not _after_the(narr, m.start()) and (n := _clean_name(m.group(1))):
                named[n] += 1
        for m in TAG_NOMINAL.finditer(narr):
            adj, noun = (m.group(1), m.group(2)) if m.group(2) else (m.group(3), m.group(4))
            if (phrase := _nominal(adj, noun)):
                nominal[phrase] += 1

    chars: dict[str, _Char] = {}
    alias_to_id: dict[str, str] = {}

    def add(name: str, is_nominal: bool = False) -> _Char:
        c = _Char(name, is_nominal)
        chars[c.id] = c
        alias_to_id[name] = c.id
        return c

    # Longer names first so "Mara Quinn" exists before "Mara" is merged into it.
    for name, _ in sorted(named.items(), key=lambda kv: (-len(kv[0].split()), -kv[1])):
        if name in alias_to_id:
            continue
        bare = name.split()
        if len(bare) == 1:
            matches = [c for c in chars.values() if not c.nominal and name in c.name.split()
                       and c.name.split()[0].rstrip(".").lower() not in TITLES]
            if len(matches) == 1:
                matches[0].aliases.add(name)
                alias_to_id[name] = matches[0].id
                continue
        add(name)
    # Re-key each named character by its most-used form ("Mara" rather than "Mara Quinn").
    for c in list(chars.values()):
        best = max(c.aliases, key=lambda a: (named.get(a, 0), -len(a)))
        if best != c.name:
            del chars[c.id]
            c.name = best
            chars[c.id] = c
            for a in c.aliases:
                alias_to_id[a] = c.id
    for phrase, count in nominal.items():
        if count >= 1 and phrase not in alias_to_id:
            add(phrase.capitalize(), is_nominal=True)
            alias_to_id[phrase] = chars[_slug(phrase.capitalize())].id

    # Full names in narration ("Isla Quinn", "Ellen Quinn") become aliases. This also ties
    # a first name to a titled speaker ("Ellen Quinn" is "Mrs. Quinn").
    _link_full_names(paragraphs, chars, alias_to_id)
    mention_re = _mention_regex(alias_to_id)

    # 2. Profile each character from the sentences about them. A sentence that starts with
    # He/She and names nobody is about the last person named in the paragraph.
    texts: dict[str, list[str]] = defaultdict(list)
    for para in paragraphs:
        subject = None
        for sent in SENTENCES.split(para["narration"]):
            hits = _mention_spans(sent, mention_re, alias_to_id)
            ids = list(dict.fromkeys(cid for cid, _, _ in hits))
            if len(ids) == 1:
                subject = ids[0]
                _, start, end = hits[0]
                _profile(chars[subject], _near(sent, start, end), sent)
                texts[subject].append(sent.lower())
            elif not ids and subject and re.match(r"\s*(He|She)\b", sent):
                _profile(chars[subject], sent[:200], sent)
                texts[subject].append(sent.lower())
            elif ids:
                subject = None
    for c in chars.values():
        _name_gender(c)
    _merge_nominals(chars, alias_to_id, texts)
    mention_re = _mention_regex(alias_to_id)

    # 3. Attribute quotes.
    recent: list[str] = []  # character ids, most recent last
    last_speakers: list[str] = []
    for para in paragraphs:
        narr = para["narration"]
        hits = _mention_spans(narr, mention_re, alias_to_id)
        mentioned = list(dict.fromkeys(cid for cid, _, _ in hits))
        speaker = None
        if para["quotes"]:
            speaker = _tagged_speaker(narr, alias_to_id, chars, recent, hits)
            if speaker is None and para["cont"] and last_speakers and last_speakers[-1] != "?":
                speaker = last_speakers[-1]  # a quote running on from the last paragraph, if we knew who said that
            if speaker is None and len(set(mentioned)) == 1:
                speaker = mentioned[0]
            known = [s for s in last_speakers if s != "?"]
            if speaker is None and len(known) >= 2 and known[-1] != known[-2] and not narr.strip():
                speaker = known[-2]
            if speaker is None and known and not narr.strip():
                others = [cid for cid in reversed(recent) if cid != known[-1]]
                speaker = others[0] if others else None
            for seg in para["quotes"]:
                seg["speaker"] = speaker
            if speaker:
                chars[speaker].lines += len({s["q"] for s in para["quotes"]})
                last_speakers.append(speaker)
            else:
                last_speakers.append("?")
        elif len(narr) > 400 or para.get("break"):
            last_speakers.clear()  # a long stretch of narration ends a conversation
        for cid in mentioned:
            _touch(recent, cid)
        if speaker:
            _touch(recent, speaker)

    characters = []
    for c in sorted(chars.values(), key=lambda c: -c.lines):
        if c.lines == 0:
            continue
        characters.append(_export(c))
    return {"characters": characters}


def _paragraphs(chapters: list[dict]) -> list[dict]:
    out = []
    for ch in chapters:
        by_para: dict[int, list[dict]] = defaultdict(list)
        for seg in ch["segments"]:
            by_para[seg["para"]].append(seg)
        for _, segs in sorted(by_para.items()):
            out.append({
                "narration": " ".join(s["text"] for s in segs if s["kind"] == "narration"),
                "quotes": [s for s in segs if s["kind"] == "dialogue"],
                "cont": any(s["cont"] for s in segs),
            })
        out.append({"narration": "", "quotes": [], "cont": False, "break": True})
    return out


def _mentions(text: str, mention_re, alias_to_id) -> list[str]:
    return list(dict.fromkeys(cid for cid, _, _ in _mention_spans(text, mention_re, alias_to_id)))


def _mention_regex(alias_to_id: dict[str, str]) -> re.Pattern | None:
    names = [re.escape(a) for a in sorted(alias_to_id, key=len, reverse=True) if not a.startswith("the ")]
    nominal = [re.escape(a) for a in alias_to_id if a.startswith("the ")]
    parts = []
    if names:
        parts.append(r"\b(?:%s)\b" % "|".join(names))
    if nominal:
        parts.append(r"(?i:\b(?:%s)\b)" % "|".join(nominal))
    return re.compile("|".join(parts)) if parts else None


def _mention_spans(text: str, mention_re, alias_to_id) -> list[tuple[str, int, int]]:
    """[(character id, start, end)] for every name mention, in order."""
    if not mention_re:
        return []
    out = []
    for m in mention_re.finditer(text):
        key = m.group(0)
        cid = alias_to_id.get(key) or alias_to_id.get(key.lower())
        if cid:
            out.append((cid, m.start(), m.end()))
    return out


def _age(c: "_Char") -> str:
    return c.votes["age"].most_common(1)[0][0] if c.votes["age"] else "adult"


FULL_NAME = re.compile(r"\b([A-Z][a-z]+) ([A-Z][a-zA-Z'’-]{2,})\b")
PERSON_NOUNS = {"man", "woman", "boy", "girl", "lady", "gentleman", "child", "lad", "lass", "fellow", "kid"}


def _link_full_names(paragraphs, chars, alias_to_id) -> None:
    for para in paragraphs:
        for m in FULL_NAME.finditer(para["narration"]):
            first, last = m.groups()
            full = f"{first} {last}"
            if full in alias_to_id or first in STOP or last in STOP or first.lower() in TITLES:
                continue
            if first in alias_to_id:
                target = alias_to_id[first]
            else:
                fl = first.lower()
                gender = "male" if fl in MALE_NAMES else "female" if fl in FEMALE_NAMES else None
                titled = [
                    c for c in chars.values()
                    if not c.nominal and len(c.name.split()) == 2 and c.name.split()[1] == last
                    and (t := c.name.split()[0].rstrip(".").lower()) in MALE_TITLES | FEMALE_TITLES
                    and (gender is None or (t in MALE_TITLES) == (gender == "male"))
                ]
                if len(titled) != 1:
                    continue
                target = titled[0].id
                alias_to_id[first] = target
                chars[target].aliases.add(first)
            alias_to_id[full] = target
            chars[target].aliases.add(full)


def _merge_nominals(chars, alias_to_id, texts) -> None:
    """Fold "the old man" into Angus when Angus is the only old man in the book."""
    for c in [c for c in chars.values() if c.nominal]:
        words = c.name.lower().split()[1:]
        noun, adj = words[-1], (words[0] if len(words) > 1 else "")
        named = [n for n in chars.values() if not n.nominal]
        if noun in PERSON_NOUNS:
            want = ("old" if adj in {"old", "elderly", "aged", "ancient"}
                    else "child" if noun in {"boy", "girl", "child", "kid"} or adj in {"little", "small"}
                    else "young" if adj == "young" else None)
            if want is None:
                continue
            matches = [n for n in named if _gender(n) == _gender(c) and _age(n) == want]
        else:  # a role: "the keeper", "the captain"
            matches = [n for n in named if any(re.search(r"\b%s\b" % noun, t) for t in texts[n.id])]
        if len(matches) != 1:
            continue
        target = matches[0]
        for key, cid in list(alias_to_id.items()):
            if cid == c.id:
                alias_to_id[key] = target.id
        target.aliases |= c.aliases
        del chars[c.id]


def _touch(recent: list[str], cid: str) -> None:
    if cid in recent:
        recent.remove(cid)
    recent.append(cid)


def _tagged_speaker(narr: str, alias_to_id, chars, recent, hits) -> str | None:
    """Resolve the speech tag that comes first in the narration around a quote."""
    found: list[tuple[int, str | None]] = []
    for rx in (TAG_AFTER, TAG_BEFORE):
        for m in rx.finditer(narr):
            n = _clean_name(m.group(1))
            if n and n in alias_to_id and not (rx is TAG_BEFORE and _after_the(narr, m.start())):
                found.append((m.start(), alias_to_id[n]))
                break
    m = TAG_NOMINAL.search(narr)
    if m:
        adj, noun = (m.group(1), m.group(2)) if m.group(2) else (m.group(3), m.group(4))
        phrase = _nominal(adj, noun)
        for phrase in (phrase, f"the {phrase.split()[-1]}" if phrase else None):
            if phrase and phrase in alias_to_id:
                found.append((m.start(), alias_to_id[phrase]))
                break
    m = TAG_PRONOUN.search(narr)
    if m:
        gender = "male" if (m.group(1) or m.group(2)).lower() == "he" else "female"
        # "he said" is whoever of that gender was named last: earlier in this paragraph, else recently.
        before = [cid for cid, start, _ in hits if start < m.start()]
        match = next((cid for cid in [*reversed(before), *reversed(recent)] if _gender(chars[cid]) == gender), None)
        found.append((m.start(), match))
    found.sort(key=lambda f: f[0])
    return found[0][1] if found else None


def _near(sent: str, start: int, end: int) -> str:
    """The words describing a name: a little before it, up to the end of its clause."""
    after = re.split(r",? (?:while|but|whereas|although|as|when) |; ", sent[end:end + 160])[0]
    return sent[max(0, start - 60):end] + after


def _profile(c: _Char, text: str, sent: str) -> None:
    """Vote on gender/age/accent/voice from `text` (the words near the mention)."""
    low = text.lower()
    m, f = len(PRONOUN_M.findall(sent)), len(PRONOUN_F.findall(sent))
    if m > f:
        c.votes["gender"]["male"] += 1
    elif f > m:
        c.votes["gender"]["female"] += 1
    if (dm := re.search(r"\bin (?:his|her) (?:early |late |mid-)?(twenties|thirties|forties|fifties|sixties|seventies|eighties|nineties)\b", low)):
        c.votes["age"]["young" if dm.group(1) == "twenties" else "adult" if dm.group(1) in ("thirties", "forties", "fifties") else "old"] += 5
    useful = False
    for age, words in AGE_WORDS.items():
        for w in words:
            if re.search(r"\b%s\b" % re.escape(w), low):
                c.votes["age"][age] += 2 if age != "young" else 1
                useful = True
    if (am := re.search(r"\b(\d{1,2}|%s)[- ]years?[- ]old\b" % "|".join(NUMBERS), low)):
        years = int(am.group(1)) if am.group(1).isdigit() else NUMBERS[am.group(1)]
        c.votes["age"]["child" if years < 13 else "young" if years < 25 else "adult" if years < 60 else "old"] += 5
        useful = True
    for accent, words in ACCENT_WORDS.items():
        for w in words:
            if re.search(r"\b%s\b" % re.escape(w), low):
                c.votes["accent"][accent] += 2 if "accent" in low or "voice" in low else 1
                useful = True
    for direction, words in PITCH_WORDS.items():
        for w in words:
            if re.search(r"\b%s\b" % re.escape(w), low):
                c.votes["pitch"][direction] += 1
                useful = True
    for direction, words in PITCH_VOICE_WORDS.items():
        for w in words:
            if re.search(r"\b%s\b,? %s" % (re.escape(w), VOICE_NOUN), low):
                c.votes["pitch"][direction] += 2  # said outright: "a deep voice"
                useful = True
    for direction, words in PACE_WORDS.items():
        for w in words:
            if re.search(r"\b%s\b" % re.escape(w), low):
                c.votes["pace"][direction] += 1
    for noun in MALE_NOUNS:
        if re.search(r"\b%s\b" % noun, low):
            c.votes["gender"]["male"] += 1
    for noun in FEMALE_NOUNS:
        if re.search(r"\b%s\b" % noun, low):
            c.votes["gender"]["female"] += 1
    if useful and len(c.evidence) < 4 and len(sent) < 400 and sent.strip() not in c.evidence:
        c.evidence.append(sent.strip())


def _name_gender(c: _Char) -> None:
    first = c.name.split()[0].rstrip(".").lower()
    words = c.name.lower().split()
    if first in MALE_TITLES or words[-1] in MALE_NOUNS:
        c.votes["gender"]["male"] += 10
    elif first in FEMALE_TITLES or words[-1] in FEMALE_NOUNS:
        c.votes["gender"]["female"] += 10
    for w in c.name.split():
        lw = w.lower()
        if lw in MALE_NAMES:
            c.votes["gender"]["male"] += 4
        if lw in FEMALE_NAMES:
            c.votes["gender"]["female"] += 4
    if "old" in words:
        c.votes["age"]["old"] += 10
    if words[-1] in {"boy", "girl", "child", "kid"}:
        c.votes["age"]["child"] += 10


def _gender(c: _Char) -> str:
    g = c.votes["gender"]
    if not g:
        return "unknown"
    (top, n), *rest = g.most_common()
    return top if not rest or n > rest[0][1] else "unknown"


def _export(c: _Char) -> dict:
    age = c.votes["age"].most_common(1)[0][0] if c.votes["age"] else "adult"
    accent = c.votes["accent"].most_common(1)[0][0] if c.votes["accent"] else ""
    net = sum(k * v for k, v in c.votes["pitch"].items())
    pitch = 0 if abs(net) < PITCH_THRESHOLD else (1 if net > 0 else -1)
    pace = sum(k * v for k, v in c.votes["pace"].items())
    gender = _gender(c)
    bits = [b for b in (age if age != "adult" else "", gender if gender != "unknown" else "", accent.replace("_", " ")) if b]
    voice = []
    if pitch < 0:
        voice.append("low voice")
    elif pitch > 0:
        voice.append("high voice")
    if pace < 0:
        voice.append("slow speech")
    elif pace > 0:
        voice.append("quick speech")
    return {
        "id": c.id,
        "name": c.name,
        "aliases": sorted(a for a in c.aliases if a != c.name),
        "gender": gender,
        "age": age,
        "accent": accent,
        "pitch": max(-1, min(1, pitch)),
        "pace": max(-1, min(1, pace)),
        "summary": ", ".join(bits + voice) or "no description found",
        "evidence": c.evidence,
        "lines": c.lines,
    }
