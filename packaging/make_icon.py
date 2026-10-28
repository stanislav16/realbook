"""Draw the RealBook app icon and write packaging/RealBook.icns (run with the project's Python)."""

import shutil
import subprocess
import sys
from pathlib import Path

from AppKit import (
    NSBezierPath,
    NSFont,
    NSFontAttributeName,
    NSForegroundColorAttributeName,
    NSMakeSize,
    NSShadow,
    NSString,
    NSBitmapImageRep,
    NSColor,
    NSCompositingOperationSourceOver,
    NSGradient,
    NSGraphicsContext,
    NSImage,
    NSMakeRect,
    NSPNGFileType,
)

HERE = Path(__file__).resolve().parent
SIZE = 1024


def _rgb(r: int, g: int, b: int, a: float = 1.0):
    return NSColor.colorWithCalibratedRed_green_blue_alpha_(r / 255, g / 255, b / 255, a)


def draw() -> NSBitmapImageRep:
    """A bold serif opening quotation mark in ink on warm paper: books, and the voices in them."""
    rep = NSBitmapImageRep.alloc().initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bytesPerRow_bitsPerPixel_(
        None, SIZE, SIZE, 8, 4, True, False, "NSCalibratedRGBColorSpace", 0, 0
    )
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.setCurrentContext_(NSGraphicsContext.graphicsContextWithBitmapImageRep_(rep))

    # macOS icon grid: an 824pt rounded square centred in 1024, with a soft drop shadow.
    inset = 100
    shape = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
        NSMakeRect(inset, inset, SIZE - 2 * inset, SIZE - 2 * inset), 185, 185
    )
    shadow = NSShadow.alloc().init()
    shadow.setShadowOffset_(NSMakeSize(0, -10))
    shadow.setShadowBlurRadius_(28)
    shadow.setShadowColor_(_rgb(0, 0, 0, 0.28))
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    _rgb(250, 247, 240).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient.alloc().initWithStartingColor_endingColor_(_rgb(236, 230, 218), _rgb(250, 247, 240)).drawInBezierPath_angle_(shape, 90)

    font = NSFont.fontWithName_size_("Georgia-Bold", 760) or NSFont.boldSystemFontOfSize_(760)
    attrs = {NSFontAttributeName: font, NSForegroundColorAttributeName: _rgb(28, 27, 26)}
    quote = NSString.stringWithString_("\u201c")
    size = quote.sizeWithAttributes_(attrs)
    quote.drawAtPoint_withAttributes_((SIZE / 2 + 6 - size.width / 2, SIZE / 2 - 150 - size.height / 2), attrs)
    NSGraphicsContext.restoreGraphicsState()
    return rep


def main() -> None:
    png = HERE / "icon_1024.png"
    draw().representationUsingType_properties_(NSPNGFileType, None).writeToFile_atomically_(str(png), True)
    iconset = HERE / "RealBook.iconset"
    shutil.rmtree(iconset, ignore_errors=True)
    iconset.mkdir()
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = size * scale
            name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
            subprocess.run(["sips", "-z", str(px), str(px), str(png), "--out", str(iconset / name)], check=True, capture_output=True)
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(HERE / "RealBook.icns")], check=True)
    shutil.rmtree(iconset)
    print("wrote", HERE / "RealBook.icns")


if __name__ == "__main__":
    sys.exit(main())
