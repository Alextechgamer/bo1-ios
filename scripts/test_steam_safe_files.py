#!/usr/bin/env python3
"""Test the actual POSIX Steam file helper on Linux/macOS, without Steam or credentials."""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sanitize", choices=["none", "address,undefined"], default="none")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    content = root / "ios/SteamServices/Content"
    with tempfile.TemporaryDirectory(prefix="bo1-steam-file-tests-") as directory:
        binary = str(Path(directory) / "test-steam-safe-files")
        command = shlex.split(os.environ.get("CC", "cc"))
        command += ["-std=c11", "-D_POSIX_C_SOURCE=200809L", "-Wall", "-Wextra", "-Werror"]
        command += ["-I" + str(content), str(content / "steam_safe_files.c"),
                    str(root / "tests/test_steam_safe_files.c"), "-o", binary]
        if args.sanitize != "none":
            command += ["-g", "-O1", "-fno-omit-frame-pointer", "-fsanitize=" + args.sanitize]
        subprocess.run(command, check=True, timeout=60)
        subprocess.run([binary], check=True, timeout=30)


if __name__ == "__main__":
    main()
