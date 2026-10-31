"""Designed voices on Linux with an NVIDIA graphics card. The Mac runs Qwen3-TTS through MLX, inside the
app; here it runs through PyTorch in a Python of its own (qwen_worker.py), installed from
qwen_pc_requirements.txt, where every package is pinned with its hash. Offered in Settings only on
computers with a card that has enough memory.
"""

from __future__ import annotations

import atexit
import hashlib
import json
import logging
import os
import shutil
import subprocess
import tarfile
import tempfile
import threading
from pathlib import Path
from types import SimpleNamespace

import numpy as np

from . import system

HERE = Path(__file__).resolve().parent
TRY_ON_THIS_COMPUTER = bool(os.environ.get("REALBOOK_QWEN_PC"))  # for developing it elsewhere, without a card
ENABLED = system.LINUX or TRY_ON_THIS_COMPUTER
MIN_GPU_GB = 8
RUNTIME_BYTES = 6_000_000_000  # PyTorch and what it needs, about
TORCH_INDEX = "https://download.pytorch.org/whl/cu128"  # the first PyTorch for every RTX 50 card
UV = ("https://github.com/astral-sh/uv/releases/download/0.13.6/uv-x86_64-unknown-linux-gnu.tar.gz",
      "f29c3e94ffabd7e6f3ba521dba169a9b7ec12100bf3257087f0f24f6123f3645")

log = logging.getLogger(__name__)
_gpu: bool | None = None


def supported() -> bool:
    """An NVIDIA card with enough memory."""
    global _gpu
    if TRY_ON_THIS_COMPUTER:
        return True
    if not system.LINUX:
        return False
    if _gpu is None:
        _gpu = False
        if smi := shutil.which("nvidia-smi"):
            try:
                out = subprocess.run([smi, "--query-gpu=memory.total", "--format=csv,noheader,nounits"], capture_output=True, text=True, timeout=10).stdout
                _gpu = max((int(x) for x in out.split()), default=0) >= MIN_GPU_GB * 1024
            except (OSError, ValueError, subprocess.SubprocessError):
                pass
    return _gpu


def _requirements_hash() -> str:
    return hashlib.sha256((HERE / "qwen_pc_requirements.txt").read_bytes()).hexdigest()


def ready(runtime: Path) -> bool:
    try:
        return (runtime / "ready").read_text().strip() == _requirements_hash()
    except OSError:
        return False


def _python(runtime: Path) -> Path:
    return runtime / "venv" / "bin" / "python"


def _download_uv(runtime: Path) -> Path:
    url, sha = UV
    uv = runtime / "uv"
    if uv.exists():
        return uv
    with tempfile.TemporaryDirectory(dir=runtime) as tmp:
        archive = Path(tmp) / "uv.tar.gz"
        system.run([system.curl(), "-sSL", "--fail", "--retry", "3", "-o", str(archive), url], check=True, timeout=600)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != sha:
            raise RuntimeError("The installer failed its integrity check; please try again")
        with tarfile.open(archive) as t:
            member = next(m for m in t.getmembers() if m.name.endswith("/uv"))
            with t.extractfile(member) as source, open(uv, "wb") as target:
                shutil.copyfileobj(source, target)
    uv.chmod(0o755)
    return uv


def install(runtime: Path, status: dict, need_gpu: bool = True) -> None:
    """Sets up the Python that runs the voices. Everything stays inside `runtime`."""
    if ready(runtime):
        return
    runtime.mkdir(parents=True, exist_ok=True)
    status["message"] = "Installing the voice software (about 6 GB)…"
    uv = _download_uv(runtime)
    env = {**os.environ, "UV_PYTHON_INSTALL_DIR": str(runtime / "pythons"), "UV_CACHE_DIR": str(runtime / "cache"), "UV_NO_CONFIG": "1"}

    def uv_run(*args: str) -> None:
        done = system.run([str(uv), *args], env=env, capture_output=True, text=True)
        if done.returncode:
            log.error("uv %s failed: %s", args[0], done.stderr)
            raise RuntimeError(f"Couldn't install the voice software: {done.stderr.strip()[-300:]}")

    uv_run("venv", "--python", "3.12", "--python-preference", "only-managed", "--allow-existing", str(runtime / "venv"))
    uv_run("pip", "sync", "--python", str(_python(runtime)), "--require-hashes", "--index", TORCH_INDEX, "--default-index", "https://pypi.org/simple",
           "--index-strategy", "unsafe-best-match", str(HERE / "qwen_pc_requirements.txt"))
    shutil.rmtree(runtime / "cache", ignore_errors=True)
    status["message"] = "Checking the graphics card…"
    check = system.run([str(_python(runtime)), "-c", "import torch, qwen_tts; print(torch.cuda.is_available())"], capture_output=True, text=True, timeout=300)
    if check.returncode:
        raise RuntimeError(f"The voice software didn't start: {check.stderr.strip()[-300:]}")
    if need_gpu and check.stdout.strip().splitlines()[-1] != "True":
        raise RuntimeError("The voice software can't use your graphics card. Update your NVIDIA driver (RTX 50 cards need version 570 or later) and try again.")
    (runtime / "ready").write_text(_requirements_hash())


