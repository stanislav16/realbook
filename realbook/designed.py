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
import re
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
# MLX keeps memory freed by each line in a cache for reuse. Unlimited, that cache grows to over
# 13 GB on top of the model; this keeps the app at roughly model size plus the line being made.
MLX_CACHE_LIMIT = 512 * 1024 * 1024

# Words like "warm", "soft", "husky" and "rich" make Breeze's voices muffled; these keep them clear.
NARRATOR_DESCRIPTION = ("An adult woman with a bright, clear voice and a neutral American accent, "
                        "reading a story aloud with feeling.")
# Spoken by every designed voice; lines are cloned from it. It has a statement, an exclamation and
# a question, so the clone hears how this voice exclaims and asks: with a calm sample, "!" often
# came out rising like a question. A more dramatic sample fixed that but made every voice too
# excitable (and old characters sound young); listening tests chose this moderate one.
REFERENCE_TEXT = ("I have been thinking about it all morning, and I suppose I should just tell you. "
                  "It is good news, really! Would you like to hear it?")
# What voices designed before that change say in their sample; they're still cloned with it.
CALM_REFERENCE_TEXT = ("I have been thinking about it all morning, and I suppose there is no better time to tell you. "
                       "Some things are easier to say out loud than to keep to yourself.")
# Lines the narration says are whispered or muttered are read from a second sample of the same
# description, designed whispering: the clone copies a sample's energy, so this one reads them
# hushed. (Cloning the usual sample with hushed words didn't change how loud lines came out.)
QUIET_REFERENCE_TEXT = ("Shh, keep your voice down. They are sleeping in the next room, so we must be very quiet. "
                        "Come closer, and I will tell you.")
