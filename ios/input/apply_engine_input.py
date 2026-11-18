#!/usr/bin/env python3
"""Install the checked iOS IN_Frame input hook in the pinned BO1 checkout."""
import argparse
from pathlib import Path
import subprocess

REVISION = "3401a66355c07d6c590049c2f42b7635c9bf00ac"

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("engine_source", type=Path)
    args = parser.parse_args()
    source = args.engine_source.resolve()
    patch = Path(__file__).with_name("engine-input.patch").resolve()
    def git(*command, **kwargs):
        return subprocess.run(["git", "-C", str(source), *command], **kwargs)
    actual = git("rev-parse", "HEAD", check=True, capture_output=True, text=True).stdout.strip()
    if actual != REVISION:
        raise SystemExit(f"Expected Ascension {REVISION}, found {actual}; no changes made.")
    checked = git("apply", "--check", str(patch), capture_output=True, text=True)
    if checked.returncode == 0:
        git("apply", str(patch), check=True)
        print("Applied iOS input pump hook before IN_MouseMove.")
    elif git("apply", "--reverse", "--check", str(patch), capture_output=True).returncode == 0:
        print("iOS input pump hook is already applied.")
    else:
        raise SystemExit("Input patch does not apply cleanly; no files changed.\n" + checked.stderr)

if __name__ == "__main__":
    main()
