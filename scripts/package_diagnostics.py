#!/usr/bin/env python3
"""Package the real device diagnostics app as an unsigned, clearly named IPA."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import tempfile
import zipfile

from probe_engine_abi import inspect_macho


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path,
                        default=Path("dist/BO1-Port-Diagnostics-Unsigned.ipa"))
    args = parser.parse_args()
    app = args.app.resolve()
    if not app.is_dir() or app.suffix != ".app":
        parser.error("--app must be an existing Xcode-built .app directory")
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.alextechgamer.bo1ios.diagnostics":
        parser.error("Refusing to label an unrelated app as BO1 Port Diagnostics")
    if not info.get("LSRequiresIPhoneOS") or info.get("CFBundlePackageType") != "APPL":
        parser.error("The bundle is not an iPhone application")
    executable = info.get("CFBundleExecutable", "")
    if not executable or Path(executable).name != executable:
        parser.error("Invalid bundle executable name")
    binary = app / executable
    if not binary.is_file() or not os.access(binary, os.X_OK):
        parser.error("The app executable is missing or is not executable")
    macho = inspect_macho(binary.read_bytes())
    if not all(macho[key] for key in ("ios_target", "pie", "hard_pagezero_4gib", "text_above_4gib")):
        parser.error("The bundle must contain a normal ARM64 iPhoneOS executable, with PIE and PAGEZERO")
    paths = sorted(app.rglob("*"))
    if any(path.is_symlink() for path in paths):
        parser.error("Unexpected symlink in the standalone static diagnostics app")
    if (app / "embedded.mobileprovision").exists():
        parser.error("This packaging target expects a bundle without a provisioning profile")
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(prefix="bo1-diagnostics-", suffix=".ipa",
                                     dir=output.parent, delete=False) as temporary:
        temporary_path = Path(temporary.name)
    try:
        with zipfile.ZipFile(temporary_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for path in paths:
                if path.is_file():
                    archive.write(path, Path("Payload") / app.name / path.relative_to(app))
        temporary_path.replace(output)
    finally:
        temporary_path.unlink(missing_ok=True)
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    manifest = {
        "artifact": output.name, "sha256": digest, "bytes": output.stat().st_size,
        "bundle_identifier": info["CFBundleIdentifier"], "display_name": info.get("CFBundleDisplayName"),
        "bundle_version": info.get("CFBundleVersion"), "minimum_ios": info.get("MinimumOSVersion"),
        "target": "arm64-apple-ios", "code_signing": "no-distribution-signature-or-provisioning-profile",
        "game_engine_included": False, "device_execution_verified": False,
        "executable_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
    }
    output.with_suffix(".json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
