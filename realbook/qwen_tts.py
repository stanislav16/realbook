"""Designed voices with Qwen3-TTS, an open-source speech model that runs offline on Apple silicon.

Each character's voice is designed once from a written description ("an old Scottish man with
a deep, gravelly voice") as a short reference clip. Every line they speak is then cloned from
that clip with a smaller, faster model, so the voice stays the same from line to line.

Voices are named `qwen:<key>`; the description behind each key lives in voices/<key>.json and
its reference clip in voices/<key>.wav. About 6.4 GB of models are downloaded once.
"""

from __future__ import annotations

import hashlib
import itertools
import json
import os
import platform
import queue
import shutil
import subprocess
import tempfile
import threading
import time
import wave
from concurrent.futures import Future
from pathlib import Path

import numpy as np

from . import store, system

HF = "https://huggingface.co"
# Pinned revisions of the MLX conversions; every file is checked against its size and sha256.
MODELS = {
    "designer": ("mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16", "7d3824abff87e49756bb0f83fb5411de75d160c4", {
        "model.safetensors": (3833402589, "96ae28bec2205ec0b5e0c750bea2b8a5deac4f14d33a8a25a5f753299486b70e"),
        "model.safetensors.index.json": (32458, "abf019e063dcc595d7aef7c9554d2806ffdc58746a7ac6238cb26177af8d431f"),
        "config.json": (5232, "8a9be83c045ee9ab9d2e6609655f547b9291a070f5acae3428c3ff07a365de40"),
    }),
    "reader": ("mlx-community/Qwen3-TTS-12Hz-0.6B-Base-bf16", "1eccf1cb2519b5a4e8a95b5f0544f3303568164f", {
        "model.safetensors": (1829344448, "d7c7ed3e3464e3e59de0f955b3755891fa8319ff061c3f0307fe2e1343bc122d"),
        "model.safetensors.index.json": (38573, "e02433c97b2894586e8842af2b40381c5bb644bc1c6bf71a6a52a727efe92313"),
        "config.json": (5317, "ee1871ab778c89645f8806df736cb35958619c40276598a41aeaa014615656a4"),
    }),
}
# Files both models share byte for byte (tokenizers and the audio codec).
SHARED = {
    "generation_config.json": (245, "f1b90b4513f3b34c62851049e2492d7b4c5940daf1276f89c82b8ef04127f3aa"),
    "merges.txt": (1671839, "599bab54075088774b1733fde865d5bd747cbcc7a547c5bc12610e874e26f5e3"),
    "preprocessor_config.json": (127, "efdde1022ea9d76928bf7a9cd53139138f5ba2e466e837f08f6105ab1af1c119"),
    "speech_tokenizer/config.json": (2336, "ee65bb901c876664ab8707c487157aa1a6ee57c65969b28fb5ec9dc211e68167"),
    "speech_tokenizer/configuration.json": (76, "6bc26d64eb5024b4d1dab5a52371958b429256d6c9d59787f1f5294a54e0cebd"),
    "speech_tokenizer/model.safetensors": (682293092, "836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258"),
    "speech_tokenizer/preprocessor_config.json": (234, "fcb3805e597e786d4067706e602f6688524640f8d3396790e2e09b5942fcbdfb"),
    "tokenizer_config.json": (7344, "dc3c31c3bdaedd5016382bb3cbe07323026775ad51f5a4fb564505992ae4a670"),
    "vocab.json": (2776833, "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
}
DOWNLOAD_BYTES = sum(size for _, _, files in MODELS.values() for size, _ in files.values()) + sum(
    size for size, _ in SHARED.values())  # shared files are downloaded once and linked into the other model
SAMPLE_RATE = 24000
DESIGNER_IDLE_SECONDS = 120  # the big design model is unloaded when no new voices are being made

NARRATOR_DESCRIPTION = ("A warm, clear adult female narrator with a calm, measured, storytelling delivery "
                        "and a neutral American accent.")
# Spoken by every designed voice; the reader model clones the voice from it.
REFERENCE_TEXT = ("I have been thinking about it all morning, and I suppose there is no better time to tell you. "
                  "Some things are easier to say out loud than to keep to yourself.")
ACCENT_WORDS = {"south_african": "South African"}
TIMBRES = ["warm", "bright", "husky", "smooth", "crisp", "rich", "soft", "slightly raspy"]


_mlx_loads: bool | None = None


def supported() -> bool:
    """Apple silicon, with a macOS new enough for the bundled MLX runtime to load."""
    global _mlx_loads
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        return False
    if _mlx_loads is None:
        try:
            import mlx.core  # noqa: F401
            _mlx_loads = True
        except Exception:
            _mlx_loads = False
    return _mlx_loads


def model_dir() -> Path:
    return store.DATA_DIR / "models" / "qwen"


def _files(role: str) -> dict[str, tuple[int, str]]:
    return {**MODELS[role][2], **SHARED}


def installed() -> bool:
    return supported() and all((model_dir() / role / name).exists() for role in MODELS for name in _files(role))


def voices_dir() -> Path:
    return model_dir() / "voices"


# ------------------------------------------------------------------ download

_install = {"state": "idle", "progress": 0.0, "message": ""}
_install_lock = threading.Lock()


def install_status() -> dict:
    return {"installed": installed(), "supported": supported(), "bytes": DOWNLOAD_BYTES, **_install}


def install_async(on_done=None) -> dict:
    with _install_lock:
        if _install["state"] == "downloading" or installed() or not supported():
            return install_status()
        _install.update(state="downloading", progress=0.0, message="Starting download…")
    threading.Thread(target=_download, args=(on_done,), daemon=True).start()
    return install_status()


def _download(on_done) -> None:
    done_bytes = 0
    have: dict[str, Path] = {}  # sha256 -> a finished file, to link instead of downloading twice
    try:
        for role, (repo, rev, _) in MODELS.items():
            for name, (size, sha) in _files(role).items():
                target = model_dir() / role / name
                target.parent.mkdir(parents=True, exist_ok=True)
                if not target.exists():
                    _install["message"] = f"Preparing designed voices… {int(100 * _install['progress'])}%"
                    source = have.get(sha) or _hf_cache_copy(repo, rev, name, size, sha)
                    if source and source.stat().st_dev == target.parent.stat().st_dev:
                        os.link(source, target)
                    elif source:
                        shutil.copy(source, target)
                    else:
                        _fetch(f"{HF}/{repo}/resolve/{rev}/{name}", target, size, sha, done_bytes)
                if sha not in have:
                    have[sha] = target
                    done_bytes += size
                _install["progress"] = min(1.0, done_bytes / DOWNLOAD_BYTES)
        _install.update(state="done", progress=1.0, message="Designed voices installed")
        if on_done:
            on_done()
    except Exception as e:  # surfaced to the UI
        _install.update(state="error", message=str(e))


def _hf_cache_copy(repo: str, rev: str, name: str, size: int, sha: str) -> Path | None:
    """The same file from an earlier Hugging Face download on this Mac, if there is one."""
    p = Path.home() / ".cache" / "huggingface" / "hub" / f"models--{repo.replace('/', '--')}" / "snapshots" / rev / name
    try:
        p = p.resolve(strict=True)
    except OSError:
        return None
    return p if p.stat().st_size == size and _sha256(p) == sha else None


def _fetch(url: str, target: Path, size: int, sha: str, done_bytes: int) -> None:
    part = target.with_name(target.name + ".part")
    # System curl uses the macOS certificate store, which a bundled Python may not have.
    proc = system.popen([system.curl(), "-sSL", "--fail", "--retry", "3", "-C", "-", "-o", str(part), url],
                            stderr=subprocess.PIPE, text=True)
    while proc.poll() is None:
        got = part.stat().st_size if part.exists() else 0
        _install["progress"] = (done_bytes + got) / DOWNLOAD_BYTES
        _install["message"] = f"Downloading designed voices… {int(100 * _install['progress'])}%"
        time.sleep(0.4)
    if proc.returncode != 0:
        raise RuntimeError(f"Download failed: {proc.stderr.read().strip() or 'network error'}")
    if part.stat().st_size != size:
        part.unlink()
        raise RuntimeError(f"{target.name} downloaded incompletely; please try again")
    _install["message"] = "Checking the download…"
    if _sha256(part) != sha:
        part.unlink()
        raise RuntimeError(f"{target.name} failed its integrity check; please try again")
    part.rename(target)


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ------------------------------------------------------------- descriptions


def describe_character(char: dict) -> str:
    """A voice description from what the analyzer found: who they are, how they sound, how they talk."""
    if char.get("voice_description"):
        return char["voice_description"]
    gender, age = char.get("gender", "unknown"), char.get("age", "adult")
    who = {
        ("male", "child"): "A young boy, about ten years old,", ("female", "child"): "A young girl, about ten years old,",
        ("male", "young"): "A young man in his twenties", ("female", "young"): "A young woman in her twenties",
        ("male", "adult"): "A grown man", ("female", "adult"): "A grown woman",
        ("male", "old"): "An old man in his seventies", ("female", "old"): "An old woman in her seventies",
    }.get((gender, age)) or {"child": "A child", "young": "A young adult", "old": "An elderly person"}.get(age, "An adult")
    pitch = char.get("pitch", 0)
    # Unremarkable voices get a timbre of their own, so two plain characters don't sound alike.
    timbre = TIMBRES[int(hashlib.sha1(char["id"].encode()).hexdigest(), 16) % len(TIMBRES)]
    voice = {-1: "a deep, low voice", 1: "a high, light voice"}.get(pitch, f"a {timbre} voice")
    accent = char.get("accent", "")
    text = f"{who} with {voice}"
    if accent:
        word = ACCENT_WORDS.get(accent, accent.title())
        text += f" and {'an' if word[0] in 'AEIOU' else 'a'} {word} accent"
    text += "."
    text += {-1: " Speaks slowly and deliberately.", 1: " Speaks quickly and energetically."}.get(char.get("pace", 0), "")
    summary = (char.get("summary") or "").strip()
    if summary.endswith(".") and len(summary.split()) > 5:  # Claude writes a sentence on how they sound
        text += " " + summary
    return text


def voice_for(description: str, seed: str = "", take: int = 0) -> str:
    """The voice name for a description; the clip itself is designed the first time it's spoken."""
    key = hashlib.sha1(f"{seed}|{take}|{description}".encode()).hexdigest()[:16]
    path = voices_dir() / f"{key}.json"
    if not path.exists():
        voices_dir().mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"description": description, "seed": seed, "take": take}))
    return f"qwen:{key}"