ACCENT_WORDS = {"south_african": "South African"}
TIMBRES = ["bright", "clear", "expressive", "lively", "crisp", "slightly raspy"]
# Every new voice is checked: muffled (95% of its sound below this), or a man who sounds like a woman
# or the other way round, and it's designed again. Up to DESIGN_ATTEMPTS tries; the best one is kept.
CLEAR_ROLLOFF_HZ = 1500
MALE_MAX_PITCH_HZ, FEMALE_MIN_PITCH_HZ = 160, 165
DESIGN_ATTEMPTS = 3

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
    design: Callable  # (model, description, sample text) -> generator of audio chunks
    read: Callable  # (model, text, reference clip, what the clip says) -> generator of audio chunks
    licence_note: str = ""
    speed_note: str = ""
    design_version: int = 1  # bump when design settings change, so voices are designed again
    # Re-design voices that come out muffled or the wrong pitch for their gender (Breeze needs this;
    # Qwen's voices are clear, and checking them only costs time).
    check_quality: bool = False
    styles: tuple[str, ...] = ("quiet",)  # ways of speaking it can do (see STYLES)
    fingerprint: bool = False  # cloning takes a separate speaker fingerprint (Style.keep_voice)
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
    design=lambda m, description, text=REFERENCE_TEXT: m.generate_voice_design(text=text, instruct=description, language="English"),
    read=lambda m, text, ref, ref_text: m.generate(text=text, ref_audio=str(ref), ref_text=ref_text, lang_code="english"),
    design_version=3,  # 2: an expressive sample; 3: a moderate one
    styles=("quiet", "loud", "upset"),
    fingerprint=True,
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
    # Following the description strictly (Breeze's suggested 4) makes voices muffled and "underwater";
    # 1.5 is clear and, with gender stated in the description, still follows it.
    design=lambda m, description, text=REFERENCE_TEXT: m.generate(text=text, instruct=description, cfg_scale=1.5),
    read=lambda m, text, ref, ref_text: m.generate(text=text, ref_audio=str(ref), ref_text=ref_text),
    design_version=4,  # 2: strictness 1.5 and the quality check; 3: an expressive sample; 4: a moderate one
    check_quality=True,
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
        ("male", "child"): "A ten-year-old boy", ("female", "child"): "A ten-year-old girl",
        ("male", "young"): "A young man in his twenties", ("female", "young"): "A young woman in her twenties",
        ("male", "adult"): "An adult man", ("female", "adult"): "An adult woman",
        ("male", "old"): "An elderly man in his late seventies", ("female", "old"): "An elderly woman in her late seventies",
    }.get((gender, age)) or {"child": "A child", "young": "A young adult", "old": "An elderly person"}.get(age, "An adult")
    pitch = char.get("pitch", 0)
    # How the voice sounds: from the local AI's reading of the book when there is one; otherwise
    # unremarkable voices get a timbre of their own, so two plain characters don't sound alike.
    timbre = char.get("sound") or TIMBRES[int(hashlib.sha1(char["id"].encode()).hexdigest(), 16) % len(TIMBRES)]
    # Saying "masculine" keeps men from sounding high and soft; "feminine" darkens women's voices,
    # so they get "clear" instead.
    if age == "child" and timbre == "slightly raspy":
        timbre = "lively"
    if age == "old" and not char.get("sound"):
        timbre = "weathered" if gender == "male" else "dry"  # youthful words ("crisp", "lively") made them sound young
    parts = {-1: ["deep"], 1: ["high"]}.get(pitch, [])
    if char.get("sound") or not parts:  # deep/high voices from the free analyzer stay simple
        parts.append(timbre)
    if age == "old":
        parts.append("weathered")
        if gender == "male":
            parts.append("aged")
    if gender == "male":
        parts = [re.sub(r"\bbright\b", "clear", p) for p in parts]  # "bright" makes men's voices higher
        parts.append("boyish" if age == "child" else "masculine")
    elif age == "old":
        pass  # "clear" makes old women sound young; "dry, weathered … shaky with age" won a listening test
    elif "clear" not in " ".join(parts):
        parts.append("clear")
    elif parts == ["clear"]:
        parts = ["bright", "clear"]
    voice = ", ".join(dict.fromkeys(w.strip() for p in parts for w in p.split(",") if w.strip()))  # no "deep, deep"
    voice = f"{'an' if voice[0] in 'aeiou' else 'a'} {voice} voice"
    if age == "old":  # both won listening tests against wording that only said "old"
        voice += ", slightly hoarse with age," if gender == "male" else ", slightly shaky with age,"
    accent = char.get("accent", "")
    text = f"{who} with {voice}".rstrip(",")
    if accent:
        word = ACCENT_WORDS.get(accent, accent.title())
        text = f"{who} with {voice} and {'an' if word[0] in 'AEIOU' else 'a'} {word} accent"
    # How they speak is left neutral: manners in the description ("with mocking, venomous glee") made
    # the designer act every line, and men came out cocky, shouting cartoon knights. A character
    # sounds whispered, shouted or upset only on the lines the book says so (see STYLES).
    speed = {-1: "slowly, ", 1: "quickly, "}.get(char.get("pace", 0), "")
    return f"{text}, speaking {speed}naturally and conversationally."


def voice_for(engine: Engine, description: str, seed: str = "", take: int = 0) -> str:
    """The voice name for a description; the clip itself is designed the first time it's spoken."""
    version = f"|v{engine.design_version}" if engine.design_version > 1 else ""
    key = hashlib.sha1(f"{seed}|{take}|{description}{version}".encode()).hexdigest()[:16]
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


def prune(in_use: set[str]) -> int:
    """Delete designed voices no book uses any more (they're made again if ever needed). Returns how many."""
    removed = 0
    for engine in ENGINES.values():
        for info in voices_dir(engine).glob("*.json") if voices_dir(engine).exists() else []:
            if f"{engine.name}:{info.stem}" not in in_use:
                info.unlink(missing_ok=True)
                info.with_suffix(".wav").unlink(missing_ok=True)
                for styled in info.parent.glob(f"{info.stem}-*.wav"):
                    styled.unlink(missing_ok=True)
                removed += 1
    return removed


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
_last_line = 0.0  # when a line was last asked for: background designs wait until reading is quiet
QUIET_SECONDS = 3.0
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
    import mlx.core as mx

    mx.set_cache_limit(MLX_CACHE_LIMIT)
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


