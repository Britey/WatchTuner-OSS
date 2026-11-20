#!/usr/bin/env python3
"""Check current source/build inputs and optional compiled Watch bundles for removed dependencies."""
import argparse
import plistlib
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REMOVED = re.compile(r"Tuna|Beethoven|YINUtil|YINEstimator|ReferencePitchMethods|\.yin\b|yin:\s*Bool|absoluteThreshold|cumulativeDifference|difference2", re.IGNORECASE)


HISTORICAL = {"PitchDetector.swift", "HarmonicSpectrum.swift", "VocalPeriodEstimator.swift"}


# Thin and universal Mach-O headers, in either byte order (32- and 64-bit).
MACHO_MAGICS = {
    bytes.fromhex(value) for value in (
        "feedface", "cefaedfe", "feedfacf", "cffaedfe",
        "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
    )
}


def bundle_code_files(bundle):
    """Find code by its header, including Xcode's Debug dylib and nested code."""
    result = []
    for path in sorted(bundle.rglob("*")):
        if path.is_file():
            with path.open("rb") as stream:
                if stream.read(4) in MACHO_MAGICS:
                    result.append(path)
    return result


def audit(bundles):
    failures = []
    inputs = [ROOT / "Package.swift", ROOT / "Scripts/generate-project.py"]
    for directory in ["Sources", "App", "Tests", "UITests", "Tools", "WatchTuner.xcodeproj"]:
        inputs.extend(p for p in (ROOT / directory).rglob("*")
                      if p.is_file() and p.suffix in {".swift", ".mjs", ".py", ".pbxproj", ".xcscheme", ".json", ".plist"})
    for path in inputs:
        if REMOVED.search(path.name) or REMOVED.search(path.read_text()):
            failures.append(f"Removed implementation/reference in {path.relative_to(ROOT)}")
    package = (ROOT / "Package.swift").read_text()
    project = (ROOT / "WatchTuner.xcodeproj/project.pbxproj").read_text()
    if re.search(r"\.package\s*\(|XCRemoteSwiftPackageReference|XCSwiftPackageProductDependency", package + project):
        failures.append("Unexpected external package dependency in Watch build inputs")
    references = set(re.findall(r'path = "((?:App|Sources)/[^\"]+\.swift)";', project))
    expected = {str(p.relative_to(ROOT)) for p in (ROOT / "App").glob("*.swift")}
    expected.update(str(p.relative_to(ROOT)) for p in (ROOT / "Sources/TunerDSP").glob("*.swift") if p.name not in HISTORICAL)
    if references != expected:
        failures.append(f"Watch Swift source references differ from source inventory: {references ^ expected}")
    if project.count('SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) WATCHTUNER_APP"') != 2:
        failures.append("Watch Debug/Release target configurations must define the production-only compilation condition")
    license_text = (ROOT / "ThirdParty/Pitchy-4.1.0-LICENSE.txt").read_text()
    source = (ROOT / "Sources/TunerDSP/PitchAlgorithms.swift").read_text()
    notice = source.split('public static let licenseNotice = """', 1)[1].split('"""', 1)[0]
    normalize = lambda value: " ".join(value.split())
    if normalize(license_text[license_text.index("Permission is hereby granted"):]) != normalize(notice[notice.index("Permission is hereby granted"):]):
        failures.append("In-app MIT terms differ from pinned Pitchy license")
    if "Copyright 2018–2021 Ian Johnson" not in notice or "Copyright 2018-2021 Ian Johnson" not in license_text:
        failures.append("Missing pinned Pitchy copyright attribution")
    for bundle in bundles:
        info = plistlib.loads((bundle / "Info.plist").read_bytes())
        executable = bundle / info["CFBundleExecutable"]
        code_files = bundle_code_files(bundle)
        if executable not in code_files:
            failures.append(f"Missing Mach-O bundle executable: {executable}")
        for code in code_files:
            strings = subprocess.check_output(["strings", "-a", str(code)], text=True)
            symbols = subprocess.check_output(["nm", "-a", str(code)], text=True, stderr=subprocess.PIPE)
            if any(name in strings + symbols for name in ("PitchDetector", "HarmonicSpectrum", "VocalPeriodEstimator")):
                failures.append(f"Historical detector found in bundled Mach-O: {code}")
            if REMOVED.search(strings + symbols):
                failures.append(f"Removed implementation found in bundled Mach-O: {code}")
        if any(REMOVED.search(p.name) for p in bundle.rglob("*")):
            failures.append(f"Removed dependency filename found in built bundle {bundle}")
    return failures, len(inputs)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, action="append", default=[], help="Built .app to inspect (repeatable); source/build audit always runs")
    args = parser.parse_args()
    for bundle in args.bundle:
        for code in bundle_code_files(bundle):
            print(f"Checking Mach-O: {code}", flush=True)
    failures, count = audit(args.bundle)
    if failures:
        raise SystemExit("\n".join(failures))
    print(f"PASS: {count} source/build inputs, no removed implementation or external Watch package; historical Watch detectors excluded; Pitchy attribution retained; {len(args.bundle)} bundle(s) checked")
