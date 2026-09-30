"""Offline B21S protocol and rendering regressions; no Bluetooth access."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from PIL import Image, ImageDraw, ImageOps

GENERATOR = Path(__file__).resolve().parents[1] / "tools" / "niimbot-b21s" / "generate_job.py"
spec = importlib.util.spec_from_file_location("niimbot_b21s_generator", GENERATOR)
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


def decode_frame(hex_data):
    packet = bytes.fromhex(hex_data)
    prefix = packet.startswith(b"\x03\x55\x55")
    if prefix:
        packet = packet[1:]
    if packet[:2] != b"\x55\x55" or packet[-2:] != b"\xaa\xaa":
        raise AssertionError("invalid frame boundary")
    command, length = packet[2:4]
    if len(packet) != length + 7:
        raise AssertionError("invalid payload length")
    check = 0
    for value in packet[2:-2]:
        check ^= value
    if check != 0:
        raise AssertionError("invalid checksum")
    if prefix != (command == 0xC1):
        raise AssertionError("Connect prefix missing or used on another command")
    return command, packet[4:-3]


class ProtocolTests(unittest.TestCase):
    def test_captured_frame_bytes_and_connect_prefix(self):
        self.assertEqual(generator.frame(0xC1, [1]), "035555c10101c1aaaa")
        self.assertEqual(generator.frame(0x40, [8]), "555540010849aaaa")
        self.assertEqual(generator.frame(0x21, [3]), "555521010323aaaa")
        self.assertEqual(generator.frame(0x13, [0, 160, 0, 240, 0, 1]),
                         "5555130600a000f0000144aaaa")

    def test_verified_single_copy_sequence_and_completion(self):
        job = generator.make_job(Image.new("1", (240, 160), 1))
        frames = [decode_frame(item["hex"]) for item in job]
        self.assertEqual(frames[:9], [
            (0xC1, b"\x01"), (0x40, b"\x08"), (0x21, b"\x03"),
            (0x23, b"\x01"), (0x01, b"\x01"), (0x20, b"\x01"),
            (0x03, b"\x01"), (0x13, b"\x00\xa0\x00\xf0\x00\x01"),
            (0x15, b"\x00\x01"),
        ])
        self.assertEqual(job[1]["expectData"], "0309")
        self.assertEqual(job[7]["expectPrefix"], "01")  # Size ACK can contain 01 00.
        self.assertEqual(frames[-3:], [(0xE3, b"\x01"), (0xA3, b"\x01"), (0xF3, b"\x01")])
        self.assertEqual(job[-2]["repeatUntilPrefix"], "00016464")
        self.assertEqual(job[-2]["maxAttempts"], 60)
        self.assertEqual(job[-2]["timeout"], 5)
        self.assertEqual(job[-1]["expect"], 0xF4)

    def test_bitmap_roundtrip_positions_polarity_and_chunk_counts(self):
        # Probe both edges of each 128-dot head section and byte boundaries.
        # Also include an all-black row, a narrow pattern, and blank rows.
        for width in (160, 240, 384):
            with self.subTest(width=width):
                original = Image.new("1", (width, 5), 1)
                for x in (0, 7, 8, 127, 128, 255, 256, 383):
                    if x < width:
                        original.putpixel((x, 0), 0)
                for x in range(width):
                    original.putpixel((x, 1), 0)
                for x in range(3, width, 11):
                    original.putpixel((x, 3), 0)
                recovered = Image.new("1", original.size, 1)
                rows = generator.make_job(original)[9:-3]
                self.assertEqual(len(rows), original.height)
                for y, item in enumerate(rows):
                    command, data = decode_frame(item["hex"])
                    self.assertEqual(int.from_bytes(data[:2], "big"), y)
                    self.assertEqual(item["delay"], 0.015)
                    if command == 0x84:
                        self.assertEqual(data[2:], b"\x01")
                        self.assertTrue(all(original.getpixel((x, y)) for x in range(width)))
                        continue
                    self.assertEqual(command, 0x85)
                    self.assertEqual(data[5], 1)
                    self.assertEqual(len(data[6:]), width // 8)
                    expected_counts = [sum(original.getpixel((x, y)) == 0
                                           for x in range(start, min(start + 128, width)))
                                       for start in (0, 128, 256)]
                    self.assertEqual(list(data[2:5]), expected_counts)
                    for x in range(width):
                        black = data[6 + x // 8] & (0x80 >> (x % 8))
                        recovered.putpixel((x, y), 0 if black else 255)
                self.assertEqual(recovered.tobytes(), original.tobytes())

    def test_density_label_type_and_invalid_protocol_inputs(self):
        image = Image.new("1", (160, 120), 1)
        job = generator.make_job(image, label_type=5, density=4)
        self.assertEqual(decode_frame(job[2]["hex"]), (0x21, b"\x04"))
        self.assertEqual(decode_frame(job[3]["hex"]), (0x23, b"\x05"))
        for kwargs in ({"density": 0}, {"density": 6}, {"density": 2.5}, {"label_type": 4}):
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                generator.make_job(image, **kwargs)
        for invalid in (Image.new("L", (160, 120)), Image.new("1", (159, 120)),
                        Image.new("1", (392, 120)), Image.new("1", (160, 0))):
            with self.subTest(size=invalid.size, mode=invalid.mode), self.assertRaises(ValueError):
                generator.make_job(invalid)


class RenderingTests(unittest.TestCase):
    def test_stock_bounds_and_printhead_limit(self):
        self.assertEqual(generator.label_size(50, 30), (384, 240))
        self.assertEqual(generator.label_size(48, 30), (384, 240))
        self.assertEqual(generator.label_size(20.9, 15), (160, 120))
        self.assertEqual(generator.label_size(30, 200), (240, 1600))
        for width, height in ((19.9, 30), (50.1, 30), (30, 14.9), (30, 200.1),
                              (float("nan"), 30), (30, float("inf")), (0, 0)):
            with self.subTest(width=width, height=height), self.assertRaises(ValueError):
                generator.label_size(width, height)

    def test_transparent_black_is_white_and_opaque_black_is_printed(self):
        source = Image.new("RGBA", (32, 16), (0, 0, 0, 0))
        ImageDraw.Draw(source).rectangle((8, 4, 23, 11), fill=(0, 0, 0, 255))
        result = generator.fit_image(source, source.size)
        self.assertEqual(result.mode, "1")
        self.assertEqual(result.getpixel((0, 0)), 255)
        self.assertEqual(result.getpixel((10, 6)), 0)
        self.assertEqual(ImageOps.invert(result.convert("L")).getbbox(), (8, 4, 24, 12))

    def test_image_aspect_ratio_and_centering(self):
        result = generator.fit_image(Image.new("RGB", (80, 20), "black"), (160, 120))
        self.assertEqual(ImageOps.invert(result.convert("L")).getbbox(), (0, 40, 160, 80))

    def test_autofit_descenders_wide_and_multiline_text(self):
        for text in ("gypqj", "W" * 24, "gypqj\nWIDE TEXT"):
            with self.subTest(text=text):
                result = generator.draw_text_label(text, (384, 240))
                box = ImageOps.invert(result.convert("L")).getbbox()
                self.assertIsNotNone(box)
                self.assertEqual(result.mode, "1")
                self.assertGreaterEqual(box[0], generator.MARGIN)
                self.assertGreaterEqual(box[1], generator.MARGIN)
                self.assertLessEqual(box[2], 384 - generator.MARGIN)
                self.assertLessEqual(box[3], 240 - generator.MARGIN)
                self.assertLessEqual(abs(box[0] - (384 - box[2])), 1)
                self.assertLessEqual(abs(box[1] - (240 - box[3])), 1)

    def test_logo_keeps_aspect_and_text_below(self):
        # A solid 4:1 logo makes its rendered bounds unambiguous.
        result = generator.draw_text_label("Example", (384, 240),
                                            logo=Image.new("RGBA", (200, 50), "black"))
        ink = ImageOps.invert(result.convert("L"))
        top_box = ink.crop((0, 0, 384, 100)).getbbox()
        self.assertEqual(top_box, (48, 12, 336, 84))
        self.assertIsNone(ink.crop((0, 84, 384, 96)).getbbox())
        self.assertIsNotNone(ink.crop((0, 96, 384, 228)).getbbox())

    def test_empty_long_and_invalid_font_errors(self):
        with self.assertRaisesRegex(ValueError, "empty"):
            generator.draw_text_label(" \n\t ", (384, 240))
        with self.assertRaisesRegex(ValueError, "too long"):
            generator.draw_text_label("W" * 1000, (160, 120))
        with self.assertRaisesRegex(ValueError, "cannot load font"):
            generator.draw_text_label("Example", (384, 240), "/nonexistent/font.ttf")


class CLITests(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run([sys.executable, str(GENERATOR), *map(str, args)],
                              capture_output=True, text=True)

    def test_cli_job_and_both_previews(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "label.json"
            result = self.run_cli(output, "--text", "Example")
            self.assertEqual(result.returncode, 0, result.stderr)
            summary = json.loads(result.stdout)
            self.assertEqual(summary["printable_pixels"], [384, 240])
            self.assertEqual(summary["printable_width_mm"], 48)
            self.assertTrue(summary["printhead_limited"])
            self.assertEqual(summary["copies"], 1)
            with Image.open(output.with_suffix(".png")) as preview:
                self.assertEqual(preview.mode, "1")
                self.assertEqual(preview.size, (384, 240))
                self.assertEqual(json.loads(output.read_text()), generator.make_job(preview))
                with Image.open(output.with_name("label-4x.png")) as enlarged:
                    self.assertEqual(enlarged.mode, "1")
                    self.assertEqual(enlarged.size, (1536, 960))
                    self.assertEqual(enlarged.tobytes(), preview.resize(enlarged.size,
                                     Image.Resampling.NEAREST).tobytes())

    def test_cli_image_and_custom_preview(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.png"
            Image.new("RGBA", (80, 20), "black").save(source)
            output, preview = root / "job.json", root / "previews" / "proof.png"
            result = self.run_cli(output, "--image", source, "--preview-png", preview,
                                  "--width-mm", 20, "--height-mm", 15)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(preview.with_name("proof-4x.png").is_file())
            with Image.open(preview) as image:
                self.assertEqual(image.size, (160, 120))
                self.assertEqual(ImageOps.invert(image.convert("L")).getbbox(), (0, 40, 160, 80))

    def test_invalid_cli_leaves_no_job(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "bad.json"
            for args, message in ((["--text", " "], "text must not be empty"),
                                  (["--text", "Example", "--width-mm", "51"], "between 20 and 50"),
                                  (["--text", "Example", "--font", directory], "cannot load font"),
                                  (["--image", "missing.png", "--logo", "logo.png"], "only be used with --text")):
                with self.subTest(args=args):
                    result = self.run_cli(output, *args)
                    self.assertEqual(result.returncode, 2)
                    self.assertIn(message, result.stderr)
                    self.assertFalse(output.exists())

    def test_cli_refuses_overwriting_image_input_with_preview(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source.png"
            Image.new("RGBA", (80, 20), "black").save(source)
            original = source.read_bytes()
            result = self.run_cli(source.with_suffix(".json"), "--image", source)
            self.assertEqual(result.returncode, 2)
            self.assertIn("overwrite an input", result.stderr)
            self.assertEqual(source.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
