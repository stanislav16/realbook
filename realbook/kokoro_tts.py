"""Natural-sounding voices with Kokoro, an open-source speech model that runs offline.

The model (about 350 MB) is downloaded once into the data folder. Voices are named
`kokoro:<id>`, or `kokoro:<id>+<id>` for an even blend of two voices, which gives a
large cast more distinct-sounding people than the model ships with.
"""

from __future__ import annotations

import hashlib
import subprocess
import tempfile
import threading
import time
import wave
from pathlib import Path

import numpy as np

from . import store, system

RELEASE = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1"
FILES = {
    # name: (bytes, sha256)
    "kokoro-v1.0.onnx": (325505369, "beb0d1848dee9a49da392cc3df26958d46cfa35d321edf434f52949153f0df3a"),
    "voices-v1.0.bin": (28214398, "bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d"),
}
DOWNLOAD_BYTES = sum(size for size, _ in FILES.values())
BASE_RATE = 180  # the `say` words-per-minute that corresponds to Kokoro speed 1.0

# id: (display name, gender, locale, grade 0-10 from Kokoro's VOICES.md, age)
VOICES = {
    "af_heart": ("Heart", "female", "en_US", 10, "adult"),
    "af_bella": ("Bella", "female", "en_US", 9, "adult"),
    "af_nicole": ("Nicole", "female", "en_US", 7, "adult"),
    "af_aoede": ("Aoede", "female", "en_US", 6, "adult"),
    "af_kore": ("Kore", "female", "en_US", 6, "adult"),
    "af_sarah": ("Sarah", "female", "en_US", 6, "adult"),
    "af_alloy": ("Alloy", "female", "en_US", 5, "adult"),
    "af_nova": ("Nova", "female", "en_US", 5, "adult"),
    "af_sky": ("Sky", "female", "en_US", 4, "young"),
    "af_jessica": ("Jessica", "female", "en_US", 2, "adult"),
    "af_river": ("River", "female", "en_US", 2, "adult"),
    "am_fenrir": ("Fenrir", "male", "en_US", 6, "adult"),
    "am_michael": ("Michael", "male", "en_US", 6, "adult"),
    "am_puck": ("Puck", "male", "en_US", 6, "young"),
    "am_echo": ("Echo", "male", "en_US", 2, "adult"),
    "am_eric": ("Eric", "male", "en_US", 2, "adult"),
    "am_liam": ("Liam", "male", "en_US", 2, "young"),
    "am_onyx": ("Onyx", "male", "en_US", 2, "adult"),
    "am_santa": ("Santa", "male", "en_US", 1, "old"),
    "am_adam": ("Adam", "male", "en_US", 0, "adult"),
    "bf_emma": ("Emma", "female", "en_GB", 7, "adult"),
    "bf_isabella": ("Isabella", "female", "en_GB", 5, "adult"),
    "bf_alice": ("Alice", "female", "en_GB", 2, "adult"),
    "bf_lily": ("Lily", "female", "en_GB", 2, "young"),
    "bm_fable": ("Fable", "male", "en_GB", 5, "adult"),
    "bm_george": ("George", "male", "en_GB", 5, "adult"),
    "bm_lewis": ("Lewis", "male", "en_GB", 3, "adult"),
    "bm_daniel": ("Daniel", "male", "en_GB", 2, "adult"),
}
BLEND_MIN_GRADE = 5  # only blend voices that are good on their own
CAST_MIN_GRADE = 3  # weaker voices stay in the menus but aren't picked automatically


def model_dir() -> Path:
    return store.DATA_DIR / "models" / "kokoro"


def installed() -> bool:
    return all((model_dir() / name).exists() for name in FILES)


# ------------------------------------------------------------------ download

_install = {"state": "idle", "progress": 0.0, "message": ""}
_install_lock = threading.Lock()


def install_status() -> dict:
    return {"installed": installed(), "bytes": DOWNLOAD_BYTES, **_install}


def install_async(on_done=None) -> dict:
    with _install_lock:
        if _install["state"] == "downloading" or installed():
            return install_status()
        _install.update(state="downloading", progress=0.0, message="Starting download…")
    threading.Thread(target=_download, args=(on_done,), daemon=True).start()
    return install_status()


