#!/usr/bin/env python3
"""Run unchanged shared DSP sources on Linux with a test-only dot-product shim.

Requires a Swift 6 toolchain. This checks core behavior, not Apple Accelerate,
AVAudioEngine, SwiftUI, an iOS build, or device audio. The original package and
sources are never rewritten. AVFAudio-dependent tests are listed and excluded.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PortableTunerCore", targets: [
    .target(name: "Accelerate"),
    .target(name: "TunerDSP", dependencies: ["Accelerate"]),
    .testTarget(name: "TunerDSPTests", dependencies: ["TunerDSP"])
])
'''
SHIM = '''// Test-only Linux implementation of the single Accelerate primitive used.
// The arithmetic operation is equivalent; reduction order/rounding and speed
// do not claim to reproduce Apple Accelerate.
public typealias vDSP_Length = UInt
public func vDSP_dotpr(_ a: UnsafePointer<Float>, _ aStride: Int,
                       _ b: UnsafePointer<Float>, _ bStride: Int,
                       _ result: UnsafeMutablePointer<Float>, _ count: vDSP_Length) {
    var sum: Float = 0
    for index in 0..<Int(count) { sum += a[index * aStride] * b[index * bStride] }
    result.pointee = sum
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", default=shutil.which("swift"), help="Swift 6 executable")
    parser.add_argument("--filter", help="XCTest name regular expression (default: all portable tests)")
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    if not args.swift:
        parser.error("Swift is unavailable; pass --swift /path/to/swift")
    # Preserve the executable name: toolchains may use a swift -> swift-driver
    # symlink whose argv[0] selects command behavior.
    swift = str(Path(args.swift).absolute())
    with tempfile.TemporaryDirectory(prefix="watchtuner-portable-") as temporary:
        work = Path(temporary)
        shutil.copytree(ROOT / "Sources/TunerDSP", work / "Sources/TunerDSP")
        tests = work / "Tests/TunerDSPTests"
        tests.mkdir(parents=True)
        excluded = []
        for source in sorted((ROOT / "Tests/TunerDSPTests").glob("*.swift")):
            if "import AVFAudio" in source.read_text():
                excluded.append(source.name)
            else:
                shutil.copy2(source, tests / source.name)
        shim = work / "Sources/Accelerate"
        shim.mkdir()
        (shim / "DotProduct.swift").write_text(SHIM)
        (work / "Package.swift").write_text(MANIFEST)
        print("Portable shared-core regression: unchanged source + test-only scalar vDSP_dotpr", flush=True)
        print("Excluded Apple audio tests: " + ", ".join(excluded), flush=True)
        print("Does not validate iOS compilation, audio hardware, or Accelerate rounding/performance.", flush=True)
        command = [swift, "test", "--package-path", str(work),
                   "--cache-path", str(work / "package-cache"),
                   "--config-path", str(work / "package-config"),
                   "--security-path", str(work / "package-security"),
                   "--configuration", "release", "--jobs", str(args.jobs)]
        if args.filter:
            command += ["--filter", args.filter]
        environment = os.environ.copy()
        # Keep compiler caches inside the disposable, authorized workspace.
        environment["CLANG_MODULE_CACHE_PATH"] = str(work / "clang-cache")
        environment["SWIFTPM_MODULECACHE_OVERRIDE"] = str(work / "module-cache")
        return subprocess.run(command, env=environment).returncode


if __name__ == "__main__":
    raise SystemExit(main())
