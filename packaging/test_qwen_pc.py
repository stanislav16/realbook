"""Tries designed voices through PyTorch (qwen_pc.py) from start to finish: makes a voice, reads lines
alone and in a group, whispers one and compares speakers. Nothing is played. Run with
REALBOOK_QWEN_PC=1 and REALBOOK_DATA set to an empty folder; on a computer without an NVIDIA card add
REALBOOK_QWEN_DEVICE=cpu and pass --no-gpu, which is slow. With --runtime PATH it uses a Python that's
already set up instead of installing one (for trying it on a Mac).
"""

import sys
import time
from pathlib import Path

import numpy as np

from realbook import designed, qwen_pc, tts

engine = designed.ENGINES["qwen"]
runtime = designed._runtime(engine)
status: dict = {}
args = sys.argv[1:]
t = time.time()
if "--runtime" in args:
    runtime.mkdir(parents=True, exist_ok=True)
    (runtime / "venv").symlink_to(Path(args[args.index("--runtime") + 1]))
    (runtime / "ready").write_text(qwen_pc._requirements_hash())
else:
    qwen_pc.install(runtime, status, need_gpu="--no-gpu" not in args)
print(f"software installed in {time.time() - t:.0f}s: {status.get('message')}", flush=True)
assert qwen_pc.ready(runtime)
t = time.time()
designed._download(engine, None)
print(f"models: {engine.install['state']} {engine.install['message']} in {time.time() - t:.0f}s", flush=True)
assert engine.install["state"] == "done", engine.install
assert designed.installed(engine)

voice = designed.voice_for(engine, "A calm middle-aged man with a deep, warm voice, speaking slowly.", seed="test")
out = Path(designed.store.DATA_DIR) / "lines"


def seconds(path: Path) -> float:
    assert path.stat().st_size > 1000, path
    return len(designed._read_wav(path)) / designed.SAMPLE_RATE


t = time.time()
one = tts.synthesize(out, "The old mill stood by the river, and nobody had worked it for years.", voice, 180, 0)
print(f"one line (and designing the voice): {seconds(one):.1f}s of audio in {time.time() - t:.0f}s", flush=True)
t = time.time()
two = tts.synthesize(out, "The water went on turning the wheel all the same.", voice, 180, 0)
print(f"another line: {seconds(two):.1f}s of audio in {time.time() - t:.0f}s", flush=True)
t = time.time()
group = [("Nobody came to the mill that winter.", 0), ("Yes … of course.", 0), ("A long grey road ran up over the hill, and at the top of it a light was burning in the window.", 0)]
tts.synthesize_many(out, voice, 180, 0, group)
made = [tts.audio_path(out, text, voice, 180, 0) for text, _ in group]
print("a group of 3:", [f"{seconds(p):.1f}s" for p in made], f"in {time.time() - t:.0f}s", flush=True)
t = time.time()
quiet = tts.synthesize(out, "Keep your voice down, they will hear us.", voice, 180, 0, style="quiet")
print(f"whispered (and designing that sample): {seconds(quiet):.1f}s of audio in {time.time() - t:.0f}s", flush=True)
a, b = (designed._read_wav(p) for p in (one, two))
alike = designed._submit(designed.URGENT, designed._likeness, engine, a, b).result()
print(f"two lines' speakers alike: {alike:.3f}", flush=True)
assert alike > 0.7
assert not list(out.glob("*.tmp*"))
print("PYTORCH VOICES PASSED")
