"""Designed voices: open-source speech models that make a voice from a written description, offline
on Apple silicon. Two engines share this module:

- Qwen3-TTS: a 1.7B VoiceDesign model designs each voice, a 0.6B Base model reads every line.
  About 2× faster than real time on an M5. Apache 2.0.
- Breeze-TTS-2: one 3B model (8-bit) does both. About as fast as real time on an M5, and rated
  higher for quality. Its licence allows research and non-commercial use only.

Each character's voice is designed once from a description ("an old Scottish man with a deep,
gravelly voice") as a short reference clip. Every line they speak is then cloned from that clip,
so the voice stays the same from line to line. Voices are named `<engine>:<key>`; the description
behind each key lives in models/<engine>/voices/<key>.json and its reference clip in <key>.wav.
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
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

import numpy as np

from . import store, system

HF = "https://huggingface.co"
SAMPLE_RATE = 24000
DESIGNER_IDLE_SECONDS = 120  # a separate design model is unloaded when no new voices are being made

NARRATOR_DESCRIPTION = ("A warm, clear adult female narrator with a calm, measured, storytelling delivery "
                        "and a neutral American accent.")
# Spoken by every designed voice; lines are cloned from it.
REFERENCE_TEXT = ("I have been thinking about it all morning, and I suppose there is no better time to tell you. "
                  "Some things are easier to say out loud than to keep to yourself.")
ACCENT_WORDS = {"south_african": "South African"}
TIMBRES = ["warm", "bright", "husky", "smooth", "crisp", "rich", "soft", "slightly raspy"]

# Files the Qwen models share byte for byte (tokenizers and the audio codec).
_QWEN_SHARED = {
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


@dataclass(frozen=True)
class Engine:
    name: str
    label: str
    # role -> (Hugging Face repository, pinned revision, {file: (bytes, sha256)})
    models: dict[str, tuple[str, str, dict[str, tuple[int, str]]]]
    design_role: str
    read_role: str
    design: Callable  # (model, description) -> generator of audio chunks
    read: Callable  # (model, text, reference clip) -> generator of audio chunks
    licence_note: str = ""
    speed_note: str = ""
    install: dict = field(default_factory=lambda: {"state": "idle", "progress": 0.0, "message": ""})

    def files(self) -> list[tuple[str, str, str, int, str]]:
        """(role, repo, revision, file, bytes, sha256) for every file to install."""
        return [(role, repo, rev, name, size, sha) for role, (repo, rev, files) in self.models.items()
                for name, (size, sha) in files.items()]

    @property
    def download_bytes(self) -> int:
        return sum({sha: size for *_, size, sha in self.files()}.values())  # identical files are fetched once


QWEN = Engine(
    name="qwen", label="Designed voices (Qwen3-TTS)",
    models={
        "designer": ("mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16", "7d3824abff87e49756bb0f83fb5411de75d160c4", {
            "model.safetensors": (3833402589, "96ae28bec2205ec0b5e0c750bea2b8a5deac4f14d33a8a25a5f753299486b70e"),
            "model.safetensors.index.json": (32458, "abf019e063dcc595d7aef7c9554d2806ffdc58746a7ac6238cb26177af8d431f"),
            "config.json": (5232, "8a9be83c045ee9ab9d2e6609655f547b9291a070f5acae3428c3ff07a365de40"),
            **_QWEN_SHARED,
        }),
        "reader": ("mlx-community/Qwen3-TTS-12Hz-0.6B-Base-bf16", "1eccf1cb2519b5a4e8a95b5f0544f3303568164f", {
            "model.safetensors": (1829344448, "d7c7ed3e3464e3e59de0f955b3755891fa8319ff061c3f0307fe2e1343bc122d"),
            "model.safetensors.index.json": (38573, "e02433c97b2894586e8842af2b40381c5bb644bc1c6bf71a6a52a727efe92313"),
            "config.json": (5317, "ee1871ab778c89645f8806df736cb35958619c40276598a41aeaa014615656a4"),
            **_QWEN_SHARED,
        }),
    },
    design_role="designer", read_role="reader",
    design=lambda m, description: m.generate_voice_design(text=REFERENCE_TEXT, instruct=description, language="English"),
    read=lambda m, text, ref: m.generate(text=text, ref_audio=str(ref), ref_text=REFERENCE_TEXT, lang_code="english"),
    speed_note="About twice as fast as listening on a recent Mac.",
)

BREEZE = Engine(
    name="breeze", label="Designed voices (Breeze-TTS-2)",
    models={
        "model": ("mlx-community/Breeze-TTS-2-mlx-8bit", "c6e4a2ff6ab9afba68b7853de802273ffe23fb49", {
            "LICENSE": (18856, "2a143ae167cb0253d95bafa694e415570dcce336d712230d205c538523bbd855"),
            "NOTICE": (146, "70bc248b98e5bb527f160c86be56d60ef8c63776c43051273643db036ebee40d"),
            "audio_tokenizer/config.json": (2336, "ee65bb901c876664ab8707c487157aa1a6ee57c65969b28fb5ec9dc211e68167"),
            "audio_tokenizer/configuration.json": (76, "6bc26d64eb5024b4d1dab5a52371958b429256d6c9d59787f1f5294a54e0cebd"),
            "audio_tokenizer/model.safetensors": (682293092, "836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258"),
            "audio_tokenizer/preprocessor_config.json": (234, "fcb3805e597e786d4067706e602f6688524640f8d3396790e2e09b5942fcbdfb"),
            "config.json": (12379, "91cf471c3a9bd00e61046a5e08dce22967f161e75488d21b128026154111be65"),
            "generation_config.json": (251, "2ef3f2c0ab8d9ad241059138a795433c5410fd9954efb9625674ecd2a9529434"),
            "model.safetensors": (3885721536, "d7a82315bcc59c3057f13bb85100743c7cd40692e38145fb255d6c1f0bf447bc"),
            "model.safetensors.index.json": (98863, "113da60084ed077d67dd99706e5619f4c40056d777225923302cb957b3677026"),
            "special_tokens_map.json": (886, "194f265bb588d142a16f27d9576104eb3dab3d7ba9961541d2d6e3d5e77e6470"),
            "tokenizer.json": (33386945, "d3ec9ac3eb2392389b9f5112e85d8b43316494addb587ba7b7a9d61eac23af96"),
            "tokenizer_config.json": (1157960, "2c084fd6725c2284e8aa6da095a8d036d48fe79665595bfcd50371821b620e44"),
        }),
    },
    design_role="model", read_role="model",
    design=lambda m, description: m.generate(text=REFERENCE_TEXT, instruct=description, cfg_scale=4.0),
    read=lambda m, text, ref: m.generate(text=text, ref_audio=str(ref), ref_text=REFERENCE_TEXT),
    licence_note=("Breeze-TTS-2's licence allows research and non-commercial use only: fine for listening to "
                  "your own books, but don't sell or publish what it makes."),
    speed_note="About as fast as listening on a recent Mac, so playback faster than 1× may pause between lines.",
)

ENGINES = {e.name: e for e in (QWEN, BREEZE)}

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


def engine_of(voice: str) -> Engine | None:
    return ENGINES.get(voice.split(":", 1)[0]) if ":" in voice else None


def model_dir(engine: Engine) -> Path:
    return store.DATA_DIR / "models" / engine.name


def voices_dir(engine: Engine) -> Path:
    return model_dir(engine) / "voices"


def installed(engine: Engine) -> bool:
    return supported() and all((model_dir(engine) / role / name).exists() for role, _, _, name, _, _ in engine.files())


# ------------------------------------------------------------------ download

_install_lock = threading.Lock()


def install_status(engine: Engine) -> dict:
    return {"installed": installed(engine), "supported": supported(), "bytes": engine.download_bytes,
            "label": engine.label, "licence": engine.licence_note, "speed": engine.speed_note, **engine.install}


def install_async(engine: Engine, on_done=None) -> dict:
    with _install_lock:
        if engine.install["state"] == "downloading" or installed(engine) or not supported():
            return install_status(engine)
        engine.install.update(state="downloading", progress=0.0, message="Starting download…")
    threading.Thread(target=_download, args=(engine, on_done), daemon=True).start()
    return install_status(engine)


def _download(engine: Engine, on_done) -> None:
    status, total = engine.install, engine.download_bytes
    done_bytes = 0
    have: dict[str, Path] = {}  # sha256 -> a finished file, to link instead of downloading twice
    try:
        for role, repo, rev, name, size, sha in engine.files():
            target = model_dir(engine) / role / name
            target.parent.mkdir(parents=True, exist_ok=True)
            if not target.exists():
                status["message"] = f"Preparing voices… {int(100 * status['progress'])}%"
                source = have.get(sha) or _hf_cache_copy(repo, rev, name, size, sha)
                if source and source.stat().st_dev == target.parent.stat().st_dev:
                    os.link(source, target)
                elif source:
                    shutil.copy(source, target)
                else:
                    _fetch(status, f"{HF}/{repo}/resolve/{rev}/{name}", target, size, sha, done_bytes, total)
            if sha not in have:
                have[sha] = target
                done_bytes += size
            status["progress"] = min(1.0, done_bytes / total)
        status.update(state="done", progress=1.0, message="Voices installed")
        if on_done:
            on_done()
    except Exception as e:  # surfaced to the UI
        status.update(state="error", message=str(e))


def _hf_cache_copy(repo: str, rev: str, name: str, size: int, sha: str) -> Path | None:
    """The same file from an earlier Hugging Face download on this Mac, if there is one."""
    p = Path.home() / ".cache" / "huggingface" / "hub" / f"models--{repo.replace('/', '--')}" / "snapshots" / rev / name
    try:
        p = p.resolve(strict=True)
    except OSError:
        return None
    return p if p.stat().st_size == size and _sha256(p) == sha else None


def _fetch(status: dict, url: str, target: Path, size: int, sha: str, done_bytes: int, total: int) -> None:
    part = target.with_name(target.name + ".part")
    # System curl uses the macOS certificate store, which a bundled Python may not have.
    proc = system.popen([system.curl(), "-sSL", "--fail", "--retry", "3", "-C", "-", "-o", str(part), url],
                        stderr=subprocess.PIPE, text=True)
    while proc.poll() is None:
        got = part.stat().st_size if part.exists() else 0
        status["progress"] = (done_bytes + got) / total
        status["message"] = f"Downloading voices… {int(100 * status['progress'])}%"
        time.sleep(0.4)
    if proc.returncode != 0:
        raise RuntimeError(f"Download failed: {proc.stderr.read().strip() or 'network error'}")
    if part.stat().st_size != size:
        part.unlink()
        raise RuntimeError(f"{target.name} downloaded incompletely; please try again")
    status["message"] = "Checking the download…"
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


def voice_for(engine: Engine, description: str, seed: str = "", take: int = 0) -> str:
    """The voice name for a description; the clip itself is designed the first time it's spoken."""
    key = hashlib.sha1(f"{seed}|{take}|{description}".encode()).hexdigest()[:16]
    path = voices_dir(engine) / f"{key}.json"
    if not path.exists():
        voices_dir(engine).mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"description": description, "seed": seed, "take": take}))
    return f"{engine.name}:{key}"


