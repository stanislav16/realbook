"""Smoke test of an installation or a packaged build: import the sample book, cast it, and speak a
line with each voice engine that's available. Used by the Windows build on GitHub, where nobody
can look at the window.

    realbook-selftest [--kokoro] [--log FILE]
    RealBook --selftest [--kokoro] [--log FILE]      (the packaged app)

--kokoro also downloads the natural-voice model (350 MB) and speaks with it.
Runs against a fresh, temporary library. Exit code 0 means everything worked.
"""

from __future__ import annotations

import os
import sys
import tempfile
import time
import traceback


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    log_path = argv[argv.index("--log") + 1] if "--log" in argv else None
    out = open(log_path, "w", encoding="utf-8") if log_path else sys.stdout

    def say(*parts) -> None:
        print(*parts, file=out, flush=True)

    # Must happen before realbook.store decides where the library lives.
    os.environ["REALBOOK_DATA"] = tempfile.mkdtemp(prefix="realbook-selftest-")
    ok = True
    try:
        from . import kokoro_tts, server, store, system, tts, voices

        say(f"platform: {sys.platform}, library: {store.DATA_DIR}")
        server.prepare_library()
        book = store.load(store.list_books()[0]["id"])
        say(f"sample book: {book['title']!r}, {len(book['chapters'])} chapters, "
            f"cast: {', '.join(c['name'] for c in book['characters'])}")
        line = next(s for s in book["chapters"][0]["segments"] if s["kind"] == "dialogue")

        def speak(label: str, voice: str) -> bool:
            t = time.monotonic()
            try:
                path = tts.synthesize(store.audio_dir(book["id"]), line["text"], voice, voices.DEFAULT_RATE, 0)
                size = path.stat().st_size
                say(f"{label}: {voice} -> {path.name}, {size} bytes in {time.monotonic() - t:.1f}s")
                return size > 1000
            except Exception:
                say(f"{label}: {voice} FAILED")
                say(traceback.format_exc())
                return False

        system_voices = [v for v in voices.installed_voices() if v["locale"].lower().startswith("en")]
        say(f"system voices: {len(system_voices)} English ({', '.join(v['name'] for v in system_voices[:6])})")
        if system_voices:
            ok &= speak("system voice", system_voices[0]["name"])
        else:
            say("system voice: none installed (skipped)")

        if "--kokoro" in argv:
            kokoro_tts.install_async()
            while kokoro_tts.install_status()["state"] == "downloading":
                time.sleep(2)
            status = kokoro_tts.install_status()
            say(f"kokoro download: {status['state']} {status['message']}")
            ok &= status["installed"] and speak("kokoro", "kokoro:af_heart")
        ok &= bool(book["characters"]) and system.AUDIO_EXT in (".m4a", ".wav")
    except Exception:
        say(traceback.format_exc())
        ok = False
    say("SELFTEST PASSED" if ok else "SELFTEST FAILED")
    if log_path:
        out.close()
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