def _quality(samples: np.ndarray, description: str) -> tuple[float, bool]:
    """(score, good enough): clarity, minus a penalty that grows the further the pitch is from the gender's.

    A slightly-too-high man still beats a muffled one; a man who sounds like a woman doesn't.
    """
    import re

    rolloff, pitch = _rolloff(samples), _pitch(samples)
    words = description.lower()
    # Boys and girls have high voices anyway; only grown men are checked for sounding too high.
    off = 0.0
    if re.search(r"\b(man|gentleman)\b", words) and not re.search(r"\bhigh\b", words):  # unless meant to be high
        off = max(0.0, pitch - MALE_MAX_PITCH_HZ)
    elif re.search(r"\b(woman|girl)\b", words) and pitch:
        floor = 140 if re.search(r"\b(elderly|old)\b", words) else FEMALE_MIN_PITCH_HZ  # older women speak lower
        off = max(0.0, floor - pitch)
    score = min(rolloff, 3000.0) - 15 * off  # past 3 kHz a voice is clear enough; don't trade pitch for more
    return score, rolloff >= CLEAR_ROLLOFF_HZ and off == 0


def _pitch(samples: np.ndarray) -> float:
    """Median speaking pitch in Hz, from voiced 40 ms frames (0 if none found)."""
    n, hop = int(0.04 * SAMPLE_RATE), int(0.01 * SAMPLE_RATE)
    lo, hi = SAMPLE_RATE // 400, SAMPLE_RATE // 60
    frames = [samples[i:i + n] for i in range(0, len(samples) - n, hop)]
    if not frames:
        return 0.0
    energy = np.array([np.sqrt(np.mean(f ** 2)) for f in frames])
    floor = 0.3 * np.median(energy[energy > 0]) if np.any(energy > 0) else 0
    found = []
    for f, e in zip(frames, energy):
        if e < floor:
            continue
        f = f - f.mean()
        ac = np.correlate(f, f, "full")[n - 1:]
        if ac[0] <= 0:
            continue
        lag = lo + int(np.argmax(ac[lo:hi]))
        if ac[lag] / ac[0] > 0.45:  # clearly periodic: a voiced sound
            found.append(SAMPLE_RATE / lag)
    return float(np.median(found)) if found else 0.0


def _rolloff(samples: np.ndarray) -> float:
    """The frequency below which 95% of the sound's energy lies; low means muffled."""
    power = np.abs(np.fft.rfft(samples)) ** 2
    freqs = np.fft.rfftfreq(len(samples), 1 / SAMPLE_RATE)
    cum = np.cumsum(power)
    return float(freqs[np.searchsorted(cum, 0.95 * cum[-1])]) if cum[-1] > 0 else 0.0


def _write_wav(path: Path, samples: np.ndarray) -> None:
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes((np.clip(samples, -1, 1) * 32767).astype("<i2").tobytes())


# Voices partway through their tries: key -> (best samples so far, its score, tries made).
_candidates: dict[str, tuple[np.ndarray, float, int]] = {}


def _design_try(engine: Engine, key: str) -> bool:
    """Make one try at a voice. True once it's finished (saved), False if another try is wanted.

    Designing is random: now and then a voice comes out muffled, or a man sounds like a woman.
    Engines that check quality try again, up to DESIGN_ATTEMPTS times, and keep the best.
    """
    global _last_design
    ref = voices_dir(engine) / f"{key}.wav"
    if ref.exists():
        return True
    description = json.loads((voices_dir(engine) / f"{key}.json").read_text())["description"]
    samples = _generate(engine.design(_model(engine, engine.design_role), description))
    _last_design = time.monotonic()
    score, good = _quality(samples, description) if engine.check_quality else (0.0, True)
    best, best_score, tries = _candidates.get(key, (samples, score, 0))
    if score >= best_score:
        best, best_score = samples, score
    tries += 1
    if not good and tries < DESIGN_ATTEMPTS:
        _candidates[key] = (best, best_score, tries)
        return False
    _candidates.pop(key, None)
    info_path = voices_dir(engine) / f"{key}.json"
    info = json.loads(info_path.read_text())
    info["reference_text"] = REFERENCE_TEXT  # cloning must use exactly what the sample says
    info_path.write_text(json.dumps(info))
    tmp = ref.with_suffix(".tmp.wav")
    _write_wav(tmp, best)
    tmp.rename(ref)
    return True


def _design(engine: Engine, key: str) -> Path:
    """The voice's reference clip, designing it now if needed (all its tries at once)."""
    while not _design_try(engine, key):
        pass
    return voices_dir(engine) / f"{key}.wav"


