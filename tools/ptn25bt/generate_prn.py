#!/usr/bin/env python3
"""Generate simple Brother raster command streams for PT-N25BT experiments."""

from __future__ import annotations

import argparse
import math
import struct
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps

DPI = 180
MM_PER_INCH = 25.4
DEFAULT_FEED_MARGIN_MM = 0.0
DEFAULT_TRAILING_PAD_MM = 13.4

PIXEL_FONT_5X7 = {
    " ": ["00000", "00000", "00000", "00000", "00000", "00000", "00000"],
    "-": ["00000", "00000", "00000", "11110", "00000", "00000", "00000"],
    ".": ["00000", "00000", "00000", "00000", "00000", "01100", "01100"],
    "/": ["00001", "00010", "00010", "00100", "01000", "01000", "10000"],
    ":": ["00000", "01100", "01100", "00000", "01100", "01100", "00000"],
    "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
    "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
    "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
    "3": ["11110", "00001", "00001", "01110", "00001", "00001", "11110"],
    "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
    "5": ["11111", "10000", "10000", "11110", "00001", "00001", "11110"],
    "6": ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
    "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
    "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
    "9": ["01110", "10001", "10001", "01111", "00001", "00010", "01100"],
    "A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
    "B": ["11110", "10001", "10001", "11110", "10001", "10001", "11110"],
    "C": ["01111", "10000", "10000", "10000", "10000", "10000", "01111"],
    "D": ["11110", "10001", "10001", "10001", "10001", "10001", "11110"],
    "E": ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
    "F": ["11111", "10000", "10000", "11110", "10000", "10000", "10000"],
    "G": ["01111", "10000", "10000", "10011", "10001", "10001", "01111"],
    "H": ["10001", "10001", "10001", "11111", "10001", "10001", "10001"],
    "I": ["01110", "00100", "00100", "00100", "00100", "00100", "01110"],
    "J": ["00111", "00010", "00010", "00010", "00010", "10010", "01100"],
    "K": ["10001", "10010", "10100", "11000", "10100", "10010", "10001"],
    "L": ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
    "M": ["10001", "11011", "10101", "10101", "10001", "10001", "10001"],
    "N": ["10001", "11001", "10101", "10011", "10001", "10001", "10001"],
    "O": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
    "P": ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
    "Q": ["01110", "10001", "10001", "10001", "10101", "10010", "01101"],
    "R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
    "S": ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
    "T": ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
    "U": ["10001", "10001", "10001", "10001", "10001", "10001", "01110"],
    "V": ["10001", "10001", "10001", "10001", "10001", "01010", "00100"],
    "W": ["10001", "10001", "10001", "10101", "10101", "10101", "01010"],
    "X": ["10001", "10001", "01010", "00100", "01010", "10001", "10001"],
    "Y": ["10001", "10001", "01010", "00100", "00100", "00100", "00100"],
    "Z": ["11111", "00001", "00010", "00100", "01000", "10000", "11111"],
}

Box = tuple[int, int, int, int]


def pixel_text_box(
    xy: tuple[int, int],
    text: str,
    scale: int = 1,
    tracking: int = 1,
) -> Box:
    width, height = pixel_text_size(text, scale=scale, tracking=tracking)
    x, y = xy
    return (x, y, x + width - 1, y + height - 1)


def expand_box(box: Box, padding_px: int) -> Box:
    x0, y0, x1, y1 = box
    return (x0 - padding_px, y0 - padding_px, x1 + padding_px, y1 + padding_px)


def boxes_overlap(a: Box, b: Box) -> bool:
    return max(a[0], b[0]) <= min(a[2], b[2]) and max(a[1], b[1]) <= min(a[3], b[3])


def assert_boxes_clear(labeled_boxes: list[tuple[str, Box]], padding_px: int = 4) -> None:
    """Reject layouts where labeled elements collide or crowd each other."""
    for index, (left_label, left_box) in enumerate(labeled_boxes):
        padded_left = expand_box(left_box, padding_px)
        for right_label, right_box in labeled_boxes[index + 1 :]:
            if boxes_overlap(padded_left, right_box):
                raise ValueError(
                    f"layout collision: {left_label} {left_box} is within "
                    f"{padding_px}px of {right_label} {right_box}"
                )


def packbits_encode(data: bytes) -> bytes:
    out = bytearray()
    i = 0
    n = len(data)
    while i < n:
        run = 1
        while i + run < n and run < 128 and data[i + run] == data[i]:
            run += 1
        # Brother's raster reference encodes even 2-byte repeats as runs.
        if run >= 2:
            out.append(257 - run)
            out.append(data[i])
            i += run
            continue

        literal_start = i
        i += run
        while i < n:
            run = 1
            while i + run < n and run < 128 and data[i + run] == data[i]:
                run += 1
            if run >= 2 or i - literal_start >= 128:
                break
            i += run
        literal = data[literal_start:i]
        out.append(len(literal) - 1)
        out.extend(literal)
    return bytes(out)