def _key(voice: str) -> str:
    key = voice.split(":", 1)[1]
    if not key.isalnum():
        raise ValueError(f"Bad voice name {voice}")
    return key


def describe(voice: str) -> dict | None:
    """Catalog entry for a designed voice, in the same shape as the other engines' voices."""
    engine = engine_of(voice)
    try:
        info = json.loads((voices_dir(engine) / f"{_key(voice)}.json").read_text())
    except (OSError, ValueError, TypeError):
        return None
    return {"name": voice, "base": "Designed voice", "locale": "", "gender": "unknown", "age": "adult",
            "quality": 5, "novelty": False, "engine": engine.name, "description": info["description"]}


def designed(voice: str) -> bool:
    return (voices_dir(engine_of(voice)) / f"{_key(voice)}.wav").exists()


# ---------------------------------------------------------------- synthesis
#
# MLX keeps its GPU state per thread, so every model call, for either engine, runs on one worker
# thread. Lines needed right now go ahead of prefetched lines, which go ahead of voices designed
# in advance.

URGENT, PREFETCH, BACKGROUND = 0, 1, 2
_queue: queue.PriorityQueue = queue.PriorityQueue()
_order = itertools.count()
_worker: threading.Thread | None = None
_worker_lock = threading.Lock()
_models: dict[tuple[str, str], object] = {}
_last_design = 0.0
_queued_designs: set[str] = set()


