"""The Mac's player on real Liquid Glass: native controls in a glass view floating over the page.

Only native views can be Liquid Glass, and the reader is a web page. So the page keeps its player,
invisible, and stays in charge of everything: it sends this what to show and where (`show`), and
pressing a control here presses the same control there. Native menus come for free: Macs draw them
in glass by themselves. Macs before macOS 26 have no such view (`available`), and keep the page's own.
"""

from __future__ import annotations

import json
import threading

import AppKit
import objc
import Quartz  # noqa: F401  so that colours for layers come through as what they are
from Foundation import NSMakePoint, NSMakeRect, NSObject
from PyObjCTools import AppHelper

RADIUS = 28
SIDE = 20  # the controls' margin inside the glass
FADE_SECONDS = 0.15
ROW_ICON = (40, 24)
ROW_ITEMS = (("speed-btn", "Speed", None), ("sleep-btn", "Sleep", "moon"), ("text-btn", "Text", "text.alignleft"), ("toc-btn", "Chapters", "list.bullet"))


def available() -> bool:
    try:
        objc.lookUpClass("NSGlassEffectView")
        return True
    except objc.error:
        return False


def _symbol(name: str, size: float, weight=AppKit.NSFontWeightRegular) -> AppKit.NSImage:
    image = AppKit.NSImage.imageWithSystemSymbolName_accessibilityDescription_(name, None)
    return image.imageWithSymbolConfiguration_(AppKit.NSImageSymbolConfiguration.configurationWithPointSize_weight_(size, weight))


def _row_icon(draw_inside) -> AppKit.NSImage:
    """All the same size, so the labels under them line up."""
    image = AppKit.NSImage.imageWithSize_flipped_drawingHandler_(ROW_ICON, False, draw_inside)
    image.setTemplate_(True)
    return image


def _row_symbol(name: str) -> AppKit.NSImage:
    symbol = _symbol(name, 17)
    size = symbol.size()

    def draw(rect):
        symbol.drawInRect_(NSMakeRect((ROW_ICON[0] - size.width) / 2, (ROW_ICON[1] - size.height) / 2, size.width, size.height))
        return True

    return _row_icon(draw)


def _row_text(text: str) -> AppKit.NSImage:
    """Text as an icon: the speed sits where the other buttons have theirs."""
    attrs = {AppKit.NSFontAttributeName: AppKit.NSFont.systemFontOfSize_weight_(15, AppKit.NSFontWeightSemibold)}
    string = AppKit.NSAttributedString.alloc().initWithString_attributes_(text, attrs)
    size = string.size()

    def draw(rect):
        string.drawAtPoint_(NSMakePoint((ROW_ICON[0] - size.width) / 2, (ROW_ICON[1] - size.height) / 2))
        return True

    return _row_icon(draw)


class _Flipped(AppKit.NSView):
    def isFlipped(self):
        return True


class _Press(AppKit.NSButton):
    """Answers the moment it's pressed, and doesn't take the keyboard from the page (space is play)."""

    def acceptsFirstMouse_(self, event):
        return True

    def mouseDown_(self, event):
        self.setAlphaValue_(0.55)
        objc.super(_Press, self).mouseDown_(event)  # returns when the button is let go
        self.setAlphaValue_(1.0)


class _Slider(AppKit.NSSlider):
    def acceptsFirstMouse_(self, event):
        return True


class _Target(NSObject):
    def initWithOwner_(self, owner):
        self = objc.super(_Target, self).init()
        self.owner = owner
        return self

    def pressed_(self, sender):
        self.owner.press(str(sender.identifier()))

    def slid_(self, sender):
        self.owner.slid(sender)