def command(op: bytes, payload: bytes = b"") -> bytes:
    return op + payload


def raster_line(line: bytes, compress: bool = True) -> bytes:
    if line == b"\x00" * len(line):
        return b"Z"
    if compress:
        encoded = packbits_encode(line)
        return b"G" + struct.pack("<H", len(encoded)) + encoded
    return b"G" + struct.pack("<H", len(line)) + line


def mm_to_dots(mm: float) -> int:
    return round(mm / MM_PER_INCH * DPI)


def load_font(paths: list[str], size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    for path in paths:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def to_1bpp(image: Image.Image) -> Image.Image:
    return image.convert("L").point(lambda pixel: 255 if pixel >= 128 else 0, mode="1")


def pixel_text_size(text: str, scale: int = 1, tracking: int = 1) -> tuple[int, int]:
    chars = [char.upper() for char in text]
    width = 0
    for char in chars:
        glyph = PIXEL_FONT_5X7.get(char, PIXEL_FONT_5X7[" "])
        width += len(glyph[0]) * scale + tracking
    return max(0, width - tracking), 7 * scale


def draw_pixel_text(
    draw: ImageDraw.ImageDraw,
    xy: tuple[int, int],
    text: str,
    fill: int,
    scale: int = 1,
    tracking: int = 1,
) -> None:
    cursor_x, start_y = xy
    for char in text.upper():
        glyph = PIXEL_FONT_5X7.get(char, PIXEL_FONT_5X7[" "])
        for row_index, row in enumerate(glyph):
            for col_index, value in enumerate(row):
                if value == "1":
                    x0 = cursor_x + col_index * scale
                    y0 = start_y + row_index * scale
                    draw.rectangle((x0, y0, x0 + scale - 1, y0 + scale - 1), fill=fill)
        cursor_x += len(glyph[0]) * scale + tracking


def text_image(text: str, length_px: int, height_px: int) -> Image.Image:
    image = Image.new("L", (length_px, height_px), 255)
    draw = ImageDraw.Draw(image)
    font_paths = [
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ]
    for size in range(height_px - 10, 8, -1):
        font = load_font(font_paths, size)
        bbox = draw.textbbox((0, 0), text, font=font)
        if bbox[2] - bbox[0] <= length_px - 24 and bbox[3] - bbox[1] <= height_px - 8:
            break
    bbox = draw.textbbox((0, 0), text, font=font)
    x = (length_px - (bbox[2] - bbox[0])) // 2 - bbox[0]
    y = (height_px - (bbox[3] - bbox[1])) // 2 - bbox[1]
    draw.text((x, y), text, fill=0, font=font)
    return image


def border_image(length_px: int, height_px: int, border_px: int = 1) -> Image.Image:
    image = Image.new("L", (length_px, height_px), 255)
    draw = ImageDraw.Draw(image)
    for inset in range(border_px):
        draw.rectangle((inset, inset, length_px - 1 - inset, height_px - 1 - inset), outline=0)
    return image


def star_points(cx: int, cy: int, outer: int, inner: int) -> list[tuple[int, int]]:
    points = []
    for i in range(10):
        radius = outer if i % 2 == 0 else inner
        angle = -90 + i * 36
        radians = angle * math.pi / 180
        points.append((round(cx + radius * math.cos(radians)), round(cy + radius * math.sin(radians))))
    return points


def draw_hatched_box(
    draw: ImageDraw.ImageDraw,
    box: tuple[int, int, int, int],
    start_x: int | None = None,
    stop_x: int | None = None,
    step: int = 18,
    span: int = 14,
    inset: int = 6,
    fill: int = 0,
    width: int = 2,
) -> None:
    x0, y0, x1, y1 = box
    start = x0 + inset if start_x is None else start_x
    stop = x1 - inset - span + 1 if stop_x is None else stop_x
    stop = min(stop, x1 - inset - span + 1)
    for x in range(start, stop, step):
        draw.line((x, y1 - inset, x + span, y0 + inset), fill=fill, width=width)
    draw.rectangle(box, outline=fill, width=2)


def showoff_image(length_px: int, height_px: int) -> Image.Image:
    image = Image.new("L", (length_px, height_px), 255)
    draw = ImageDraw.Draw(image)

    draw.rectangle((0, 0, length_px - 1, height_px - 1), outline=0)

    draw.rounded_rectangle((4, 4, 94, height_px - 5), radius=8, fill=0)
    draw.rounded_rectangle((9, 9, 89, height_px - 10), radius=5, outline=255, width=1)
    draw.polygon([(20, 13), (44, 13), (35, 28), (50, 28), (24, 52), (32, 35), (17, 35)], fill=255)
    draw.line((53, 12, 53, 51), fill=255, width=1)
    draw_pixel_text(draw, (61, 13), "BLE", fill=255, scale=1, tracking=1)
    draw_pixel_text(draw, (61, 27), "180", fill=255, scale=1, tracking=1)
    draw_pixel_text(draw, (61, 41), "DPI", fill=255, scale=1, tracking=1)

    draw.rectangle((101, 4, 105, height_px - 5), fill=0)
    draw_pixel_text(draw, (116, 5), "CODEX", fill=0, scale=6, tracking=2)
    draw.rectangle((112, 50, 393, 61), fill=0)
    footer = "PT-N25BT / BLE RASTER / 1BPP"
    footer_width, _ = pixel_text_size(footer, scale=1, tracking=1)
    draw_pixel_text(draw, (112 + (281 - footer_width) // 2, 53), footer, fill=255, scale=1, tracking=1)

    draw_hatched_box(draw, (286, 7, 395, 44), start_x=298, step=18, span=14, inset=6)

    panel_x = length_px - 149
    draw_hatched_box(
        draw,
        (panel_x, 7, length_px - 8, 56),
        start_x=panel_x + 11,
        stop_x=panel_x + 72,
        step=16,
        span=18,
        inset=6,
    )
    badge_x = length_px - 61
    draw.ellipse((badge_x, 10, badge_x + 43, 53), outline=0, width=3)
    draw.polygon(star_points(badge_x + 22, 32, 15, 6), fill=0)
    draw.polygon(star_points(badge_x + 22, 32, 7, 3), fill=255)
    for y in range(12, 54, 10):
        draw.line((length_px - 11, y, length_px - 5, y), fill=0, width=2)

    return image


def margin_test_image(text: str, length_px: int, height_px: int, border_px: int = 2) -> Image.Image:
    image = border_image(length_px=length_px, height_px=height_px, border_px=border_px)
    draw = ImageDraw.Draw(image)

    lead = "LEAD"
    trail = "TRAIL"
    trail_width, _ = pixel_text_size(trail, scale=1, tracking=1)
    center_width, _ = pixel_text_size(text, scale=2, tracking=2)
    feed_width, _ = pixel_text_size("FEED", scale=1, tracking=1)

    draw_pixel_text(draw, (8, 8), lead, fill=0, scale=1, tracking=1)
    draw.polygon([(6, 35), (18, 27), (18, 43)], fill=0)
    draw.rectangle((18, 32, 32, 38), fill=0)

    draw_pixel_text(draw, (length_px - trail_width - 8, 8), trail, fill=0, scale=1, tracking=1)
    draw.polygon([(length_px - 7, 35), (length_px - 19, 27), (length_px - 19, 43)], fill=0)
    draw.rectangle((length_px - 33, 32, length_px - 19, 38), fill=0)

    draw.rectangle((42, 20, length_px - 43, 49), outline=0, width=1)
    draw_pixel_text(draw, ((length_px - center_width) // 2, 24), text, fill=0, scale=2, tracking=2)
    draw_pixel_text(draw, ((length_px - feed_width) // 2, 53), "FEED", fill=0, scale=1, tracking=1)

    return image


def label_image(
    text: str,
    length_px: int,
    printable_px: int,
    calibration: str | None = None,
    border_px: int = 1,
) -> Image.Image:
    if calibration == "border":
        return to_1bpp(border_image(length_px=length_px, height_px=printable_px, border_px=border_px))
    if calibration == "margin-test":
        return to_1bpp(margin_test_image(text, length_px=length_px, height_px=printable_px, border_px=border_px))
    if calibration == "showoff":
        return to_1bpp(showoff_image(length_px=length_px, height_px=printable_px))
    return to_1bpp(text_image(text, length_px=length_px, height_px=printable_px))


def add_trailing_padding(image: Image.Image, pad_px: int) -> Image.Image:
    if pad_px <= 0:
        return image
    padded = Image.new(image.mode, (image.width + pad_px, image.height), 255)
    padded.paste(image, (0, 0))
    return padded


def image_to_raster_bytes(image: Image.Image, head_px: int, offset_px: int | None = None) -> bytes:
    mono = to_1bpp(image)
    mono = ImageOps.invert(mono.convert("L")).convert("1", dither=Image.Dither.NONE)
    mono = mono.rotate(-90, expand=True)
    mono = ImageOps.mirror(mono)
    width, height = mono.size
    if width > head_px:
        raise ValueError(f"image is {width}px tall after rotation, exceeds {head_px}px head")
    if offset_px is None:
        offset_px = (head_px - width) // 2
    if offset_px < 0 or offset_px + width > head_px:
        raise ValueError(f"offset {offset_px}px places {width}px image outside {head_px}px head")
    padded = Image.new("1", (head_px, height))
    padded.paste(mono, (offset_px, 0))
    return padded.tobytes()


def build_prn(
    text: str,
    length_px: int,
    compress: bool,
    head_px: int,
    printable_px: int,
    offset_px: int,
    margin_dots: int,
    page_mode: int,
    calibration: str | None = None,
    border_px: int = 1,
    trailing_pad_dots: int = 0,
) -> bytes:
    line_bytes = head_px // 8
    image = label_image(text, length_px, printable_px, calibration, border_px)
    image = add_trailing_padding(image, trailing_pad_dots)
    raster = image_to_raster_bytes(image, head_px=head_px, offset_px=offset_px)
    raster_lines = len(raster) // line_bytes

    out = bytearray()
    out.extend(b"\x00" * 64)
    out.extend(command(b"\x1b@"))
    out.extend(command(b"\x1bia", b"\x01"))

    active_fields = (1 << 2) | (1 << 6) | (1 << 7)
    out.extend(command(b"\x1biz", struct.pack("<4BI2B", active_fields, 0x03, 12, 0, raster_lines, page_mode, 0)))
    out.extend(command(b"\x1biK", b"\x08"))
    out.extend(command(b"\x1biM", b"\x00"))
    out.extend(command(b"\x1bid", struct.pack("<H", margin_dots)))
    out.extend(command(b"M", b"\x02" if compress else b"\x00"))

    for offset in range(0, len(raster), line_bytes):
        out.extend(raster_line(raster[offset : offset + line_bytes], compress=compress))

    out.extend(command(b"\x1a"))
    return bytes(out)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("--text", default="CODEX")
    parser.add_argument("--length-px", type=int, default=320)
    parser.add_argument("--head-px", type=int, default=128)
    parser.add_argument("--printable-px", type=int, default=64)
    parser.add_argument("--offset-px", type=int, default=0)
    parser.add_argument("--margin-mm", type=float, default=DEFAULT_FEED_MARGIN_MM)
    parser.add_argument("--margin-dots", type=int, help="Override Brother feed/margin amount in dots")
    parser.add_argument(
        "--trailing-pad-mm",
        type=float,
        default=DEFAULT_TRAILING_PAD_MM,
        help="Append printer-specific blank raster columns after the artwork; not included in previews",
    )
    parser.add_argument("--trailing-pad-dots", type=int, help="Override blank raster padding after artwork in dots")
    parser.add_argument("--page-mode", type=int, default=2, choices=(0, 1, 2))
    parser.add_argument("--compress", action="store_true", help="Use experimental TIFF/PackBits compression")
    parser.add_argument("--calibration", choices=("border", "margin-test", "showoff"), help="Generate a built-in pattern instead of text")
    parser.add_argument("--border-px", type=int, default=1, help="Border thickness for --calibration border")
    parser.add_argument("--preview-png", type=Path, help="Save the source label image before raster rotation")
    args = parser.parse_args()

    if args.head_px % 8:
        raise SystemExit("--head-px must be divisible by 8")
    if args.printable_px > args.head_px:
        raise SystemExit("--printable-px must be less than or equal to --head-px")

    margin_dots = args.margin_dots if args.margin_dots is not None else mm_to_dots(args.margin_mm)
    trailing_pad_dots = (
        args.trailing_pad_dots if args.trailing_pad_dots is not None else mm_to_dots(args.trailing_pad_mm)
    )
    if args.preview_png:
        preview = label_image(args.text, args.length_px, args.printable_px, args.calibration, args.border_px)
        args.preview_png.parent.mkdir(parents=True, exist_ok=True)
        preview.save(args.preview_png)

    data = build_prn(
        args.text,
        args.length_px,
        args.compress,
        args.head_px,
        args.printable_px,
        args.offset_px,
        margin_dots,
        args.page_mode,
        args.calibration,
        args.border_px,
        trailing_pad_dots,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(data)
    print(
        f"wrote {len(data)} bytes to {args.output} "
        f"(feed_margin_dots={margin_dots} trailing_pad_dots={trailing_pad_dots})"
    )


if __name__ == "__main__":
    main()
