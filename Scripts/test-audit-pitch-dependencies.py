#!/usr/bin/env python3
"""Exercise the bundle audit with real Mach-O fixtures; never execute their code."""
import importlib.util
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("pitch_audit", ROOT / "Scripts/audit-pitch-dependencies.py")
AUDIT = importlib.util.module_from_spec(spec)
spec.loader.exec_module(AUDIT)


class BundleAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="watch-pitch-audit-")
        self.addCleanup(self.temp.cleanup)
        self.bundle = Path(self.temp.name) / "Watch Tuner.app"
        self.bundle.mkdir()
        (self.bundle / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Watch Tuner"}))
        self.compile(self.bundle / "Watch Tuner", "int main(void) { return 0; }")
        self.dylib = self.bundle / "Watch Tuner.debug.dylib"

    def compile(self, output, source, dylib=False):
        subprocess.run(["xcrun", "clang", "-x", "c", *(["-dynamiclib"] if dylib else []),
                        "-", "-o", str(output)], input=source, text=True, check=True,
                       capture_output=True)

    def test_clean_executable_and_debug_dylib_pass(self):
        self.compile(self.dylib, "void CleanAuditFixture(void) {}", dylib=True)
        failures, _ = AUDIT.audit([self.bundle])
        self.assertEqual(failures, [])

    def test_forbidden_symbols_in_debug_dylib_are_rejected(self):
        # The main executable stays clean. Only the Debug dylib changes, matching
        # the Xcode layout that the previous executable-only audit missed.
        for name in ["PitchDetector", "HarmonicSpectrum", "VocalPeriodEstimator", "Tuna"]:
            with self.subTest(symbol=name):
                self.compile(self.dylib, f"void {name}AuditFixture(void) {{}}", dylib=True)
                symbols = subprocess.check_output(["nm", "-a", str(self.dylib)], text=True)
                self.assertIn(name + "AuditFixture", symbols)
                failures, _ = AUDIT.audit([self.bundle])
                self.assertTrue(any(str(self.dylib) in failure for failure in failures), failures)

    def test_nested_macho_without_dylib_extension_is_checked(self):
        self.compile(self.dylib, "void CleanAuditFixture(void) {}", dylib=True)
        nested = self.bundle / "Frameworks/Fixture.framework/Fixture"
        nested.parent.mkdir(parents=True)
        self.compile(nested, "void HarmonicSpectrumAuditFixture(void) {}", dylib=True)
        failures, _ = AUDIT.audit([self.bundle])
        self.assertTrue(any(str(nested) in failure for failure in failures), failures)


if __name__ == "__main__":
    unittest.main(verbosity=2)
