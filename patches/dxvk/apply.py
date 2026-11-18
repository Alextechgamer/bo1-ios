#!/usr/bin/env python3
"""Apply the v2.6.1 Metal overlay to a separate, pinned DXVK checkout."""
from pathlib import Path
import argparse
import subprocess

REVISION = "2b1a284f8453baa2bd193709b67e5183074c74ba"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dxvk_source", type=Path)
    args = parser.parse_args()
    source = args.dxvk_source.resolve()
    bundle = Path(__file__).resolve().parents[2]
    patch = Path(__file__).with_name("0001-metal-wsi-and-static-loader.patch").resolve()
    overlay = bundle / "graphics/dxvk/src/wsi/metal/wsi_platform_ios.cpp"
    destination = source / "src/wsi/metal/wsi_platform_ios.cpp"

    def git(*command, **kwargs):
        return subprocess.run(["git", "-C", str(source), *command], **kwargs)

    revision = git("rev-parse", "HEAD", check=True, capture_output=True, text=True).stdout.strip()
    if revision != REVISION:
        raise SystemExit(f"Expected DXVK v2.6.1 ({REVISION}), found {revision}; refusing to patch.")
    if destination.exists() and destination.read_bytes() != overlay.read_bytes():
        raise SystemExit(f"Existing provider differs: {destination}. Keep or merge it manually.")

    check = git("apply", "--check", str(patch), capture_output=True, text=True)
    if check.returncode == 0:
        git("apply", str(patch), check=True)
        status = "Applied"
    elif git("apply", "--reverse", "--check", str(patch), capture_output=True).returncode == 0:
        status = "Already applied"
    else:
        raise SystemExit("Patch does not apply cleanly; no files changed.\n" + check.stderr)

    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(overlay.read_bytes())
    print(f"{status}: Metal WSI/bootstrap/static-loader overlay for DXVK v2.6.1.")


if __name__ == "__main__":
    main()