def _submit(priority: int, fn, *args) -> Future:
    global _worker
    with _worker_lock:
        if _worker is None:
            _worker = threading.Thread(target=_work, daemon=True, name="designed-voices")
            _worker.start()
    fut: Future = Future()
    _queue.put((priority, next(_order), fn, args, fut))
    return fut


def _work() -> None:
    while True:
        try:
            _, _, fn, args, fut = _queue.get(timeout=30)
        except queue.Empty:
            _unload_idle()
            continue
        if not fut.set_running_or_notify_cancel():
            continue
        try:
            fut.set_result(fn(*args))
        except BaseException as e:  # handed back to the caller
            fut.set_exception(e)


def _model(engine: Engine, role: str):
    if (engine.name, role) not in _models:
        from mlx_audio.tts.utils import load_model

        # Only one engine's models stay in memory at a time.
        for loaded in [k for k in _models if k[0] != engine.name]:
            del _models[loaded]
        _models[engine.name, role] = load_model(model_dir(engine) / role)
    return _models[engine.name, role]


def _unload_idle() -> None:
    """Free separate design models (Qwen's 1.7B) when no new voices have been made for a while."""
    if time.monotonic() - _last_design < DESIGNER_IDLE_SECONDS:
        return
    idle = [k for k in _models if k[1] == ENGINES[k[0]].design_role != ENGINES[k[0]].read_role]
    if idle:
        import mlx.core as mx

        for k in idle:
            del _models[k]
        mx.clear_cache()