def _key(voice: str) -> str:
    key = voice.split(":", 1)[1]
    if not key.isalnum():
        raise ValueError(f"Bad voice name {voice}")
    return key


def describe(voice: str) -> dict | None:
    """Catalog entry for a designed voice, in the same shape as the other engines' voices."""
    try:
        info = json.loads((voices_dir() / f"{_key(voice)}.json").read_text())
    except (OSError, ValueError):
        return None
    return {"name": voice, "base": "Designed voice", "locale": "", "gender": "unknown", "age": "adult",
            "quality": 5, "novelty": False, "engine": "qwen", "description": info["description"]}


def designed(voice: str) -> bool:
    return (voices_dir() / f"{_key(voice)}.wav").exists()


# ---------------------------------------------------------------- synthesis
#
# MLX keeps its GPU state per thread, so every model call runs on one worker thread. Lines
# needed right now go ahead of prefetched lines, which go ahead of voices designed in advance.

URGENT, PREFETCH, BACKGROUND = 0, 1, 2
_queue: queue.PriorityQueue = queue.PriorityQueue()
_order = itertools.count()
_worker: threading.Thread | None = None
_worker_lock = threading.Lock()
_models: dict = {}
_last_design = 0.0
_queued_designs: set[str] = set()


def _submit(priority: int, fn, *args) -> Future:
    global _worker
    with _worker_lock:
        if _worker is None:
            _worker = threading.Thread(target=_work, daemon=True, name="qwen-tts")
            _worker.start()
    fut: Future = Future()
    _queue.put((priority, next(_order), fn, args, fut))
    return fut