class Player:
    def __init__(self, window) -> None:
        self.window = window
        self.web = window.contentView()
        self.target = _Target.alloc().initWithOwner_(self)
        self.dragging = False
        self.shown: dict = {}
        self.pills: dict[str, AppKit.NSView] = {}
        self.items: dict[str, AppKit.NSButton] = {}

        self.glass = objc.lookUpClass("NSGlassEffectView").alloc().initWithFrame_(NSMakeRect(0, 0, 600, 180))
        self.glass.setCornerRadius_(RADIUS)
        self.glass.setHidden_(True)
        self.content = _Flipped.alloc().initWithFrame_(self.glass.bounds())
        self.glass.setContentView_(self.content)

        self.slider = _Slider.alloc().initWithFrame_(NSMakeRect(0, 0, 100, 20))
        self.slider.setTarget_(self.target)
        self.slider.setAction_("slid:")
        self.slider.setContinuous_(True)
        self.slider.setRefusesFirstResponder_(True)
        self.slider.setAccessibilityLabel_("Line in this chapter")
        self.left, self.right = self._label(11), self._label(11)
        self.right.setAlignment_(AppKit.NSTextAlignmentRight)
        for view in (self.slider, self.left, self.right):
            self.content.addSubview_(view)

        self.prev = self._control("prev", "backward.end.fill", "Previous line", 21)
        self.next = self._control("next", "forward.end.fill", "Next line", 21)
        self.play = self._control("play", "play.fill", "Play or pause", 24)
        self.play.setWantsLayer_(True)
        self.play.layer().setCornerRadius_(30)
        self._icon = "play.fill"
        for ident, title, icon in ROW_ITEMS:
            pill = _Flipped.alloc().initWithFrame_(NSMakeRect(0, 0, 46, 28))
            pill.setWantsLayer_(True)
            pill.layer().setCornerRadius_(14)
            self.content.addSubview_(pill)
            self.pills[ident] = pill
            button = self._control(ident, icon or "circle", title, 17)
            button.setImage_(_row_symbol(icon or "circle"))
            button.setTitle_(title)
            button.setFont_(AppKit.NSFont.systemFontOfSize_(10.5))
            button.setImagePosition_(AppKit.NSImageAbove)
            self.items[ident] = button
        self.web.addSubview_positioned_relativeTo_(self.glass, AppKit.NSWindowAbove, None)

    def _label(self, size: float) -> AppKit.NSTextField:
        label = AppKit.NSTextField.labelWithString_("")
        label.setFont_(AppKit.NSFont.monospacedDigitSystemFontOfSize_weight_(size, AppKit.NSFontWeightMedium))
        label.setTextColor_(AppKit.NSColor.secondaryLabelColor())
        return label

    def _control(self, ident: str, icon: str, label: str, size: float) -> _Press:
        button = _Press.alloc().initWithFrame_(NSMakeRect(0, 0, 46, 46))
        button.setBordered_(False)
        button.setTitle_("")
        button.setImage_(_symbol(icon, size))
        button.setImagePosition_(AppKit.NSImageOnly)
        button.setContentTintColor_(AppKit.NSColor.labelColor())
        button.setIdentifier_(ident)
        button.setTarget_(self.target)
        button.setAction_("pressed:")
        button.setRefusesFirstResponder_(True)
        button.setAccessibilityLabel_(label)
        button.cell().setHighlightsBy_(0)
        self.content.addSubview_(button)
        return button

    # ---------------------------------------------------------------- what the page says

    def show(self, state: dict) -> None:
        was, self.shown = self.shown, state
        changed = lambda *keys: any(was.get(k) != state.get(k) for k in keys)
        if changed("x", "y", "w", "h"):
            self._place(state, animate=bool(was))
        if changed("visible"):
            self._fade(state["visible"])
        if changed("dark"):
            self._appearance(state["dark"])
        if changed("left"):
            self.left.setStringValue_(state["left"])
        if changed("right"):
            self.right.setStringValue_(state["right"])
        if not self.dragging:
            self.slider.setMaxValue_(max(1, state["max"]))
            self.slider.setDoubleValue_(state["value"])
        if changed("playing"):
            self._icon = "pause.fill" if state["playing"] else "play.fill"
            self.play.setImage_(_symbol(self._icon, 24))
        if changed("loading"):
            self.play.setAlphaValue_(0.6 if state["loading"] else 1.0)
        if changed("speed"):
            self.items["speed-btn"].setImage_(_row_text(state["speed"]))
        if changed("sleep"):
            self.items["sleep-btn"].setTitle_(state["sleep"])
        if changed("sleepOn", "textOn", "tocOn", "dark"):
            on = {"sleep-btn": state["sleepOn"], "text-btn": state["textOn"], "toc-btn": state["tocOn"], "speed-btn": False}
            fill = (AppKit.NSColor.whiteColor() if state["dark"] else AppKit.NSColor.blackColor()).colorWithAlphaComponent_(0.14).CGColor()
            for ident, pill in self.pills.items():
                pill.layer().setBackgroundColor_(fill if on[ident] else None)

    def _appearance(self, dark: bool) -> None:
        self.glass.setAppearance_(AppKit.NSAppearance.appearanceNamed_(AppKit.NSAppearanceNameDarkAqua if dark else AppKit.NSAppearanceNameAqua))
        # The big button is solid, as everywhere: the page's ink, with the icon cut out of it.
        self.play.layer().setBackgroundColor_((AppKit.NSColor.whiteColor() if dark else AppKit.NSColor.blackColor()).CGColor())
        self.play.setContentTintColor_(AppKit.NSColor.blackColor() if dark else AppKit.NSColor.whiteColor())

    def _fade(self, visible: bool) -> None:
        if visible:
            self.glass.setAlphaValue_(0.0)
            self.glass.setHidden_(False)

        def animate(context):
            context.setDuration_(FADE_SECONDS)
            self.glass.animator().setAlphaValue_(1.0 if visible else 0.0)

        def done():
            if not self.shown.get("visible"):
                self.glass.setHidden_(True)

        AppKit.NSAnimationContext.runAnimationGroup_completionHandler_(animate, done)

    def _place(self, state: dict, animate: bool) -> None:
        frame = NSMakeRect(state["x"], state["y"], state["w"], state["h"])
        if animate and self.glass.frame().size.width != state["w"]:  # a side panel opened: it moves over, as they slide
            def run(context):
                context.setDuration_(0.22)
                self.glass.animator().setFrame_(frame)

            AppKit.NSAnimationContext.runAnimationGroup_completionHandler_(run, None)
        else:
            self.glass.setFrame_(frame)
        self._layout(state["w"], state["h"])

    def _layout(self, w: float, h: float) -> None:
        self.content.setFrame_(NSMakeRect(0, 0, w, h))
        inner = w - 2 * SIDE
        self.slider.setFrame_(NSMakeRect(SIDE, 8, inner, 20))
        self.left.setFrame_(NSMakeRect(SIDE, 30, inner / 2, 15))
        self.right.setFrame_(NSMakeRect(w / 2, 30, inner / 2, 15))
        middle = 78
        self.play.setFrame_(NSMakeRect(w / 2 - 30, middle - 30, 60, 60))
        self.prev.setFrame_(NSMakeRect(w / 2 - 30 - 40 - 46, middle - 23, 46, 46))
        self.next.setFrame_(NSMakeRect(w / 2 + 30 + 40, middle - 23, 46, 46))
        step = inner / len(ROW_ITEMS)
        top = h - 56
        for i, (ident, _, _) in enumerate(ROW_ITEMS):
            x = SIDE + i * step
            self.items[ident].setFrame_(NSMakeRect(x, top, step, 50))
            self.pills[ident].setFrame_(NSMakeRect(x + step / 2 - 23, top - 4, 46, 28))

    # ---------------------------------------------------------------- what the person does

    def js(self, code: str) -> None:
        self.web.evaluateJavaScript_completionHandler_(code, None)

    def press(self, ident: str) -> None:
        self.js(f"document.getElementById({json.dumps(ident)}).click()")

    def slid(self, slider) -> None:
        value = round(slider.doubleValue())
        ended = AppKit.NSApp.currentEvent().type() == AppKit.NSEventTypeLeftMouseUp or not AppKit.NSEvent.pressedMouseButtons() & 1
        self.dragging = not ended
        self.js(f"glassScrub({value}, {'true' if ended else 'false'})")

    def menu(self, spec: dict) -> None:
        """A native menu at the page's button; it says which item was picked, if any."""
        menu = AppKit.NSMenu.alloc().init()
        menu.setAutoenablesItems_(False)
        chosen: list[int] = []
        picker = _MenuTarget.alloc().initWithChosen_(chosen)
        for i, it in enumerate(spec["items"]):
            if it is None:
                menu.addItem_(AppKit.NSMenuItem.separatorItem())
                continue
            item = menu.addItemWithTitle_action_keyEquivalent_(it["label"], "picked:", "")
            item.setTarget_(picker)
            item.setTag_(i)
            item.setEnabled_(not it.get("disabled"))
            if it.get("note") == "✓":
                item.setState_(AppKit.NSControlStateValueOn)
            elif it.get("note"):
                item.setBadge_(AppKit.NSMenuItemBadge.alloc().initWithString_(it["note"]))
            if it.get("danger"):
                item.setAttributedTitle_(AppKit.NSAttributedString.alloc().initWithString_attributes_(
                    it["label"], {AppKit.NSForegroundColorAttributeName: AppKit.NSColor.systemRedColor()}))
            if it.get("dot"):
                item.setImage_(_dot(it["dot"]))
        # Above a button low in the window, as the player's are; below one anywhere else.
        y = spec["y"] + spec["h"] + 4
        if y + menu.size().height > self.web.bounds().size.height - 8:
            y = spec["y"] - menu.size().height - 4
        menu.popUpMenuPositioningItem_atLocation_inView_(None, NSMakePoint(spec["x"], y), self.web)  # returns once it's closed
        self.js(f"glassMenuClosed({chosen[0] if chosen else -1})")


