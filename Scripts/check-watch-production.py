#!/usr/bin/env python3
"""Compile and run configuration checks against the generated Watch DSP inventory."""
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
project = (ROOT / "WatchTuner.xcodeproj/project.pbxproj").read_text()
sources = sorted(set(re.findall(r'path = "(Sources/[^\"]+\.swift)";', project)))
if not sources:
    raise SystemExit("No DSP sources found in the generated Watch project")

build = ROOT / ".build/WatchProductionSmoke"
build.mkdir(parents=True, exist_ok=True)
executable = build / "watch-production-smoke"
subprocess.run([
    "swiftc", "-O", "-swift-version", "6", "-D", "WATCHTUNER_APP",
    "-module-cache-path", str(build / "ModuleCache"),
    *(str(ROOT / source) for source in sources),
    str(ROOT / "Scripts/WatchProductionSmoke.swift"), "-o", str(executable),
], check=True)
subprocess.run([str(executable)], check=True)
