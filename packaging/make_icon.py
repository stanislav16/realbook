"""Draw the RealBook app icon and write packaging/RealBook.icns (run with the project's Python)."""

import shutil
import subprocess
import sys
from pathlib import Path

from AppKit import (
    NSBezierPath,
    NSBitmapImageRep,
    NSColor,
    NSCompositingOperationSourceOver,
    NSGradient,
    NSGraphicsContext,
    NSImage,
    NSImageSymbolConfiguration,
    NSMakeRect,
    NSPNGFileType,
)

HERE = Path(__file__).resolve().parent
SIZE = 1024


def _symbol(name: str, points: float, color, center: tuple[float, float]) -> None:
    config = NSImageSymbolConfiguration.configurationWithPointSize_weight_(points, 0.3)
    config = config.configurationByApplyingConfiguration_(NSImageSymbolConfiguration.configurationWithHierarchicalColor_(color))
    image = NSImage.imageWithSystemSymbolName_accessibilityDescription_(name, None).imageWithSymbolConfiguration_(config)
    w, h = image.size()
    image.drawInRect_fromRect_operation_fraction_(
        NSMakeRect(center[0] - w / 2, center[1] - h / 2, w, h), NSMakeRect(0, 0, 0, 0), NSCompositingOperationSourceOver, 1.0
    )


def draw() -> NSBitmapImageRep:
    rep = NSBitmapImageRep.alloc().initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bytesPerRow_bitsPerPixel_(
        None, SIZE, SIZE, 8, 4, True, False, "NSCalibratedRGBColorSpace", 0, 0
    )
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.setCurrentContext_(NSGraphicsContext.graphicsContextWithBitmapImageRep_(rep))

    # macOS icon grid: an 824pt rounded square centred in 1024.
    inset = 100
    shape = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
        NSMakeRect(inset, inset, SIZE - 2 * inset, SIZE - 2 * inset), 185, 185
    )
    top = NSColor.colorWithCalibratedRed_green_blue_alpha_(0.20, 0.27, 0.45, 1)
    bottom = NSColor.colorWithCalibratedRed_green_blue_alpha_(0.08, 0.11, 0.22, 1)
    NSGradient.alloc().initWithStartingColor_endingColor_(bottom, top).drawInBezierPath_angle_(shape, 90)

    _symbol("book.closed.fill", 400, NSColor.colorWithCalibratedRed_green_blue_alpha_(0.97, 0.94, 0.88, 1), (SIZE / 2 - 50, SIZE / 2 + 10))

    # A warm badge with a sound wave: the book is being read aloud.
    orange = NSColor.colorWithCalibratedRed_green_blue_alpha_(0.91, 0.50, 0.27, 1)
    orange.setFill()
    NSBezierPath.bezierPathWithOvalInRect_(NSMakeRect(560, 190, 270, 270)).fill()
    _symbol("waveform", 150, NSColor.whiteColor(), (695, 325))
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