def _design_in_background(engine: Engine, name: str) -> None:
    """One try, then back in the queue: a line someone is waiting for can go first between tries.

    While lines are being asked for, it doesn't start at all: a try takes 8-25 seconds and can't
    be interrupted, so it would hold up the line being waited for.
    """
    if time.monotonic() - _last_line < QUIET_SECONDS:
        threading.Timer(1.0, _submit, args=(BACKGROUND, _design_in_background, engine, name)).start()
        return
    if _design_try(engine, _key(name)):
        _queued_designs.discard(name)
    else:
        _submit(BACKGROUND, _design_in_background, engine, name)


@dataclass(frozen=True)
class Style:
    """A way of speaking the narration asks for ("he whispered", "she shouted"), read from a second
    sample of the voice's description designed that way: the clone copies a sample's energy."""
    ending: str  # replaces the description's ", speaking …" part
    text: str  # what the sample says, in that mood
    attempts: int = 1
    score: Callable | None = None  # (sample, usual sample) -> higher is better; tries stop once it's >= 0
    # Keep the usual sample's speaker fingerprint and take only the delivery from the styled one:
    # otherwise shouting or crying sounds like someone else (Qwen only).
    keep_voice: bool = False
    # Clone from the usual sample followed by the styled one, rather than the styled one alone. For
    # whispers the fingerprint by itself wasn't enough (Piter came out shouting); joined, a listening
    # test heard Jessica whisper in her own voice.
    join: bool = False
    deep_ending: str = ""  # used instead of `ending` for voices described as deep
    # Each line is checked against the usual voice: no more than MAX_PITCH_RISE higher, and the
    # same speaker by fingerprint. A line that fails is made again, then read as usual.
    check_line: bool = False
    version: int = 1  # bump when the style's sample changes, so samples and lines are made again


STYLES = {
    # About half of whisper designs come out spoken: a real whisper is mostly breath, at most half
    # of it with a pitch (normal speech: ~75%).
    "quiet": Style(", whispering quietly and secretively.", QUIET_REFERENCE_TEXT, attempts=4,
                   score=lambda s, usual: 0.5 - _voiced(s), keep_voice=True, join=True),
    # Shouting samples came out two to three times higher than the voice (the Baron's 90 Hz voice
    # shouted at 300 Hz, like someone else): a sample must be at least 3 dB louder and at most
    # 1.8 times higher, and deep voices are asked to bellow instead.
    "loud": Style(", shouting loudly and forcefully.",
                  "Enough! I will not be kept waiting. Bring him to me, now! Do you hear me? Now!",
                  attempts=4, score=lambda s, usual: min(_loudness(s) - _loudness(usual) - 3, 10 * (1.8 - _pitch_rise(s, usual))),
                  keep_voice=True, deep_ending=", bellowing angrily in a deep, booming voice.", check_line=True, version=2),
    "upset": Style(", speaking in a shaky, tearful, upset voice.",
                   "Please, please don't go. I can't do this without you. I'm so sorry, I never meant for any of this to happen.",
                   keep_voice=True, check_line=True),
}
QUIET_DB = 6  # whispered lines are at least this much quieter than the voice's usual sample


def style_description(description: str, style: str) -> str:
    """The same voice in another mood: "An adult woman with a clear, poised voice, whispering quietly and secretively." """
    first = description.split(". ")[0].split(", speaking")[0].rstrip(". ")
    how = STYLES[style]
    return first + (how.deep_ending if how.deep_ending and re.search(r"\bdeep\b", first) else how.ending)


def style_tag(style: str) -> str:
    """`style` with its version, for naming samples and cached lines ("loud2")."""
    version = STYLES[style].version if style in STYLES else 1
    return style if version == 1 else f"{style}{version}"


def _style_path(engine: Engine, key: str, style: str) -> Path:
    return voices_dir(engine) / f"{key}-{style_tag(style)}.wav"


MAX_PITCH_RISE = 1.7
MIN_LIKENESS = 0.96


def _median_pitch(samples: np.ndarray) -> float:
    found = [p for p in (_pitch(samples[i:i + 2048]) for i in range(0, len(samples) - 2048, 1200)) if p > 0]
    return float(np.median(found)) if found else 0.0


def _pitch_rise(samples: np.ndarray, usual: np.ndarray) -> float:
    base = _median_pitch(usual)
    return _median_pitch(samples) / base if base else 1.0