def _generate(gen) -> np.ndarray:
    import mlx.core as mx

    parts = [r.audio for r in gen]
    audio = mx.concatenate(parts) if len(parts) > 1 else parts[0]
    mx.eval(audio)
    return np.clip(np.array(audio, dtype=np.float32).ravel(), -1, 1)


def _write_wav(path: Path, samples: np.ndarray) -> None:
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes((samples * 32767).astype("<i2").tobytes())


def _design(engine: Engine, key: str) -> Path:
    global _last_design
    ref = voices_dir(engine) / f"{key}.wav"
    if ref.exists():
        return ref
    info = json.loads((voices_dir(engine) / f"{key}.json").read_text())
    samples = _generate(engine.design(_model(engine, engine.design_role), info["description"]))
    _last_design = time.monotonic()
    tmp = ref.with_suffix(".tmp.wav")
    _write_wav(tmp, samples)
    tmp.rename(ref)
    return ref


def _speak(engine: Engine, out: Path, text: str, key: str) -> None:
    ref = _design(engine, key)
    samples = _generate(engine.read(_model(engine, engine.read_role), text, ref))
    with tempfile.NamedTemporaryFile(suffix=".wav", dir=out.parent, delete=False) as tmp:
        wav = Path(tmp.name)
    _write_wav(wav, samples)
    system.encode(wav, out, SAMPLE_RATE)


def synthesize(out: Path, text: str, voice: str, urgent: bool = True) -> None:
    """Render `text` in a designed voice to an audio file at `out` (designing the voice first if needed)."""
    _submit(URGENT if urgent else PREFETCH, _speak, engine_of(voice), out, text, _key(voice)).result()


def warm_up(engine: Engine) -> None:
    """Load the reading model in the background, so the first line doesn't wait for it."""
    _submit(BACKGROUND, _model, engine, engine.read_role)


def design_ahead(voice_names: list[str]) -> None:
    """Design these voices in the background, so a character's first line doesn't wait for it."""
    for name in voice_names:
        engine = engine_of(name)
        if engine and not designed(name) and name not in _queued_designs:
            _queued_designs.add(name)
            _submit(BACKGROUND, _design, engine, _key(name)).add_done_callback(
                lambda _, n=name: _queued_designs.discard(n))