class _MenuTarget(NSObject):
    def initWithChosen_(self, chosen):
        self = objc.super(_MenuTarget, self).init()
        self.chosen = chosen
        return self

    def picked_(self, sender):
        self.chosen.append(int(sender.tag()))


def _dot(css: str) -> AppKit.NSImage:
    """A character's colour, "#rrggbb" or "hsl(…)": the system turns any it can't read into grey."""
    colour = _colour(css)

    def draw(rect):
        colour.setFill()
        AppKit.NSBezierPath.bezierPathWithOvalInRect_(rect).fill()
        return True

    return AppKit.NSImage.imageWithSize_flipped_drawingHandler_((9, 9), False, draw)


def _colour(css: str) -> AppKit.NSColor:
    text = css.strip().lstrip("#")
    if len(text) == 6:
        try:
            r, g, b = (int(text[i:i + 2], 16) / 255 for i in (0, 2, 4))
            return AppKit.NSColor.colorWithSRGBRed_green_blue_alpha_(r, g, b, 1)
        except ValueError:
            pass
    return AppKit.NSColor.secondaryLabelColor()


def start(window) -> Player | None:
    """Puts the player in the window, from the main thread. None if this Mac can't."""
    made: list[Player | None] = []
    ready = threading.Event()

    def build():
        try:
            made.append(Player(window) if available() else None)
        except Exception as e:  # the page's own player still works
            print(f"No native glass player: {type(e).__name__}: {e}")
            made.append(None)
        ready.set()

    AppHelper.callAfter(build)
    ready.wait(10)
    return made[0] if made else None
