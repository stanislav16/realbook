"""The server behind the native Mac app: everything but the window. It says which port it took on
stdout, and ends when the app does (its stdin closes)."""

from __future__ import annotations

import json
import os
import socket
import sys
import threading

import uvicorn

from . import server


def main() -> None:
    server.prepare_library()
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    srv = uvicorn.Server(uvicorn.Config(server.app, host="127.0.0.1", port=port, log_level="warning"))
    threading.Thread(target=srv.run, daemon=True).start()
    while not srv.started:
        threading.Event().wait(0.05)
    print(json.dumps({"port": port}), flush=True)
    sys.stdin.read()  # returns when the app has gone, however it went
    os._exit(0)


if __name__ == "__main__":
    main()