def supports(voice: str, style: str) -> bool:
    engine = engine_of(voice)
    return bool(engine) and style in engine.styles


def _voiced(samples: np.ndarray) -> float:
    """The share of the clip that has a pitch (voiced speech, not breath or silence)."""
    starts = range(0, len(samples) - 2048, 1200)
    return sum(_pitch(samples[i:i + 2048]) > 0 for i in starts) / max(1, len(starts))


def _loudness(samples: np.ndarray) -> float:
    return float(20 * np.log10(np.sqrt(np.mean(samples ** 2)) + 1e-9))


def _read_wav(path: Path) -> np.ndarray:
    with wave.open(str(path)) as w:
        return np.frombuffer(w.readframes(w.getnframes()), "<i2").astype(np.float32) / 32768


def _design_style(engine: Engine, key: str, style: str) -> Path:
    """The voice's sample for `style`, designed the first time a line needs it. Designing is random,
    so styles with a check try up to `attempts` times and keep the best."""
    ref = _style_path(engine, key, style)
    if not ref.exists():
        how = STYLES[style]
        description = style_description(json.loads((voices_dir(engine) / f"{key}.json").read_text())["description"], style)
        usual = _read_wav(_design(engine, key))
        best, best_score = None, -1e9
        for _ in range(how.attempts):
            samples = _generate(engine.design(_model(engine, engine.design_role), description, how.text))
            score = how.score(samples, usual) if how.score else 0.0
            if score > best_score:
                best, best_score = samples, score
            if score >= 0:
                break
        tmp = ref.with_suffix(".tmp.wav")
        _write_wav(tmp, best)
        tmp.rename(ref)
    return ref


def _speak(engine: Engine, out: Path, text: str, key: str, style: str = "") -> None:
    global _last_line
    try:
        _speak_line(engine, out, text, key, style)
    finally:
        _last_line = time.monotonic()  # quiet is measured from when a line finished


def _speak_line(engine: Engine, out: Path, text: str, key: str, style: str = "") -> None:
    ref = _design(engine, key)
    info = json.loads((voices_dir(engine) / f"{key}.json").read_text())
    ref_text = info.get("reference_text", CALM_REFERENCE_TEXT)  # voices made before samples were recorded with it
    usual = ref
    model = _model(engine, engine.read_role)
    if style in engine.styles:
        ref, ref_text = _design_style(engine, key, style), STYLES[style].text
        if STYLES[style].join and engine.fingerprint:
            joined = voices_dir(engine) / f"{key}-{style_tag(style)}-joined.wav"
            if not joined.exists():
                gap = np.zeros(int(0.4 * SAMPLE_RATE), np.float32)
                _write_wav(joined, np.concatenate([_read_wav(usual), gap, _read_wav(ref)]))
            ref, ref_text = joined, f"{info.get('reference_text', CALM_REFERENCE_TEXT)} {ref_text}"
    styled = style in engine.styles and STYLES[style].keep_voice and engine.fingerprint
    usual_text = info.get("reference_text", CALM_REFERENCE_TEXT)

    def generate() -> np.ndarray:
        if not styled:
            return _generate(engine.read(model, text, ref, ref_text))
        import mlx.core as mx

        fingerprint = model.extract_speaker_embedding
        model.extract_speaker_embedding = lambda audio, sr=24000: fingerprint(mx.array(_read_wav(usual)), sr)
        try:
            return _generate(engine.read(model, text, ref, ref_text))
        finally:
            model.extract_speaker_embedding = fingerprint

    samples = generate()
    if styled and STYLES[style].check_line:
        # A shouted or upset line can still come out as someone else (higher, another accent): it's
        # made again, and if it still isn't them, read in the usual voice.
        import mlx.core as mx

        usual_samples = _read_wav(usual)
        print_of = lambda s: np.array(model.extract_speaker_embedding(mx.array(s))).ravel()
        mine = print_of(usual_samples)

        def same_person(s: np.ndarray) -> bool:
            other = print_of(s)
            likeness = float(other @ mine / (np.linalg.norm(other) * np.linalg.norm(mine) + 1e-9))
            return _pitch_rise(s, usual_samples) <= MAX_PITCH_RISE and likeness >= MIN_LIKENESS

        for _ in range(STYLE_RETRIES):
            if same_person(samples):
                break
            samples = generate()
        else:
            if not same_person(samples):
                styled, ref, ref_text = False, usual, usual_text
                samples = generate()

    # About one line in six stops while its last sound is still going (the model ends a frame too
    # soon), which sounds clipped. Those are made again, up to twice, keeping the cleanest ending.
    for _ in range(CUT_RETRIES):
        if _ending(samples) <= CUT_DB:
            break
        again = generate()
        if _ending(again) < _ending(samples):
            samples = again
    if style == "quiet" and style in engine.styles:
        over = _loudness(samples) - (_loudness(_read_wav(usual)) - QUIET_DB)
        if over > 0:
            samples = samples * 10 ** (-over / 20)
    with tempfile.NamedTemporaryFile(suffix=".wav", dir=out.parent, delete=False) as tmp:
        wav = Path(tmp.name)
    _write_wav(wav, _tidy_ends(samples))
    system.encode(wav, out, SAMPLE_RATE)


