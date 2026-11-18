#!/usr/bin/env python3
"""Run real portable host code on Linux/macOS; does not validate UIKit or Metal."""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--sanitize", choices=["none", "address,undefined", "thread"], default="none")
parser.add_argument("--engine-source", type=Path, help="Pinned source for the real gamepad interface contract test")
args = parser.parse_args()
compiler = shlex.split(os.environ.get("CXX", "c++"))
with tempfile.TemporaryDirectory(prefix="bo1-ios-host-tests-") as directory:
    core = [root / "ios/input/InputState.cpp", root / "ios/input/ios_input_bridge.cpp"]
    tests = [
        ("platform", [root / "ios/bo1_asset_gate.cpp", root / "tests/test_platform_state.cpp"]),
        ("input-state", core + [root / "tests/test_input_state.cpp"]),
    ]
    includes = [root / "ios/include", root / "ios/input"]
    if args.engine_source:
        import hashlib
        header = args.engine_source / "src/client/gpad_backend.h"
        expected = "58f1c47455a3ac1e6d797eace183446e7f26c2d65c6cbe962ba162b8cc743180"
        if not header.is_file() or hashlib.sha256(header.read_bytes()).hexdigest() != expected:
            parser.error("--engine-source must contain the reviewed native gamepad interface")
        includes.append(args.engine_source.resolve() / "src")
        tests.append(("input-engine-contract", core + [root / "ios/input/bo1_engine_input.cpp",
                                                     root / "tests/test_input_engine.cpp"]))
    for name, sources in tests:
        binary = str(Path(directory) / name)
        command = compiler + ["-std=c++20", "-Wall", "-Wextra", "-Werror", "-pthread"]
        command += ["-I" + str(path) for path in includes]
        command += list(map(str, sources)) + ["-o", binary]
        if args.sanitize != "none":
            command += ["-g", "-O1", "-fno-omit-frame-pointer", "-fsanitize=" + args.sanitize]
        subprocess.run(command, check=True)
        subprocess.run([binary], check=True)
