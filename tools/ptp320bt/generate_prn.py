#!/usr/bin/env python3
"""Generate PT-P320BT 12 mm raster jobs from text or 64-pixel-high artwork."""

from __future__ import annotations

import argparse
import struct
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps

PRINTABLE_PX = 64
MAX_LENGTH_PX = int(499 / 25.4 * 180)


def to_1bpp(image: Image.Image) -> Image.Image:
    rgba = image.convert("RGBA")
    white = Image.new("RGBA", rgba.size, "white")
    white.alpha_composite(rgba)
    return white.convert("L").point(lambda pixel: 255 if pixel >= 128 else 0, mode="1")


def build_prn(image: Image.Image) -> bytes:
    """Match the uncompressed job format captured from Design&Print 2.

    Transfer columns are 64 bits, top pixel first/MSB first, one for black.
    Blank columns use G as well: Z/PackBits have not been tested on this model.
    """
    if image.height != PRINTABLE_PX or not 1 <= image.width <= MAX_LENGTH_PX:
        raise ValueError(f"artwork must be 1..{MAX_LENGTH_PX} pixels wide and 64 pixels high")
    mono = to_1bpp(image)
    # Transpose to make each horizontal source column a packed transfer row.
    ink = ImageOps.invert(mono.convert("L")).convert("1", dither=Image.Dither.NONE)
    raster = ink.transpose(Image.Transpose.TRANSPOSE).tobytes()
    out = bytearray(100)
    out.extend(b"\x1bia\x01\x1b@")
    out.extend(b"\x1biz" + struct.pack("<4BI2B", 0xC4, 1, 12, 0, mono.width, 2, 0))
    # Preserve observed app settings; several model-specific fields are opaque.
    out.extend(bytes.fromhex("1b694b08 1b694d40 1b696b630100 1b69641c00 4d00 1b694c000101 1b694301ffffff"))
    for offset in range(0, len(raster), 8):
        out.extend(b"G\x08\x00" + raster[offset:offset + 8])
    out.append(0x1A)
    return bytes(out)


def text_image(text: str, length_px: int) -> Image.Image:
    if not text.strip():
        raise ValueError("text must not be empty")
    image = Image.new("L", (length_px, PRINTABLE_PX), 255)
    draw = ImageDraw.Draw(image)
    for size in range(48, 7, -1):
        font = ImageFont.load_default(size=size)
        box = draw.textbbox((0, 0), text, font=font)
        if box[2] - box[0] <= length_px - 16 and box[3] - box[1] <= PRINTABLE_PX - 8:
            break
    else:
        raise ValueError("text does not fit; increase --length-px or supply --image")
    draw.text(((length_px - box[2] + box[0]) // 2 - box[0],
               (PRINTABLE_PX - box[3] + box[1]) // 2 - box[1]), text, font=font, fill=0)
    return to_1bpp(image)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--text", default="HELLO")
    source.add_argument("--image", type=Path, help="64-pixel-high image; width is preserved")
    parser.add_argument("--length-px", type=int, default=320, help="Text canvas width (ignored with --image)")
    parser.add_argument("--preview-png", type=Path)
    args = parser.parse_args()
    outputs = [args.output]
    if args.preview_png:
        outputs.extend([args.preview_png, args.preview_png.with_name(args.preview_png.stem + "-4x.png")])
    if len({path.resolve() for path in outputs}) != len(outputs):
        parser.error("output and preview paths must be distinct")
    if args.image and args.image.resolve() in {path.resolve() for path in outputs}:
        parser.error("output paths must not overwrite the input image")
    try:
        if args.image:
            with Image.open(args.image) as source_image:
                image = to_1bpp(source_image)
        else:
            if not 1 <= args.length_px <= MAX_LENGTH_PX:
                raise ValueError(f"--length-px must be 1..{MAX_LENGTH_PX}")
            image = text_image(args.text, args.length_px)
        job = build_prn(image)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    if args.preview_png:
        args.preview_png.parent.mkdir(parents=True, exist_ok=True)
        image.save(args.preview_png)
        image.resize((image.width * 4, 256), Image.Resampling.NEAREST).save(
            args.preview_png.with_name(args.preview_png.stem + "-4x.png"))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(job)
    print(f"wrote {len(job)} bytes to {args.output} ({image.width} x 64 dots, 12 mm tape)")


if __name__ == "__main__":
    main()
