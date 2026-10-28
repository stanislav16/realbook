"""Listen on a phone, tablet or another computer through this Mac, over the home network.

When it's turned on, a second server listens on the network. Other devices need the secret key
in the pairing link (shown as a QR code in Settings); after opening it once, a cookie remembers
it. They can read and listen to every book, but can't change settings or open things on the Mac.
"""

from __future__ import annotations

import io
import secrets
import socket
import threading
import time

from . import store, system

PORT = 47321
COOKIE = "realbook_key"
# Things only someone sitting at the Mac may do.
BLOCKED = [("PUT", "/api/settings"), ("POST", "/api/open-link"), ("POST", "/api/open-voice-settings"),
           ("POST", "/api/kokoro/install"), ("POST", "/api/qwen/install"), ("POST", "/api/breeze/install"), ("POST", "/api/remote"),
           ("POST", "/api/remote/reset")]

_server = None
_lock = threading.Lock()


def enabled() -> bool:
    return bool(store.settings().get("remote_enabled"))


def token() -> str:
    values = store.settings()
    if not values.get("remote_token"):
        values["remote_token"] = secrets.token_urlsafe(18)
        store.save_settings(values)
    return values["remote_token"]


def lan_address() -> str | None:
    """This Mac's address on the local network (no packet is sent)."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        try:
            s.connect(("192.168.0.1", 9))
            return s.getsockname()[0]
        except OSError:
            return None


def is_local(client_host: str | None) -> bool:
    return client_host in ("127.0.0.1", "::1", "localhost")


def authorised(key: str | None) -> bool:
    return bool(key) and secrets.compare_digest(key, token())


def blocked(method: str, path: str) -> bool:
    return (method, path) in BLOCKED or path.endswith("/export/reveal") or path.endswith("/review/save")


def status() -> dict:
    on = enabled() and _server is not None
    ip = lan_address()
    url = f"http://{ip}:{PORT}/?key={token()}" if ip else None
    return {"enabled": enabled(), "running": on, "url": url if on else None, "qr": _qr(url) if on and url else None,
            "address": f"{ip}:{PORT}" if ip else None}


def _qr(text: str) -> str:
    import qrcode
    import qrcode.image.svg

    img = qrcode.make(text, image_factory=qrcode.image.svg.SvgPathImage, box_size=8, border=2)
    out = io.BytesIO()
    img.save(out)
    return out.getvalue().decode()


def start() -> None:
    global _server
    import uvicorn

    from .server import app

    with _lock:
        if _server is not None:
            return
        _server = uvicorn.Server(uvicorn.Config(app, host="0.0.0.0", port=PORT, log_level="warning"))
        threading.Thread(target=_server.run, daemon=True, name="remote-server").start()


def stop() -> None:
    global _server
    with _lock:
        if _server is not None:
            _server.should_exit = True
            _server = None


def set_enabled(on: bool) -> dict:
    values = store.settings()
    values["remote_enabled"] = on
    store.save_settings(values)
    if on:
        start()
    else:
        stop()
    time.sleep(0.3)  # let the listener come up before the QR code is shown
    return status()


def reset_token() -> dict:
    """A new pairing link; devices paired with the old one lose access."""
    values = store.settings()
    values["remote_token"] = secrets.token_urlsafe(18)
    store.save_settings(values)
    return status()


def keep_awake() -> None:
    """While another device is listening, stop this computer going to sleep for the next 10 minutes."""
    system.keep_awake(600)
