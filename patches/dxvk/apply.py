#!/usr/bin/env python3
"""Apply the v2.6.1 Metal overlay to a separate, pinned DXVK checkout."""
from pathlib import Path
import argparse
import subprocess

REVISION = "2b1a284f8453baa2bd193709b67e5183074c74ba"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dxvk_source", type=Path)
    parser.add_argument("--check-only", action="store_true",
                        help="Verify every patch and the provider are already present; write nothing.")
    args = parser.parse_args()
    source = args.dxvk_source.resolve()
    bundle = Path(__file__).resolve().parents[2]
    patches = sorted(Path(__file__).resolve().parent.glob("[0-9][0-9][0-9][0-9]-*.patch"))
    overlay = bundle / "graphics/dxvk/src/wsi/metal/wsi_platform_ios.cpp"
    destination = source / "src/wsi/metal/wsi_platform_ios.cpp"

    def git(*command, **kwargs):
        return subprocess.run(["git", "-C", str(source), *command], **kwargs)

    revision = git("rev-parse", "HEAD", check=True, capture_output=True, text=True).stdout.strip()
    if revision != REVISION:
        raise SystemExit(f"Expected DXVK v2.6.1 ({REVISION}), found {revision}; refusing to patch.")
    if destination.exists() and destination.read_bytes() != overlay.read_bytes():
        raise SystemExit(f"Existing provider differs: {destination}. Keep or merge it manually.")

    if not patches:
        raise SystemExit("No pinned DXVK patches found.")
    pending = []
    for patch in patches:
        if git("apply", "--reverse", "--check", str(patch), capture_output=True).returncode == 0:
            continue
        check = git("apply", "--check", str(patch), capture_output=True, text=True)
        if check.returncode:
            raise SystemExit(f"{patch.name} does not apply cleanly; no files changed.\n" + check.stderr)
        pending.append(str(patch))

    if args.check_only:
        if pending or not destination.exists():
            raise SystemExit("DXVK needs its complete BO1 iOS patch series/overlay applied first.")
        print(f"Verified: {len(patches)} patches and the Metal WSI overlay at pinned DXVK v2.6.1.")
        return

    if pending:
        # Validate the complete pending set before the first source mutation.
        git("apply", "--check", *pending, check=True)
        git("apply", *pending, check=True)

    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(overlay.read_bytes())
    print(f"Verified/applied {len(patches)} patches and Metal WSI overlay for DXVK v2.6.1.")


if __name__ == "__main__":
    main()