def _work() -> None:
    while True:
        try:
            _, _, fn, args, fut = _queue.get(timeout=30)
        except queue.Empty:
            _unload_idle_designer()
            continue
        if not fut.set_running_or_notify_cancel():
            continue
        try:
            fut.set_result(fn(*args))
        except BaseException as e:  # handed back to the caller
            fut.set_exception(e)


def _model(role: str):
    if role not in _models:
        from mlx_audio.tts.utils import load_model

        _models[role] = load_model(model_dir() / role)
    return _models[role]


def _unload_idle_designer() -> None:
    if "designer" in _models and time.monotonic() - _last_design > DESIGNER_IDLE_SECONDS:
        import mlx.core as mx

        del _models["designer"]
        mx.clear_cache()


def _generate(gen) -> np.ndarray:
    import mlx.core as mx

    parts = [r.audio for r in gen]
    audio = mx.concatenate(parts) if len(parts) > 1 else parts[0]
    mx.eval(audio)
    return np.clip(np.array(audio, dtype=np.float32), -1, 1)


def _write_wav(path: Path, samples: np.ndarray) -> None:
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes((samples * 32767).astype("<i2").tobytes())


def _design(key: str) -> Path:
    global _last_design
    ref = voices_dir() / f"{key}.wav"
    if ref.exists():
        return ref
    info = json.loads((voices_dir() / f"{key}.json").read_text())
    samples = _generate(_model("designer").generate_voice_design(
        text=REFERENCE_TEXT, instruct=info["description"], language="English"))
    _last_design = time.monotonic()
    tmp = ref.with_suffix(".tmp.wav")
    _write_wav(tmp, samples)
    tmp.rename(ref)
    return ref


def _speak(out: Path, text: str, key: str) -> None:
    ref = _design(key)
    samples = _generate(_model("reader").generate(
        text=text, ref_audio=str(ref), ref_text=REFERENCE_TEXT, lang_code="english"))
    with tempfile.NamedTemporaryFile(suffix=".wav", dir=out.parent, delete=False) as tmp:
        wav = Path(tmp.name)
    _write_wav(wav, samples)
    system.encode(wav, out, SAMPLE_RATE)


def synthesize(out: Path, text: str, voice: str, urgent: bool = True) -> None:
    """Render `text` in a designed voice to an .m4a at `out` (designing the voice first if needed)."""
    _submit(URGENT if urgent else PREFETCH, _speak, out, text, _key(voice)).result()


def warm_up() -> None:
    """Load the reading model in the background, so the first line doesn't wait for it."""
    _submit(BACKGROUND, _model, "reader")


def design_ahead(voice_names: list[str]) -> None:
    """Design these voices in the background, so a character's first line doesn't wait for it."""
    for name in voice_names:
        if name.startswith("qwen:") and not designed(name) and name not in _queued_designs:
            _queued_designs.add(name)
            _submit(BACKGROUND, _design, _key(name)).add_done_callback(lambda _, n=name: _queued_designs.discard(n))
