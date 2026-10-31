"""Listen on a phone, tablet or another computer through this Mac, over the home network.

When it's turned on, a second server listens on the network. Other devices need the secret key
in the pairing link (shown as a QR code in Settings); after opening it once, a cookie remembers
it. They can read and listen to every book, but can't change settings or open things on the Mac.
"""

from __future__ import annotations

import hashlib
import hmac
import io
import logging
import secrets
import socket
import subprocess
import threading
import time
import urllib.parse

from . import store, system

PORT = 47321
COOKIE = "realbook_key"
HEADER = "x-realbook-key"  # how the iPhone app sends the key
# Things only someone sitting at the Mac may do.
BLOCKED = [("PUT", "/api/settings"), ("POST", "/api/open-link"), ("POST", "/api/open-voice-settings"),
           ("POST", "/api/kokoro/install"), ("POST", "/api/qwen/install"), ("POST", "/api/remote"),
           ("POST", "/api/remote/reset"), ("POST", "/api/ahead")]
SERVICE = "_realbook._tcp.local."

_server = None
_lock = threading.Lock()
_announce_stop: threading.Event | None = None
log = logging.getLogger(__name__)


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


def mac_name() -> str:
    """This Mac's name on the local network ("Stanislavs-MacBook-Pro.local")."""
    if system.MAC:
        try:  # the name the network knows; gethostname() can be a different one
            name = subprocess.run(["scutil", "--get", "LocalHostName"], capture_output=True, text=True, timeout=5).stdout.strip()
            if name:
                return f"{name}.local"
        except (OSError, subprocess.SubprocessError):
            pass
    name = socket.gethostname()
    return name if name.endswith(".local") else f"{name.split('.')[0]}.local"


def prove(nonce: str) -> str:
    """Shows this Mac has the pairing key without giving it away."""
    return hmac.new(token().encode(), nonce.encode(), hashlib.sha256).hexdigest()


def _announce(stop: threading.Event) -> None:
    """Tells the local network where RealBook is, and again whenever this Mac's address changes, so the
    iPhone can find it on any Wi-Fi. If this fails, the iPhone still tries the last address and the name."""
    from zeroconf import ServiceInfo, Zeroconf

    zc = info = address = None
    try:
        while not stop.is_set():
            now = lan_address()
            if now != address:
                if zc:
                    zc.close()
                    zc = None
                address = now
                if now:
                    try:
                        zc = Zeroconf(interfaces=[now])
                        name = mac_name().removesuffix(".local")
                        info = ServiceInfo(SERVICE, f"RealBook on {name}.{SERVICE}", addresses=[socket.inet_aton(now)], port=PORT,
                                           server=f"realbook-{name}.local.")
                        zc.register_service(info, allow_name_change=True)
                    except Exception:
                        log.exception("Couldn't announce RealBook on the network")
                        address = None  # try again next time round
            stop.wait(10)
    finally:
        if zc:
            try:
                zc.close()
            except Exception:
                pass


def is_local(client_host: str | None) -> bool:
    return client_host in ("127.0.0.1", "::1", "localhost")


def authorised(key: str | None) -> bool:
    return bool(key) and secrets.compare_digest(key, token())


def blocked(method: str, path: str) -> bool:
    return (method, path) in BLOCKED or path.endswith("/export/reveal") or path.endswith("/review/save")


def status() -> dict:
    on = enabled() and _server is not None
    ip = lan_address()
    # The Mac's own name too, so the iPhone app still finds it when its address changes.
    url = f"http://{ip}:{PORT}/?key={token()}&mac={urllib.parse.quote(mac_name())}" if ip else None
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
    global _server, _announce_stop
    import uvicorn

    from .server import app

    with _lock:
        if _server is not None:
            return
        _server = uvicorn.Server(uvicorn.Config(app, host="0.0.0.0", port=PORT, log_level="warning"))
        threading.Thread(target=_server.run, daemon=True, name="remote-server").start()
        _announce_stop = threading.Event()
        threading.Thread(target=_announce, args=(_announce_stop,), daemon=True, name="remote-announce").start()


def stop() -> None:
    global _server
    with _lock:
        if _server is not None:
            _server.should_exit = True
            _server = None
            if _announce_stop:
                _announce_stop.set()


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
