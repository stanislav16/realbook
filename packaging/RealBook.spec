# PyInstaller spec for RealBook. On a Mac, ./packaging/build_app.sh puts this inside the native app (mac/).
# or `uv run pyinstaller packaging/RealBook.spec` on Windows or Linux (dist/RealBook/RealBook[.exe]).
import sys
from pathlib import Path

from PyInstaller.utils.hooks import collect_data_files, collect_dynamic_libs, collect_submodules

ROOT = Path(SPECPATH).parent
VERSION = "0.10.1"
MAC = sys.platform == "darwin"

datas = [
    (str(ROOT / "realbook" / "static"), "realbook/static"),
    (str(ROOT / "realbook" / "samples"), "realbook/samples"),
    # Kokoro: tokenizer config, and espeak-ng's pronunciation data
    *collect_data_files("kokoro_onnx"),
    *collect_data_files("espeakng_loader"),
    *collect_data_files("phonemizer"),
]
binaries = collect_dynamic_libs("espeakng_loader")
hiddenimports = collect_submodules("uvicorn") + collect_submodules("phonemizer") + collect_submodules("zeroconf") + ["kokoro_onnx", "qrcode.image.svg"]
if MAC:
    # Qwen3-TTS (designed voices, Apple silicon only): MLX's Metal kernels, and mlx-audio's model code
    datas += collect_data_files("mlx", includes=["**/*.metallib"]) + collect_data_files("mlx_audio")
    binaries += collect_dynamic_libs("mlx")
    # mlx-audio imports its model code by name once it has read the model's config.
    hiddenimports += (collect_submodules("mlx") + collect_submodules("mlx_audio.tts.models.qwen3_tts")
                      + collect_submodules("mlx_audio.codec")
                      + ["mlx_audio.tts.utils", "miniaudio", "transformers.models.qwen2.tokenization_qwen2"]
                      # The local AI that describes characters (mlx-lm loads model code by name too).
                      + collect_submodules("mlx_lm"))

if sys.platform.startswith("linux"):
    # The window: pywebview reaches Qt through QtPy, by name.
    hiddenimports += ["qtpy", "webview.platforms.qt", "PyQt6.QtWebEngineWidgets", "PyQt6.QtWebEngineCore", "PyQt6.QtWebChannel",
                      "PyQt6.QtNetwork", "PyQt6.QtPrintSupport"]

a = Analysis(
    [str(ROOT / "packaging" / "launch.py")],
    pathex=[str(ROOT)],
    datas=datas,
    binaries=binaries,
    hiddenimports=hiddenimports,
    excludes=["tkinter"],
)
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name="RealBook", console=False, argv_emulation=False,
          icon=str(ROOT / "packaging" / ("RealBook.icns" if MAC else "RealBook.ico")))
coll = COLLECT(exe, a.binaries, a.datas, name="RealBook")
