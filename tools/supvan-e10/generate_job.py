#!/usr/bin/env python3
"""Generate a SUPVAN E10 compressed print job and true 1bpp preview."""

from __future__ import annotations

import argparse
import lzma
import struct
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

DPI_PER_MM = 8
PRINT_HEIGHT = 96
ART_HEIGHT = 88
BYTES_PER_COLUMN = 12
MAX_COLUMNS_PER_BUFFER = 332
BUFFER_SIZE = 4000
DEFAULT_LENGTH_MM = 50
DEFAULT_DEEPNESS = 4
DEFAULT_TRAILING_PAD_MM = 6.0
MAGIC = b"SUPVAN_E10_JOB\n"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", help="Output .spv job file")
    parser.add_argument("--text", default="CODEX")
    parser.add_argument("--length-mm", type=float, default=DEFAULT_LENGTH_MM)
    parser.add_argument("--length-px", type=int)
    parser.add_argument("--deepness", type=int, default=DEFAULT_DEEPNESS)
    parser.add_argument("--threshold", type=int, default=128)
    parser.add_argument("--trailing-pad-mm", type=float, default=DEFAULT_TRAILING_PAD_MM)
    parser.add_argument("--trailing-pad-px", type=int)
    parser.add_argument("--preview-png")
    parser.add_argument("--calibration", choices=["text", "border"], default="text")
    return parser.parse_args()


def load_font(size: int) -> ImageFont.ImageFont:
    for path in (
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
    ):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            pass
    return ImageFont.load_default()


def draw_label(text: str, width: int, calibration: str) -> Image.Image:
    image = Image.new("1", (width, PRINT_HEIGHT), 1)
    draw = ImageDraw.Draw(image)
    if calibration == "border":
        draw.rectangle((0, 0, width - 1, PRINT_HEIGHT - 1), outline=0, width=2)
        draw.line((0, PRINT_HEIGHT // 2, width - 1, PRINT_HEIGHT // 2), fill=0, width=1)
        font = ImageFont.load_default()
        draw.text((6, 6), "LEAD", font=font, fill=0)
        trailing_text = "TRAIL"
        bbox = draw.textbbox((0, 0), trailing_text, font=font)
        draw.text((width - (bbox[2] - bbox[0]) - 6, 6), trailing_text, font=font, fill=0)
        return image

    font_size = min(62, max(10, int(width / max(len(text), 1) * 1.25)))
    while font_size >= 8:
        font = load_font(font_size)
        bbox = draw.textbbox((0, 0), text, font=font)
        text_width = bbox[2] - bbox[0]
        text_height = bbox[3] - bbox[1]
        if text_width <= width - 16 and text_height <= ART_HEIGHT - 8:
            break
        font_size -= 2
    x = (width - text_width) // 2
    y = (PRINT_HEIGHT - text_height) // 2 - bbox[1]
    draw.text((x, y), text, font=font, fill=0)
    draw.rectangle((0, 0, width - 1, PRINT_HEIGHT - 1), outline=0, width=1)
    return image


def add_trailing_padding(image: Image.Image, pad_px: int) -> Image.Image:
    if pad_px <= 0:
        return image
    padded = Image.new("1", (image.width + pad_px, image.height), 1)
    padded.paste(image, (0, 0))
    return padded


def column_bytes(image: Image.Image, x: int) -> bytes:
    out = bytearray(BYTES_PER_COLUMN)
    for y in range(PRINT_HEIGHT):
        if image.getpixel((x, y)) == 0:
            out[y // 8] |= 1 << (y % 8)
    return bytes(out)


def page_flags(page_start: bool, page_end: bool, print_end: bool, cut: int, deepness: int) -> bytes:
    first = 0
    if page_start:
        first |= 0x02
    if page_end:
        first |= 0x04
    if print_end:
        first |= 0x08
    first |= (cut & 0x07) << 4
    second = ((deepness << 2) | (1 << 4)) & 0xFF
    return bytes((first, second))


def page_checksum(buffer: bytearray, data_length: int) -> int:
    total = sum(buffer[2:14])
    for boundary in range(256, data_length + 1, 256):
        total += buffer[boundary - 1]
    return total & 0xFFFF


def lzma_alone(data: bytes) -> bytes:
    raw = lzma.compress(
        data,
        format=lzma.FORMAT_RAW,
        filters=[
            {
                "id": lzma.FILTER_LZMA1,
                "dict_size": 8192,
                "lc": 3,
                "lp": 0,
                "pb": 2,
                "mode": lzma.MODE_NORMAL,
                "nice_len": 128,
                "mf": lzma.MF_BT2,
            }
        ],
    )
    properties = bytes([0x5D]) + struct.pack("<I", 8192)
    return properties + struct.pack("<Q", len(data)) + raw


def build_chunks(image: Image.Image, deepness: int) -> list[bytes]:
    chunks: list[bytes] = []
    width = image.width
    offset = 0
    first = True
    while offset < width:
        columns = min(MAX_COLUMNS_PER_BUFFER, width - offset)
        last = offset + columns >= width
        buffer = bytearray(BUFFER_SIZE)
        buffer[2:4] = page_flags(first, last, last, cut=0, deepness=deepness)
        buffer[4] = columns & 0xFF
        buffer[5] = (columns >> 8) & 0xFF
        buffer[6] = BYTES_PER_COLUMN
        buffer[8] = 1
        buffer[10] = 1
        for column in range(columns):
            start = 14 + (column * BYTES_PER_COLUMN)
            buffer[start : start + BYTES_PER_COLUMN] = column_bytes(image, offset + column)
        data_length = 14 + columns * BYTES_PER_COLUMN
        check = page_checksum(buffer, data_length)
        buffer[0] = check & 0xFF
        buffer[1] = (check >> 8) & 0xFF
        chunks.append(lzma_alone(bytes(buffer)))
        offset += columns
        first = False
    return chunks


def write_job(path: Path, chunks: list[bytes]) -> None:
    payload = bytearray(MAGIC)
    payload += struct.pack("<I", len(chunks))
    for chunk in chunks:
        payload += struct.pack("<I", len(chunk))
        payload += chunk
    path.write_bytes(payload)


def main() -> None:
    args = parse_args()
    width = args.length_px or max(8, round(args.length_mm * DPI_PER_MM))
    image = draw_label(args.text, width, args.calibration)
    trailing_pad_px = args.trailing_pad_px
    if trailing_pad_px is None:
        trailing_pad_px = round(args.trailing_pad_mm * DPI_PER_MM)
    print_image = add_trailing_padding(image, trailing_pad_px)
    chunks = build_chunks(print_image, args.deepness)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    write_job(output, chunks)
    if args.preview_png:
        preview = Path(args.preview_png)
        preview.parent.mkdir(parents=True, exist_ok=True)
        image.save(preview)
    print(
        f"wrote {output} chunks={len(chunks)} "
        f"preview_width={width}px print_width={print_image.width}px "
        f"trailing_pad_px={trailing_pad_px} height={PRINT_HEIGHT}px"
    )
    for index, chunk in enumerate(chunks):
        print(f"  chunk[{index}] compressed={len(chunk)} bytes")


if __name__ == "__main__":
    main()