STYLE_RETRIES = 2
CUT_RETRIES = 2
CUT_DB = -30  # the last 20 ms louder than this (against the loudest 20 ms) means it stopped mid-sound
FADE_IN_MS, FADE_OUT_MS, TAIL_MS = 5, 40, 40


def _ending(samples: np.ndarray) -> float:
    """How loud the last 20 ms are, in dB against the loudest 20 ms of the line."""
    frame = SAMPLE_RATE // 50
    n = len(samples) // frame
    if n < 2:
        return -100.0
    rms = np.sqrt(np.mean(samples[:n * frame].reshape(n, frame) ** 2, axis=1)) + 1e-9
    return float(20 * np.log10(rms[-1] / rms.max()))


def _tidy_ends(samples: np.ndarray) -> np.ndarray:
    """A short fade at each end and a moment of silence after: a line that stops dead clicks, and the
    audio encoder smears a click into noise at the end of the line."""
    samples = samples.astype(np.float32).copy()
    fin, fout = SAMPLE_RATE * FADE_IN_MS // 1000, min(len(samples) // 4, SAMPLE_RATE * FADE_OUT_MS // 1000)
    samples[:fin] *= np.linspace(0, 1, fin, dtype=np.float32)
    if fout:
        samples[-fout:] *= np.linspace(1, 0, fout, dtype=np.float32) ** 2
    return np.concatenate([samples, np.zeros(SAMPLE_RATE * TAIL_MS // 1000, np.float32)])


def synthesize(out: Path, text: str, voice: str, urgent: bool = True, style: str = "") -> None:
    """Render `text` in a designed voice to an audio file at `out` (designing the voice first if needed).
    `style` ("quiet", "loud", "upset") reads it from the voice's sample designed that way."""
    global _last_line
    _last_line = time.monotonic()
    _submit(URGENT if urgent else PREFETCH, _speak, engine_of(voice), out, text, _key(voice), style).result()


def warm_up(engine: Engine) -> None:
    """Load the reading model in the background, so the first line doesn't wait for it."""
    _submit(BACKGROUND, _model, engine, engine.read_role)


def _style_in_background(engine: Engine, name: str, style: str) -> None:
    if time.monotonic() - _last_line < QUIET_SECONDS:
        threading.Timer(1.0, _submit, args=(BACKGROUND, _style_in_background, engine, name, style)).start()
        return
    try:
        _design_style(engine, _key(name), style)
    finally:
        _queued_designs.discard(f"{name}-{style}")


def design_styles_ahead(wanted: list[tuple[str, str]]) -> None:
    """Design these (voice, style) samples in the background, before a whispered or shouted line needs one."""
    for name, style in wanted:
        engine = engine_of(name)
        if (engine and style in engine.styles and not _style_path(engine, _key(name), style).exists()
                and f"{name}-{style}" not in _queued_designs):
            _queued_designs.add(f"{name}-{style}")
            _submit(BACKGROUND, _style_in_background, engine, name, style)


def design_ahead(voice_names: list[str]) -> None:
    """Design these voices in the background, so a character's first line doesn't wait for it."""
    for name in voice_names:
        engine = engine_of(name)
        if engine and not designed(name) and name not in _queued_designs:
            _queued_designs.add(name)
            _submit(BACKGROUND, _design_in_background, engine, name).add_done_callback(
                lambda f, n=name: f.exception() and _queued_designs.discard(n))
