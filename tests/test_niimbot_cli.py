"""Exercise the built Swift app without creating a Bluetooth manager."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / ".build/NiimbotB21S.app/Contents/MacOS/niimbot-b21s"


@unittest.skipUnless(BINARY.is_file(), "Build scripts/build-niimbot-b21s.sh first")
class OfflineClientTests(unittest.TestCase):
    def run_client(self, *args):
        return subprocess.run([str(BINARY), *args], capture_output=True, text=True, timeout=5)

    def validate(self, steps, *options):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "job.json"
            path.write_text(json.dumps(steps))
            return self.run_client(*options, "validate-file", str(path))

    @staticmethod
    def identify(**extra):
        return {"name": "identify", "hex": "555540010849aaaa", "expect": 72,
                "expectData": "0309", **extra}

    def test_help_does_not_need_bluetooth(self):
        result = self.run_client("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("validate-file", result.stdout + result.stderr)

    def test_valid_frame_and_connect_prefix(self):
        result = self.validate([
            {"name": "connect", "hex": "035555c10101c1aaaa", "expect": 194},
            self.identify(),
        ])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Scanning", result.stdout)

    def test_malformed_frames_rejected_offline(self):
        for packet in ["", "5555", "03555540010849aaaa", "555540010848aaaa",
                       "555540020849aaaa", "555540010849aaab", "not hex"]:
            with self.subTest(packet=packet):
                result = self.validate([self.identify(hex=packet)])
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("Scanning", result.stdout)

    def test_invalid_timing_and_response_commands(self):
        for extra in [{"timeout": 0}, {"delay": -1}, {"maxAttempts": 0},
                      {"expect": 256}, {"expect": -1}, {"expect": 1.5}]:
            with self.subTest(extra=extra):
                self.assertNotEqual(self.validate([self.identify(**extra)]).returncode, 0)

    def test_payload_assertion_needs_response_command(self):
        result = self.validate([{"name": "invalid", "hex": "555540010849aaaa",
                                 "expectData": "0309"}])
        self.assertNotEqual(result.returncode, 0)

    def test_empty_job_rejected(self):
        self.assertNotEqual(self.validate([]).returncode, 0)

    def test_invalid_printer_options_rejected_offline(self):
        for args in [("--uuid", "not-a-uuid"), ("--scan-seconds", "0"),
                     ("--scan-seconds", "nan"), ("--scan-seconds", "-1")]:
            with self.subTest(args=args):
                result = self.validate([self.identify()], *args)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("Scanning", result.stdout)

    def test_validation_alias_and_relative_path(self):
        with tempfile.TemporaryDirectory(dir=ROOT) as directory:
            path = Path(directory) / "job.json"
            path.write_text(json.dumps([self.identify()]))
            relative = str(path.relative_to(ROOT))
            result = subprocess.run([str(BINARY), "--validate-job", relative], cwd=ROOT,
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
