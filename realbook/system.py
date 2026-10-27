"""What differs between macOS and Windows: where data lives, system voices, audio files, opening things.

On a Mac, lines are cached as AAC (.m4a) made with afconvert and system voices come from `say`.
On Windows, lines are cached as .wav and system voices come from System.Speech (SAPI), driven
through PowerShell so no extra packages are needed.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path
from xml.sax.saxutils import escape

MAC = sys.platform == "darwin"
WINDOWS = sys.platform == "win32"
AUDIO_EXT = ".m4a" if MAC else ".wav"
AUDIO_TYPE = "audio/mp4" if MAC else "audio/wav"
CAN_EXPORT = MAC  # audiobook export encodes AAC with afconvert


def data_dir() -> Path:
    if os.environ.get("REALBOOK_DATA"):
        return Path(os.environ["REALBOOK_DATA"])
    if MAC:
        return Path.home() / "Library" / "Application Support" / "RealBook"
    if WINDOWS:
        return Path(os.environ.get("APPDATA", Path.home() / "AppData" / "Roaming")) / "RealBook"
    return Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share")) / "RealBook"


def run(args: list[str], **kw) -> subprocess.CompletedProcess:
    """subprocess.run that doesn't flash a console window on Windows."""
    if WINDOWS:
        kw.setdefault("creationflags", subprocess.CREATE_NO_WINDOW)
    return subprocess.run(args, **kw)


def popen(args: list[str], **kw) -> subprocess.Popen:
    if WINDOWS:
        kw.setdefault("creationflags", subprocess.CREATE_NO_WINDOW)
    return subprocess.Popen(args, **kw)


def curl() -> str:
    return "curl.exe" if WINDOWS else "curl"  # Windows 10 and later include curl


# ------------------------------------------------------------------ audio files


def encode(wav: Path, out: Path, sample_rate: int) -> None:
    """Turn a finished .wav into the cached audio file at `out` (AAC on a Mac, kept as WAV elsewhere).

    `sample_rate` is the rate to encode at, which may differ from the WAV's own rate when the
    voice was pitch-shifted by relabelling its rate.
    """
    if MAC:
        try:
            run(["afconvert", "-f", "m4af", "-d", f"aac@{sample_rate}", str(wav), str(out)],
                check=True, capture_output=True, timeout=120)
        finally:
            wav.unlink(missing_ok=True)
    else:
        shutil.move(str(wav), str(out))


# ---------------------------------------------------------------- system voices


def default_voice() -> str:
    if MAC:
        return "Samantha"
    voices = system_voices()
    english = [v for v in voices if v["locale"].startswith("en")]
    return (english or voices or [{"name": ""}])[0]["name"]


def system_voices() -> list[dict]:
    """[{"name", "locale", "gender", "age"}] for the voices the operating system can speak with."""
    if MAC:
        return []  # parsed from `say -v ?` in voices.py, which also knows Apple's voice names
    if not WINDOWS:
        return []
    script = (
        "Add-Type -AssemblyName System.Speech; $s = New-Object System.Speech.Synthesis.SpeechSynthesizer; "
        "@($s.GetInstalledVoices() | Where-Object Enabled | ForEach-Object { $v = $_.VoiceInfo; "
        "[pscustomobject]@{name=$v.Name; culture=$v.Culture.Name; gender=\"$($v.Gender)\"; age=\"$($v.Age)\"} }) "
        "| ConvertTo-Json -Compress"
    )
    out = run(["powershell", "-NoProfile", "-NonInteractive", "-Command", script], capture_output=True, text=True, timeout=60)
    try:
        data = json.loads(out.stdout or "[]")
    except json.JSONDecodeError:
        return []
    if isinstance(data, dict):
        data = [data]
    ages = {"Child": "child", "Teen": "young", "Adult": "adult", "Senior": "old"}
    return [{"name": v["name"], "locale": (v.get("culture") or "en-US").replace("-", "_"),
             "gender": (v.get("gender") or "").lower() if v.get("gender") in ("Male", "Female") else "unknown",
             "age": ages.get(v.get("age"), "adult")} for v in data]


_SAPI = (
    "Add-Type -AssemblyName System.Speech; $s = New-Object System.Speech.Synthesis.SpeechSynthesizer; "
    "$s.SelectVoice($env:RB_VOICE); $s.SetOutputToWaveFile($env:RB_OUT); "
    "$s.SpeakSsml([Console]::In.ReadToEnd()); $s.Dispose()"
)


def speak(text: str, voice: str, rate: int, pitch_shift: int, out: Path) -> None:
    """Render `text` with a system voice to `out` (the cached audio file)."""
    if MAC:
        prefix = f"[[pbas {pitch_shift:+d}]] " if pitch_shift else ""
        run(["say", "-v", voice, "-r", str(int(rate)), "-o", str(out), "--file-format=m4af", "--data-format=aac"],
            input=prefix + text, text=True, check=True, capture_output=True, timeout=120)
        return
    if not WINDOWS:
        raise RuntimeError("System voices aren't available on this computer; download natural voices in Settings")
    speed = round((rate / 180 - 1) * 100)  # RealBook's rates are words per minute, 180 being normal
    ssml = (f'<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="en-US">'
            f'<prosody rate="{speed:+d}%" pitch="{2 * pitch_shift:+d}%">{escape(text)}</prosody></speak>')
    env = {**os.environ, "RB_VOICE": voice, "RB_OUT": str(out)}
    run(["powershell", "-NoProfile", "-NonInteractive", "-Command", _SAPI],
        input=ssml, text=True, env=env, check=True, capture_output=True, timeout=120)


# ------------------------------------------------------------- opening things


def open_url(url: str) -> None:
    if WINDOWS:
        os.startfile(url)  # noqa: S606 - a fixed https URL checked by the caller
    else:
        run(["open" if MAC else "xdg-open", url], check=False)


def reveal(path: Path) -> None:
    """Show a file in Finder / Explorer."""
    if MAC:
        run(["open", "-R", str(path)], check=False)
    elif WINDOWS:
        run(["explorer", f"/select,{path}"], check=False)
    else:
        run(["xdg-open", str(path.parent)], check=False)


def open_voice_settings() -> bool:
    """Where the operating system offers more voices to download."""
    if MAC:
        return run(["open", "-a", "VoiceOver Utility"], capture_output=True).returncode == 0
    if WINDOWS:
        os.startfile("ms-settings:speech")  # noqa: S606
        return True
    return False


# ----------------------------------------------------------------- staying awake

_awake: subprocess.Popen | None = None
_awake_until = 0.0


def keep_awake(seconds: int = 600) -> None:
    """Stop the computer going to sleep for a while (refreshed while another device is listening)."""
    global _awake, _awake_until
    if time.monotonic() < _awake_until - seconds / 2:
        return
    _awake_until = time.monotonic() + seconds
    if MAC:
        if _awake is not None and _awake.poll() is None:
            _awake.terminate()
        _awake = popen(["caffeinate", "-i", "-t", str(seconds)])
    elif WINDOWS:
        threading.Thread(target=_windows_awake, daemon=True).start()


def _windows_awake() -> None:
    import ctypes

    ES_CONTINUOUS, ES_SYSTEM_REQUIRED = 0x80000000, 0x00000001
    ctypes.windll.kernel32.SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)
    while time.monotonic() < _awake_until:
        time.sleep(30)
    ctypes.windll.kernel32.SetThreadExecutionState(ES_CONTINUOUS)
