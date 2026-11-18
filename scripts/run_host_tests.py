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
args = parser.parse_args()
compiler = shlex.split(os.environ.get("CXX", "c++"))
with tempfile.TemporaryDirectory(prefix="bo1-ios-host-tests-") as directory:
    binary = str(Path(directory) / "host-tests")
    command = compiler + ["-std=c++20", "-Wall", "-Wextra", "-Werror", "-pthread",
        "-I" + str(root / "ios/include"), str(root / "ios/bo1_asset_gate.cpp"),
        str(root / "tests/test_platform_state.cpp"), "-o", binary]
    if args.sanitize != "none":
        command += ["-g", "-O1", "-fno-omit-frame-pointer", "-fsanitize=" + args.sanitize]
    subprocess.run(command, check=True)
    subprocess.run([binary], check=True)
