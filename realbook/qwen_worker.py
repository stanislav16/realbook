"""Runs Qwen3-TTS on an NVIDIA graphics card, for RealBook on Linux. It runs under its own Python
(see qwen_pc.py), because PyTorch is several gigabytes and only these computers need it, and it
takes one JSON request per line on stdin and answers one JSON line on stdout. Audio goes through
.npy files.
"""

import json
import os
import sys

# Libraries print to stdout: keep it for the answers.
_answers = os.fdopen(os.dup(1), "w")
os.dup2(2, 1)

import numpy as np  # noqa: E402
import torch  # noqa: E402
from qwen_tts import Qwen3TTSModel  # noqa: E402

DEVICE = os.environ.get("REALBOOK_QWEN_DEVICE", "cuda:0")
SAMPLE_RATE = 24000
MAX_NEW_TOKENS = 2048

_models = {}
_prompts = {}


def _load(role, path):
    if role not in _models:
        dtype = torch.bfloat16 if DEVICE.startswith("cuda") else torch.float32
        _models[role] = Qwen3TTSModel.from_pretrained(path, device_map=DEVICE, dtype=dtype, attn_implementation="sdpa")
    return _models[role]


def _unload(role):
    if _models.pop(role, None) is not None:
        _prompts.clear()
        if torch.cuda.is_available():
            torch.cuda.empty_cache()


def _save(wav, sr, out):
    if sr != SAMPLE_RATE:
        raise RuntimeError(f"Unexpected sample rate {sr}")
    np.save(out, np.asarray(wav, dtype=np.float32).ravel())


def _prompt(model, ref, ref_text, speaker_from):
    """Reading a sample once per voice saves that work on every line."""
    key = (ref, ref_text, speaker_from)
    if key not in _prompts:
        if len(_prompts) >= 64:
            _prompts.clear()
        items = model.create_voice_clone_prompt(ref_audio=ref, ref_text=ref_text, x_vector_only_mode=False)
        if speaker_from:  # how it's said from this sample, who says it from the voice's usual one
            usual = model.create_voice_clone_prompt(ref_audio=speaker_from, x_vector_only_mode=True)
            items[0].ref_spk_embedding = usual[0].ref_spk_embedding
        _prompts[key] = items
    return _prompts[key]


def _handle(r):
    do = r["do"]
    if do == "load":
        _load(r["role"], r["path"])
    elif do == "unload":
        _unload(r["role"])
    elif do == "design":
        wavs, sr = _load(r["role"], r["path"]).generate_voice_design(text=r["text"], instruct=r["instruct"], language=r["language"],
                                                                     max_new_tokens=MAX_NEW_TOKENS)
        _save(wavs[0], sr, r["out"])
    elif do == "read":
        model = _load(r["role"], r["path"])
        wavs, sr = model.generate_voice_clone(text=r["texts"], language=r["language"], max_new_tokens=MAX_NEW_TOKENS,
                                              voice_clone_prompt=_prompt(model, r["ref"], r["ref_text"], r.get("speaker_from")))
        for wav, out in zip(wavs, r["out"]):
            _save(wav, sr, out)
    elif do == "embed":
        model = _load(r["role"], r["path"])
        items = model.create_voice_clone_prompt(ref_audio=(np.load(r["audio"]), SAMPLE_RATE), x_vector_only_mode=True)
        return {"embedding": items[0].ref_spk_embedding.float().cpu().numpy().ravel().tolist()}
    elif do == "check":
        return {"cuda": torch.cuda.is_available(), "gpu": torch.cuda.get_device_name(0) if torch.cuda.is_available() else None}
    else:
        raise ValueError(f"Unknown request {do}")
    return {}


for line in sys.stdin:
    try:
        answer = {"ok": True, **_handle(json.loads(line))}
    except Exception as e:  # handed back to RealBook, with the reason
        import traceback

        traceback.print_exc()
        if isinstance(e, torch.cuda.OutOfMemoryError):
            torch.cuda.empty_cache()
        answer = {"ok": False, "error": f"{type(e).__name__}: {e}"}
    _answers.write(json.dumps(answer) + "\n")
    _answers.flush()
