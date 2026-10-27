"""RealBook as a desktop app (Mac or Windows): the reader in a native window, with the server running inside the app."""

from __future__ import annotations

import json
import socket
import threading
import time
from pathlib import Path

import uvicorn
import webview
from webview.menu import Menu, MenuAction, MenuSeparator

from . import importer, server, store, system

# Menu titles that get keyboard shortcuts (pywebview menus can't declare them).
SHORTCUTS = {
    "Settings…": ",",
    "Add Book…": "o",
    "Library": "l",
    "Next Chapter": "",      # ⌘→
    "Previous Chapter": "",  # ⌘←
    "Show Contents": "1",
    "Show Cast": "2",
}


def _install_menu_shortcuts() -> None:
    """pywebview menus can't declare shortcuts, and it rebuilds the menu bar whenever the window
    gains focus. So add ours every time it builds a menu."""
    try:
        import AppKit
        from webview.platforms import cocoa
    except ImportError:  # not on macOS
        return
    build = cocoa.BrowserView._process_menu_items

    def build_with_shortcuts(self, menu_items, parent_menu):
        build(self, menu_items, parent_menu)
        for item in parent_menu.itemArray():
            key = SHORTCUTS.get(item.title())
            if key:
                item.setKeyEquivalent_(key)
                item.setKeyEquivalentModifierMask_(AppKit.NSEventModifierFlagCommand)

    cocoa.BrowserView._process_menu_items = build_with_shortcuts


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Shell:
    def __init__(self) -> None:
        self.window: webview.Window | None = None

    def js(self, code: str):
        return lambda: self.window.evaluate_js(code)

    def choose_paths(self, multiple: bool) -> list[Path]:
        """A native Open sheet that accepts book files and EPUB folders (Apple Books exports those)."""
        if not system.MAC:
            picked = self.window.create_file_dialog(
                webview.OPEN_DIALOG, allow_multiple=multiple,
                file_types=("Books (*.epub;*.txt;*.md)", "All files (*.*)"))
            return [Path(p) for p in picked or []]
        import AppKit
        from PyObjCTools import AppHelper

        chosen: list[Path] = []
        done = threading.Event()

        def show():
            panel = AppKit.NSOpenPanel.openPanel()
            panel.setCanChooseFiles_(True)
            panel.setCanChooseDirectories_(True)
            panel.setAllowsMultipleSelection_(multiple)
            panel.setTreatsFilePackagesAsDirectories_(False)
            panel.setMessage_("Choose an EPUB or text file. Books dragged out of Apple Books work too.")
            panel.setPrompt_("Choose")

            def finished(response):
                if response == AppKit.NSModalResponseOK:
                    chosen.extend(Path(str(url.path())) for url in panel.URLs())
                done.set()

            panel.beginSheetModalForWindow_completionHandler_(self.window.native, finished)

        AppHelper.callAfter(show)
        done.wait()
        return chosen

    def toast(self, message: str, ms: int = 3500) -> None:
        self.window.evaluate_js(f"toast({json.dumps(message)}, {ms})")

    def add_book(self) -> None:
        for path in self.choose_paths(multiple=True):
            self.toast(f"Reading “{path.name}” and finding its characters…", 60000)
            try:
                book = store.create(*importer.read_book_path(path))
            except ValueError as e:  # a book we can't read (DRM, unsupported file): the message says why
                self.toast(str(e))
                continue
            except Exception as e:  # a bug: say which book and what went wrong, not just the bare error
                self.toast(f"Couldn't add “{path.name}”: {type(e).__name__}: {e}")
                continue
            self.window.evaluate_js(f"toast({json.dumps('Added “' + book['title'] + '”')}); openBook({json.dumps(book['id'])})")

    def update_from_file(self, book_id: str) -> dict | None:
        paths = self.choose_paths(multiple=False)
        if not paths:
            return None
        self.toast(f"Reading “{paths[0].name}”…", 60000)
        try:
            return store.update_source(book_id, *importer.read_book_path(paths[0]))
        except Exception as e:  # shown in the app
            return {"error": str(e)}


    def menu(self) -> list[Menu]:
        js = self.js
        app_items = [MenuAction("Settings…", js("openSettings()")), MenuAction("Find Voice Models…", js("openModelFinder()"))]
        file_items = [MenuAction("Add Book…", self.add_book), MenuSeparator(), MenuAction("Library", js("showLibrary()"))]
        # Mac apps keep Settings in the app menu; Windows apps keep it in File.
        top = [Menu("__app__", app_items), Menu("File", file_items)] if system.MAC else [
            Menu("File", file_items + [MenuSeparator(), *app_items])]
        return [
            *top,
            Menu("Playback", [
                MenuAction("Play / Pause", js("togglePlay()")),
                MenuAction("Next Line", js("step(1)")),
                MenuAction("Previous Line", js("step(-1)")),
                MenuSeparator(),
                MenuAction("Next Chapter", js("jumpChapter(1)")),
                MenuAction("Previous Chapter", js("jumpChapter(-1)")),
            ]),
            Menu("Book", [
                MenuAction("Show Contents", js("togglePanel('toc')")),
                MenuAction("Show Cast", js("togglePanel('cast')")),
                *([MenuSeparator(), MenuAction("Export Audiobook…", js("S.book && exportBook(S.book)"))] if system.CAN_EXPORT else []),
            ]),
        ]

    def style_native(self) -> None:
        """Books-style window: the page runs under a transparent title bar."""
        import AppKit
        from PyObjCTools import AppHelper

        self.window.events.shown.wait(15)

        def apply():
            win = self.window.native
            win.setStyleMask_(win.styleMask() | AppKit.NSWindowStyleMaskFullSizeContentView)
            win.setTitlebarAppearsTransparent_(True)
            win.setTitleVisibility_(AppKit.NSWindowTitleHidden)
            win.setTitlebarSeparatorStyle_(AppKit.NSTitlebarSeparatorStyleNone)
            # pywebview paints the title bar with a solid colour; clear it so the toolbar shows through.
            bar = win.contentView().superview().subviews().lastObject()
            if bar is not None and bar.respondsToSelector_("setBackgroundColor:"):
                bar.setBackgroundColor_(AppKit.NSColor.clearColor())

        AppHelper.callAfter(apply)


class Api:
    """Called from the page as window.pywebview.api.*"""

    def __init__(self, shell: Shell) -> None:
        self._shell = shell

    def add_books(self) -> None:
        self._shell.add_book()

    def update_from_file(self, book_id: str) -> dict | None:
        return self._shell.update_from_file(book_id)


def main() -> None:
    server.prepare_library()
    port = _free_port()
    srv = uvicorn.Server(uvicorn.Config(server.app, host="127.0.0.1", port=port, log_level="warning"))
    threading.Thread(target=srv.run, daemon=True).start()
    deadline = time.monotonic() + 15
    while not srv.started and time.monotonic() < deadline:
        time.sleep(0.05)

    # Only bare toolbar/sidebar background drags the window, not the buttons on it.
    webview.settings["DRAG_REGION_DIRECT_TARGET_ONLY"] = True
    _install_menu_shortcuts()
    shell = Shell()
    shell.window = webview.create_window(
        "RealBook",
        f"http://127.0.0.1:{port}/?native={'mac' if system.MAC else 'windows'}",
        width=1320,
        height=880,
        min_size=(860, 600),
        js_api=Api(shell),
    )
    webview.start(shell.style_native if system.MAC else None, menu=shell.menu())
    srv.should_exit = True


if __name__ == "__main__":
    main()
