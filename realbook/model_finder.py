"""Find text-to-speech models on Hugging Face, to see whether a better voice engine has come out.

Results are flagged with what matters for RealBook: whether the model can design voices from a
description or clone them, its licence, and whether a port for Apple silicon (MLX) exists.
"""

from __future__ import annotations

import json
import re
import time
import urllib.parse

from . import system

API = "https://huggingface.co/api/models"
SORTS = {"trending": "trendingScore", "likes": "likes", "downloads": "downloads", "new": "createdAt"}
# Models RealBook already uses, by the start of their repository name.
IN_REALBOOK = {"hexgrad/kokoro": "Kokoro", "qwen/qwen3-tts": "Qwen3-TTS", "breezeblue/breeze-tts-2": "Breeze-TTS-2"}
FEATURES = {
    "voice-design": "Voice design", "voice-cloning": "Voice cloning", "voice-clone": "Voice cloning",
    "emotional-speech-generation": "Emotion", "voice-direction": "Emotion", "multi-speaker": "Multi-speaker",
    "streaming": "Streaming", "on-device": "On-device",
}

_cache: dict[str, tuple[float, object]] = {}


def _get(params: dict) -> list[dict]:
    url = f"{API}?{urllib.parse.urlencode(params, doseq=True)}"
    hit = _cache.get(url)
    if hit and time.monotonic() - hit[0] < 600:
        return hit[1]
    # System curl uses the macOS certificate store, which a bundled Python may not have.
    out = system.run([system.curl(), "-sS", "--fail", "--max-time", "20", url], capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError("Couldn't reach Hugging Face. Check your internet connection.")
    data = json.loads(out.stdout)
    _cache[url] = (time.monotonic(), data)
    return data


def _base(model_id: str) -> str:
    """'mlx-community/Qwen3-TTS-12Hz-0.6B-Base-bf16' -> 'qwen3-tts-12hz-0.6b-base' (for matching ports)."""
    name = model_id.split("/")[-1].lower()
    return re.sub(r"[-_.]?(bf16|fp16|fp32|f16|\d+bit|q\d.*|mlx|onnx|gguf)$", "", name)


def _mlx_ports() -> set[str]:
    try:
        ports = _get({"author": "mlx-community", "pipeline_tag": "text-to-speech", "limit": 1000})
    except RuntimeError:
        return set()
    return {_base(m["id"]) for m in ports}


def search(query: str = "", sort: str = "trending", english: bool = True, limit: int = 30) -> list[dict]:
    params = {"pipeline_tag": "text-to-speech", "sort": SORTS.get(sort, "trendingScore"), "limit": limit * 2,
              "full": "false", "config": "false"}
    if query:
        params["search"] = query
    models = _get(params)
    ports = _mlx_ports()
    out = []
    for m in models:
        tags = m.get("tags", [])
        langs = {t for t in tags if re.fullmatch(r"[a-z]{2}", t)}
        if english and langs and "en" not in langs:
            continue
        if m["id"].startswith("mlx-community/"):
            continue  # ports are shown as a badge on the original model
        licence = next((t.split(":", 1)[1] for t in tags if t.startswith("license:")), "unknown")
        used = next((name for prefix, name in IN_REALBOOK.items() if m["id"].lower().startswith(prefix)), None)
        base = _base(m["id"])
        out.append({
            "id": m["id"],
            "url": f"https://huggingface.co/{m['id']}",
            "likes": m.get("likes", 0),
            "downloads": m.get("downloads", 0),
            "created": m.get("createdAt"),
            "updated": m.get("lastModified"),
            "licence": licence,
            "gated": bool(m.get("gated")),
            "features": sorted({label for tag, label in FEATURES.items() if tag in tags}),
            "languages": len(langs),
            "mlx": any(p == base or p.startswith(base + "-") for p in ports),
            "in_realbook": used,
        })
        if len(out) >= limit:
            break
    return out
