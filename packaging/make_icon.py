"""Draw the RealBook app icons (run with the project's Python).

Writes packaging/RealBook.icns for the Mac, and the full-bleed iPhone and web home-screen icons:
ios/RealBook/Assets.xcassets/AppIcon.appiconset/icon-1024.png, realbook/static/icon-180.png and icon-512.png.
"""

import shutil
import subprocess
import sys
from pathlib import Path

import Quartz
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
ROOT = HERE.parent
SIZE = 1024


def _rgb(r: int, g: int, b: int, a: float = 1.0):
    return NSColor.colorWithCalibratedRed_green_blue_alpha_(r / 255, g / 255, b / 255, a)


def draw(full_bleed: bool = False) -> NSBitmapImageRep:
    """A bold serif opening quotation mark in ink on warm paper: books, and the voices in them.

    The Mac icon is a rounded square with a shadow on a transparent canvas, as macOS expects. With
    full_bleed the paper fills the whole opaque square and nothing is rounded: iOS (and a web page
    saved to the home screen) cuts its own rounded shape, so any margin would show as a border.
    """
    NSGraphicsContext.saveGraphicsState()
    if full_bleed:
        # An RGB context with no alpha channel at all, so the PNG is opaque as iOS requires.
        cg = Quartz.CGBitmapContextCreate(
            None, SIZE, SIZE, 8, 0, Quartz.CGColorSpaceCreateWithName(Quartz.kCGColorSpaceSRGB), Quartz.kCGImageAlphaNoneSkipLast
        )
        NSGraphicsContext.setCurrentContext_(NSGraphicsContext.graphicsContextWithCGContext_flipped_(cg, False))
    else:
        rep = NSBitmapImageRep.alloc().initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bytesPerRow_bitsPerPixel_(
            None, SIZE, SIZE, 8, 4, True, False, "NSCalibratedRGBColorSpace", 0, 0
        )
        NSGraphicsContext.setCurrentContext_(NSGraphicsContext.graphicsContextWithBitmapImageRep_(rep))

    if full_bleed:
        tile = SIZE
        shape = NSBezierPath.bezierPathWithRect_(NSMakeRect(0, 0, SIZE, SIZE))
        _rgb(250, 247, 240).setFill()
        shape.fill()
    else:
        # macOS icon grid: an 824pt rounded square centred in 1024, with a soft drop shadow.
        inset = 100
        tile = SIZE - 2 * inset
        shape = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
            NSMakeRect(inset, inset, tile, tile), 185, 185
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

    # The mark keeps the same proportions to the tile in both shapes (designed on the 824pt tile).
    k = tile / 824
    font = NSFont.fontWithName_size_("Georgia-Bold", 760 * k) or NSFont.boldSystemFontOfSize_(760 * k)
    attrs = {NSFontAttributeName: font, NSForegroundColorAttributeName: _rgb(28, 27, 26)}
    quote = NSString.stringWithString_("\u201c")
    size = quote.sizeWithAttributes_(attrs)
    quote.drawAtPoint_withAttributes_((SIZE / 2 + 6 * k - size.width / 2, SIZE / 2 - 150 * k - size.height / 2), attrs)
    NSGraphicsContext.restoreGraphicsState()
    if full_bleed:
        rep = NSBitmapImageRep.alloc().initWithCGImage_(Quartz.CGBitmapContextCreateImage(cg))
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

    ios = ROOT / "ios/RealBook/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
    draw(full_bleed=True).representationUsingType_properties_(NSPNGFileType, None).writeToFile_atomically_(str(ios), True)
    print("wrote", ios)
    for px in (180, 512):
        web = ROOT / f"realbook/static/icon-{px}.png"
        subprocess.run(["sips", "-z", str(px), str(px), str(ios), "--out", str(web)], check=True, capture_output=True)
        print("wrote", web)


if __name__ == "__main__":
    sys.exit(main())
