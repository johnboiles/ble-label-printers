#!/usr/bin/env python3
"""Generate a single-copy NIIMBOT B21S JSON job and true 1bpp previews.

At 8 dots/mm, the 384-dot head prints at most 48 mm across 50 mm stock.
Protocol reference: https://github.com/MultiMote/niimbluelib
B21S six-byte page size: https://github.com/AndBondStyle/niimprint/issues/33
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps

DOTS_PER_MM = 8
PRINTHEAD_PIXELS = 384
LABEL_TYPES = (1, 2, 3, 5)  # Gap, black mark, continuous, transparent.
MARGIN = 12
MIN_FONT_SIZE = 12


def frame(command, data):
    """Frame one command, including Connect's extra 0x03 prefix."""
    body = bytes([command, len(data), *data])
    checksum = 0
    for value in body:
        checksum ^= value
    prefix = b"\x03" if command == 0xC1 else b""
    return (prefix + b"\x55\x55" + body + bytes([checksum]) + b"\xaa\xaa").hex()


def step(name, command, data, response=None, **kwargs):
    result = {"name": name, "hex": frame(command, data), "delay": 0.06, **kwargs}
    if response is not None:
        result["expect"] = response
    return result


def be16(n):
    return [n >> 8, n & 255]


def make_job(image, label_type=1, density=3):
    """Encode a one-bit image using the verified single-copy B21S sequence.

    Pillow's mode 1 stores white as 1; the printer stores black as 1.
    This function only generates data. It never connects to a printer.
    """
    width, height = image.size
    if image.mode != "1":
        raise ValueError("image must use one-bit mode '1'")
    if not 0 < width <= PRINTHEAD_PIXELS or width % 8:
        raise ValueError("image width must be a positive multiple of 8, at most 384 pixels")
    if not 0 < height <= 65535:
        raise ValueError("image height must fit a positive 16-bit row count")
    if not isinstance(density, int) or not 1 <= density <= 5:
        raise ValueError("density must be an integer from 1 to 5")
    if label_type not in LABEL_TYPES:
        raise ValueError("label type must be 1 (gap), 2 (black mark), 3 (continuous), or 5 (transparent)")
    job = [
        step("connect", 0xC1, [1], 0xC2),
        step("verify B21S", 0x40, [8], 0x48, expectData="0309"),
        step(f"density {density}", 0x21, [density], 0x31, expectPrefix="01"),
        step("label type", 0x23, [label_type], 0x33, expectPrefix="01"),
        step("start single-label job", 0x01, [1], 0x02, expectPrefix="01"),
        step("clear buffer", 0x20, [1], 0x30, expectPrefix="01"),
        step("page start", 0x03, [1], 0x04, expectPrefix="01"),
        # Four-byte size is ACKed but produces a blank label over BLE.
        # Rows, columns, and copies must all be big-endian 16-bit values.
        step("page size with one copy", 0x13, be16(height) + be16(width) + be16(1),
             0x14, expectPrefix="01"),
        step("exactly one copy", 0x15, [0, 1], 0x16, expectPrefix="01"),
    ]
    raw = image.tobytes()
    stride = width // 8
    for row in range(height):
        bitmap = bytes(b ^ 255 for b in raw[row * stride:(row + 1) * stride])
        if any(bitmap):
            counts = [sum(b.bit_count() for b in bitmap[i:i + 16]) for i in (0, 16, 32)]
            job.append(step(f"row {row}", 0x85, be16(row) + counts + [1] + list(bitmap), delay=0.015))
        else:
            job.append(step(f"blank row {row}", 0x84, be16(row) + [1], delay=0.015))
    job += [
        step("page end", 0xE3, [1], 0xE4, expectPrefix="01", delay=0.5),
        step("wait for one completed label", 0xA3, [1], 0xB3,
             repeatUntilPrefix="00016464", maxAttempts=60, delay=0.5, timeout=5),
        step("end job", 0xF3, [1], 0xF4, expectPrefix="01"),
    ]
    return job


def label_size(width_mm, height_mm):
    """Validate stock size and return pixels within the physical printhead."""
    if not math.isfinite(width_mm) or not 20 <= width_mm <= 50:
        raise ValueError("label width must be between 20 and 50 mm")
    if not math.isfinite(height_mm) or not 15 <= height_mm <= 200:
        raise ValueError("label height must be between 15 and 200 mm")
    # Round width down to complete bytes so fractional widths never overflow
    # the stock. Widths above 48 mm share the same 384-dot printhead limit.
    return min(PRINTHEAD_PIXELS, math.floor(width_mm) * 8), round(height_mm * DOTS_PER_MM)


def on_white(image):
    """Composite transparency before converting to grayscale."""
    rgba = image.convert("RGBA")
    background = Image.new("RGBA", rgba.size, "white")
    background.alpha_composite(rgba)
    return background.convert("L")


def one_bit(image):
    return on_white(image).point(lambda p: 255 if p >= 128 else 0, mode="1")


def read_image(path):
    try:
        with Image.open(path) as image:
            return on_white(ImageOps.exif_transpose(image))
    except (OSError, ValueError) as exc:
        raise ValueError(f"cannot read image {path}: {exc}") from exc