class _Worker:
    """The process that holds the models. If it dies it's started again on the next request."""

    def __init__(self, runtime: Path) -> None:
        self.runtime = runtime
        self.proc: subprocess.Popen | None = None
        self.lock = threading.Lock()
        self.tmp = tempfile.mkdtemp(prefix="realbook-qwen-")
        atexit.register(self.stop)

    def stop(self) -> None:
        if self.proc and self.proc.poll() is None:
            self.proc.stdin.close()
            try:
                self.proc.wait(10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def ask(self, **request) -> dict:
        with self.lock:
            if self.proc is None or self.proc.poll() is not None:
                errors = open(self.runtime / "worker.log", "ab")
                self.proc = system.popen([str(_python(self.runtime)), str(HERE / "qwen_worker.py")], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                         stderr=errors, text=True, env={**os.environ, "PYTHONUNBUFFERED": "1"})
            self.proc.stdin.write(json.dumps(request) + "\n")
            self.proc.stdin.flush()
            answer = self.proc.stdout.readline()
        if not answer:
            raise RuntimeError(f"The voice software stopped; see {self.runtime / 'worker.log'}")
        reply = json.loads(answer)
        if not reply.get("ok"):
            raise RuntimeError(reply.get("error", "The voice software failed"))
        return reply


_worker: _Worker | None = None


class Model:
    """Stands in for the Mac's model object: the same calls, and the same kind of results."""

    def __init__(self, runtime: Path, role: str, path: Path) -> None:
        global _worker
        _worker = _worker or _Worker(runtime)
        self.where = {"role": role, "path": str(path)}
        _worker.ask(do="load", **self.where)

    def _file(self, name: str) -> str:
        return os.path.join(_worker.tmp, name)

    def _read(self, texts: list[str], ref_audio: str, ref_text: str, speaker_from: str | None) -> list[np.ndarray]:
        out = [self._file(f"line{i}.npy") for i in range(len(texts))]
        _worker.ask(do="read", texts=texts, language="English", ref=ref_audio, ref_text=ref_text, speaker_from=speaker_from, out=out, **self.where)
        return [np.load(p) for p in out]

    def generate(self, text: str, ref_audio: str, ref_text: str, lang_code: str = "english", speaker_from: str | None = None):
        yield SimpleNamespace(audio=self._read([text], ref_audio, ref_text, speaker_from)[0], sequence_idx=0)

    def batch_generate(self, texts: list[str], ref_audio: str, ref_text: str, lang_code: str = "english"):
        for i, audio in enumerate(self._read(texts, ref_audio, ref_text, None)):
            yield SimpleNamespace(audio=audio, sequence_idx=i)

    def generate_voice_design(self, text: str, instruct: str, language: str = "English"):
        out = self._file("design.npy")
        _worker.ask(do="design", text=text, instruct=instruct, language=language, out=out, **self.where)
        yield SimpleNamespace(audio=np.load(out), sequence_idx=0)

    def speaker_embedding(self, audio: np.ndarray) -> np.ndarray:
        path = self._file("embed.npy")
        np.save(path, audio.astype(np.float32))
        return np.array(_worker.ask(do="embed", audio=path, **self.where)["embedding"], dtype=np.float32)

    def unload(self) -> None:
        _worker.ask(do="unload", role=self.where["role"])