def _download(on_done) -> None:
    d = model_dir()
    d.mkdir(parents=True, exist_ok=True)
    done_bytes = 0
    try:
        for name, (size, sha) in FILES.items():
            target = d / name
            if target.exists():
                done_bytes += size
                continue
            part = d / f"{name}.part"
            # System curl uses the macOS certificate store, which a bundled Python may not have.
            proc = system.popen(
                [system.curl(), "-sSL", "--fail", "--retry", "3", "-C", "-", "-o", str(part), f"{RELEASE}/{name}"],
                stderr=subprocess.PIPE, text=True,
            )
            while proc.poll() is None:
                have = part.stat().st_size if part.exists() else 0
                _install["progress"] = (done_bytes + have) / DOWNLOAD_BYTES
                _install["message"] = f"Downloading voices… {int(100 * _install['progress'])}%"
                time.sleep(0.4)
            if proc.returncode != 0:
                raise RuntimeError(f"Download failed: {proc.stderr.read().strip() or 'network error'}")
            if part.stat().st_size != size:
                part.unlink()
                raise RuntimeError(f"{name} downloaded incompletely; please try again")
            if sha and _sha256(part) != sha:
                part.unlink()
                raise RuntimeError(f"{name} failed its integrity check; please try again")
            part.rename(target)
            done_bytes += size
        _install.update(state="done", progress=1.0, message="Natural voices installed")
        if on_done:
            on_done()
    except Exception as e:  # surfaced to the UI
        _install.update(state="error", message=str(e))


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ------------------------------------------------------------------ catalog


def catalog() -> list[dict]:
    """Kokoro voices in the same shape as voices.installed_voices(), plus blends for casting."""
    if not installed():
        return []
    out = []
    for vid, (name, gender, locale, grade, age) in VOICES.items():
        out.append(_entry(vid, name, gender, locale, grade, age))
    return out


def blends() -> list[dict]:
    """Even mixes of two good voices of the same gender and accent: extra distinct voices for big casts."""
    if not installed():
        return []
    good = [(vid, v) for vid, v in VOICES.items() if v[3] >= BLEND_MIN_GRADE]
    out = []
    for i, (a, va) in enumerate(good):
        for b, vb in good[i + 1:]:
            if va[1] == vb[1] and va[2] == vb[2]:
                grade = (va[3] + vb[3]) / 2 - 1  # cast after the single voices are used up
                out.append(_entry(f"{a}+{b}", f"{va[0]} + {vb[0]}", va[1], va[2], grade, "adult", blend=True))
    return out


def _entry(vid, name, gender, locale, grade, age, blend=False) -> dict:
    return {
        "name": f"kokoro:{vid}", "base": name, "locale": locale, "gender": gender, "age": age,
        "quality": 3 + grade / 5,  # Apple's scale tops out at 3 (Premium); every Kokoro voice sounds more natural
        "novelty": False, "engine": "kokoro", "blend": blend, "grade": grade,
    }


def describe(voice: str) -> dict | None:
    """Catalog entry for any kokoro: voice name, including blends not in the default list."""
    ids = voice.split(":", 1)[1].split("+")
    if not ids or any(i not in VOICES for i in ids):
        return None
    if len(ids) == 1:
        v = VOICES[ids[0]]
        return _entry(ids[0], *v)
    a, b = VOICES[ids[0]], VOICES[ids[1]]
    return _entry("+".join(ids), f"{a[0]} + {b[0]}", a[1], a[2], (a[3] + b[3]) / 2 - 1, "adult", blend=True)


# ---------------------------------------------------------------- synthesis

_model = None
_model_lock = threading.Lock()


def _get_model():
    global _model
    with _model_lock:
        if _model is None:
            from kokoro_onnx import Kokoro

            d = model_dir()
            _model = Kokoro(str(d / "kokoro-v1.0.onnx"), str(d / "voices-v1.0.bin"))
    return _model


def synthesize(out: Path, text: str, voice: str, rate: int, pitch_shift: int, style: str = "") -> None:
    """Render `text` to an .m4a at `out`.

    Kokoro has no pitch control, so pitch is shifted by resampling: speak a little slower,
    then play the samples back proportionally faster (higher) or slower (lower).
    """
    ids = voice.split(":", 1)[1].split("+")
    model = _get_model()
    style_vec = np.mean([model.get_voice_style(i) for i in ids], axis=0)
    lang = "en-gb" if ids[0].startswith("b") else "en-us"
    factor = 2 ** (pitch_shift / 60)
    speed = float(np.clip(rate / BASE_RATE / factor, 0.5, 2.0))
    samples, sample_rate = model.create(text, voice=style_vec, speed=speed * (0.94 if style == "quiet" else 1), lang=lang)
    if style == "quiet":
        samples = samples * 0.5  # Kokoro can't whisper: a whispered line is a little slower and 6 dB quieter

    pcm = (np.clip(samples, -1, 1) * 32767).astype("<i2").tobytes()
    with tempfile.NamedTemporaryFile(suffix=".wav", dir=out.parent, delete=False) as tmp:
        wav = Path(tmp.name)
    with wave.open(str(wav), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(int(round(sample_rate * factor)))
        w.writeframes(pcm)
    system.encode(wav, out, sample_rate)
