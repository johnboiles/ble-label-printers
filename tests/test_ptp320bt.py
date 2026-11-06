"""Offline regressions against an official-app PT-P320BT capture."""

import importlib.util
from pathlib import Path
import unittest

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("ptp320bt", ROOT / "tools/ptp320bt/generate_prn.py")
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)
FIXTURES = Path(__file__).parent / "fixtures/ptp320bt"


class PTP320BTTests(unittest.TestCase):
    def test_matches_official_app_capture_byte_for_byte(self):
        with Image.open(FIXTURES / "hello.png") as image:
            job = generator.build_prn(image)
        self.assertEqual(job, (FIXTURES / "hello.prn").read_bytes())

    def test_column_order_bit_order_and_blank_column(self):
        image = Image.new("1", (3, 64), 1)
        for xy in ((0, 0), (0, 7), (0, 8), (2, 63)):
            image.putpixel(xy, 0)
        job = generator.build_prn(image)
        self.assertEqual(job[-34:], bytes.fromhex(
            "4708008180000000000000 4708000000000000000000 4708000000000000000001 1a"))
        info = job.index(b"\x1biz")
        self.assertEqual(int.from_bytes(job[info + 7:info + 11], "little"), 3)

    def test_transparency_is_white(self):
        image = Image.new("RGBA", (2, 64), (0, 0, 0, 0))
        self.assertEqual(generator.build_prn(image), generator.build_prn(Image.new("1", (2, 64), 1)))

    def test_rejects_other_tape_geometry_and_excess_length(self):
        for size in ((10, 128), (10, 63), (generator.MAX_LENGTH_PX + 1, 64)):
            with self.subTest(size=size), self.assertRaises(ValueError):
                generator.build_prn(Image.new("1", size, 1))


if __name__ == "__main__":
    unittest.main()