def fit_image(image, size):
    """Fit an image onto the full canvas, preserving its aspect ratio."""
    canvas = Image.new("L", size, 255)
    fitted = ImageOps.contain(on_white(image), size, Image.Resampling.LANCZOS)
    canvas.paste(fitted, ((size[0] - fitted.width) // 2, (size[1] - fitted.height) // 2))
    return one_bit(canvas)


def text_mask(text, size, font_path=None):
    """Render tight ink bounds, accounting for negative bearings/descenders."""
    scale_bitmap = False
    if font_path is not None:
        try:
            font = ImageFont.truetype(str(font_path), size)
        except (OSError, ValueError) as exc:
            raise ValueError(f"cannot load font {font_path}: {exc}") from exc
    else:
        try:
            font = ImageFont.truetype("DejaVuSans-Bold.ttf", size)
        except OSError:
            try:
                font = ImageFont.load_default(size=size)
            except TypeError:  # Pillow 10.0 has only a fixed-size default font.
                font = ImageFont.load_default()
                scale_bitmap = True
    spacing = max(1, (11 if scale_bitmap else size) // 8)
    draw = ImageDraw.Draw(Image.new("L", (1, 1)))
    try:
        bounds = draw.multiline_textbbox((0, 0), text, font=font, spacing=spacing, align="center")
        box = (math.floor(bounds[0]), math.floor(bounds[1]),
               math.ceil(bounds[2]), math.ceil(bounds[3]))
        mask = Image.new("L", (max(1, box[2] - box[0]), max(1, box[3] - box[1])))
        ImageDraw.Draw(mask).multiline_text((-box[0], -box[1]), text, font=font,
                                          spacing=spacing, align="center", fill=255)
    except (UnicodeError, ValueError) as exc:
        raise ValueError(f"cannot render text with this font; try --font PATH: {exc}") from exc
    ink = mask.getbbox()
    if ink is None:
        raise ValueError("text must contain visible characters supported by the font")
    mask = mask.crop(ink)
    if scale_bitmap:
        mask = mask.resize((max(1, round(mask.width * size / 11)),
                            max(1, round(mask.height * size / 11))), Image.Resampling.NEAREST)
    return mask


def draw_text_label(text, size, font_path=None, logo=None):
    text = text.strip()
    if not text:
        raise ValueError("text must not be empty")
    width, height = size
    canvas = Image.new("L", size, 255)
    text_top = MARGIN
    if logo is not None:
        logo_size = (round((width - MARGIN * 2) * 0.8),
                     round((height - MARGIN * 2) * 0.45))
        fitted = ImageOps.contain(on_white(logo), logo_size, Image.Resampling.LANCZOS)
        canvas.paste(fitted, ((width - fitted.width) // 2, MARGIN))
        text_top += fitted.height + MARGIN
    available_width = width - MARGIN * 2
    available_height = height - MARGIN - text_top
    low, high = MIN_FONT_SIZE, min(512, available_height * 2)
    best = None
    while low <= high:
        candidate = (low + high) // 2
        mask = text_mask(text, candidate, font_path)
        if mask.width <= available_width and mask.height <= available_height:
            best = mask
            low = candidate + 1
        else:
            high = candidate - 1
    if best is None:
        raise ValueError("text is too long to fit legibly; shorten it or add line breaks")
    canvas.paste(0, ((width - best.width) // 2,
                     text_top + (available_height - best.height) // 2), best)
    return one_bit(canvas)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="output JSON job (one copy only)")
    content = parser.add_mutually_exclusive_group(required=True)
    content.add_argument("--text", help="label text; explicit line breaks are supported")
    content.add_argument("--image", type=Path, help="image to fit within the printable canvas")
    parser.add_argument("--logo", type=Path, help="optional logo above --text")
    parser.add_argument("--width-mm", type=float, default=50,
                        help="stock width, 20–50 mm; printable width is capped at 48 mm (default: 50)")
    parser.add_argument("--height-mm", type=float, default=30, help="stock height, 15–200 mm (default: 30)")
    parser.add_argument("--density", type=int, choices=range(1, 6), default=3)
    parser.add_argument("--label-type", type=int, choices=LABEL_TYPES, default=1,
                        help="1 gap, 2 black mark, 3 continuous, 5 transparent (default: 1)")
    parser.add_argument("--font", type=Path, help="TrueType/OpenType font for --text")
    parser.add_argument("--preview-png", type=Path, help="preview path (default: output stem + .png)")
    args = parser.parse_args(argv)
    if args.image and (args.logo or args.font):
        parser.error("--logo and --font can only be used with --text")
    if args.output.suffix.lower() != ".json":
        parser.error("output must have a .json extension")
    preview = args.preview_png or args.output.with_suffix(".png")
    if preview.suffix.lower() != ".png":
        parser.error("--preview-png must have a .png extension")
    enlarged = preview.with_name(preview.stem + "-4x.png")
    inputs = {p.resolve() for p in (args.image, args.logo, args.font) if p is not None}
    if any(p.resolve() in inputs for p in (args.output, preview, enlarged)):
        parser.error("output would overwrite an input file; choose another output or --preview-png")
    try:
        size = label_size(args.width_mm, args.height_mm)
        if args.image:
            image = fit_image(read_image(args.image), size)
        else:
            image = draw_text_label(args.text, size, args.font,
                                    read_image(args.logo) if args.logo else None)
        job = make_job(image, args.label_type, args.density)
        for path in (args.output, preview, enlarged):
            path.parent.mkdir(parents=True, exist_ok=True)
        image.save(preview)
        image.resize((size[0] * 4, size[1] * 4), Image.Resampling.NEAREST).save(enlarged)
        args.output.write_text(json.dumps(job, indent=2) + "\n")
    except (OSError, ValueError) as exc:
        parser.error(str(exc))
    print(json.dumps({"job": str(args.output), "preview": str(preview),
                      "preview_4x": str(enlarged), "label_mm": [args.width_mm, args.height_mm],
                      "printable_pixels": size, "printable_width_mm": size[0] / DOTS_PER_MM,
                      "printhead_limited": args.width_mm > 48, "mode": image.mode,
                      "copies": 1, "steps": len(job)}))


if __name__ == "__main__":
    main()
