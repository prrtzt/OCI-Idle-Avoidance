#!/usr/bin/env python3
"""Smoke tests for load_generator.py."""

import subprocess
import sys
import time
import unittest
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[1]
GENERATOR = ROOT_DIR / "scripts" / "load_generator.py"


class TestLoadGenerator(unittest.TestCase):
    def test_rejects_usage_below_zero(self) -> None:
        result = subprocess.run(
            [sys.executable, str(GENERATOR), "-0.1"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("usage must be between 0.0 and 1.0", result.stderr)

    def test_rejects_usage_above_one(self) -> None:
        result = subprocess.run(
            [sys.executable, str(GENERATOR), "1.1"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("usage must be between 0.0 and 1.0", result.stderr)

    def test_starts_and_stops_cleanly(self) -> None:
        proc = subprocess.Popen([sys.executable, str(GENERATOR), "0.01"])
        try:
            time.sleep(0.5)
            self.assertIsNone(proc.poll())
            proc.terminate()
            proc.wait(timeout=5)
            self.assertEqual(proc.returncode, 0)
        finally:
            if proc.poll() is None:
                proc.kill()


if __name__ == "__main__":
    unittest.main()
