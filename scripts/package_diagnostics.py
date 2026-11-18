#!/usr/bin/env python3
"""Package the real device diagnostics app as an unsigned, clearly named IPA."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import zipfile

from probe_engine_abi import inspect_macho

ROOT = Path(__file__).resolve().parents[1]
DXVK_REVISION = "2b1a284f8453baa2bd193709b67e5183074c74ba"
ENGINE_REVISION = "3401a66355c07d6c590049c2f42b7635c9bf00ac"
STEAM_BO2_REVISION = "26aad790810596cf1038a5bca42bcf8789ccb54f"
# Digests of the complete, unchanged notice files in the pinned sources/package.
LICENSES = (
    ("sdl2", "LICENSE.txt", "SDL2-LICENSE.txt",
     "97f35b302b361680ec1e891e95d2d52097bb95abff361434916d99dc1305f127"),
    ("ffmpeg", "COPYING.LGPLv2.1", "FFmpeg-COPYING.LGPLv2.1",
     "b634ab5640e258563c536e658cad87080553df6f34f62269a21d554844e58bfe"),
    ("ffmpeg", "LICENSE.md", "FFmpeg-LICENSE.md",
     "cb48bf09a11f5fb576cddb0431c8f5ed0a60157a9ec942adffc13907cbe083f2"),
    ("dxvk", "LICENSE", "DXVK-LICENSE.txt",
     "a5cb1a6ded7d2d7e92d550ba28edd21be2d1d4044662b399887351023e30ce64"),
    ("moltenvk", "LICENSE", "MoltenVK-LICENSE.txt",
     "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"),
)


def required_file(path, expected_sha256=None):
    if not path.is_file() or path.is_symlink():
        raise ValueError(f"Required notice/provenance file is missing or not regular: {path}")
    data = path.read_bytes()
    if not data.strip():
        raise ValueError(f"Required notice/provenance file is empty: {path}")
    if expected_sha256 and hashlib.sha256(data).hexdigest() != expected_sha256:
        raise ValueError(f"Notice differs from its pinned upstream file: {path}")
    return data


def revision(source):
    return subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"],
                                   text=True, stderr=subprocess.PIPE).strip()


def bundled_notices(source_root, deps_root):
    """Use real fetched files; never synthesize a substitute license notice."""
    lock_bytes = required_file(ROOT / "scripts/ios_dependencies.json")
    lock = json.loads(lock_bytes)
    for name, expected in (("sdl2", lock["sdl2"]["revision"]),
                           ("ffmpeg", lock["ffmpeg"]["revision"]),
                           ("dxvk", DXVK_REVISION), ("bo1-engine", ENGINE_REVISION)):
        actual = revision(source_root / name)
        if actual != expected:
            raise ValueError(f"Provenance pin mismatch for {name}: expected {expected}, got {actual}")

    files = {}
    for name, relative, output, digest in LICENSES:
        directory = deps_root / "MoltenVK" if name == "moltenvk" else source_root / name
        files[output] = required_file(directory / relative, digest)
    files["THIRD_PARTY_NOTICES.md"] = required_file(ROOT / "THIRD_PARTY_NOTICES.md")
    files["ios_dependencies.json"] = lock_bytes
    files["audio-build.json"] = required_file(deps_root / "audio-build.json")
    files["MoltenVK-build.json"] = required_file(deps_root / "MoltenVK/bo1-source.json")
    # Preserve the upstream's own scope statement; it is not a license grant
    # for the game engine or the separate native mixer compiled by diagnostics.
    files["BO1-upstream-NOTICE.md"] = required_file(source_root / "bo1-engine/NOTICE.md")
    files["BO1-upstream-THIRD_PARTY_NOTICES.md"] = required_file(source_root / "bo1-engine/THIRD_PARTY_NOTICES.md")
    for path, name, digest in (
        ("ios/SteamAuth/COPYING", "SteamAuth-COPYING",
         "e6037104443f9a7829b2aa7c5370d0789a7bda3ca65a0b904cdc0c2e285d9195"),
        ("ios/SteamAuth/LICENSE-EXCEPTION.md", "SteamAuth-LICENSE-EXCEPTION.md",
         "534f059c2e9fe5de1acde82b920651b77ea3b4253f86837a3d6a81f54a5bdbbc"),
        ("ios/SteamServices/Content/ZSTD-LICENSE", "Steam-Zstandard-LICENSE",
         "7055266497633c9025b777c78eb7235af13922117480ed5c674677adc381c9d8"),
    ):
        files[name] = required_file(ROOT / path, digest)
    files["SteamAuth-UPSTREAM.md"] = required_file(ROOT / "ios/SteamAuth/UPSTREAM.md")
    files["SteamAuth-IMPORT.json"] = required_file(ROOT / "ios/SteamAuth/IMPORT.json")
    audio = json.loads(files["audio-build.json"])
    moltenvk = json.loads(files["MoltenVK-build.json"])
    if audio.get("target") != "arm64-apple-ios":
        raise ValueError("Audio build receipt is not for arm64-apple-ios")
    for name in ("sdl2", "ffmpeg"):
        if audio.get("sources", {}).get(name, {}).get("revision") != lock[name]["revision"]:
            raise ValueError(f"Audio build receipt has the wrong {name} source revision")
    if (moltenvk.get("version") != lock["moltenvk"]["version"] or
            moltenvk.get("archive_sha256") != lock["moltenvk"]["sha256"]):
        raise ValueError("MoltenVK receipt does not match the pinned release archive")

    recipe_paths = ("scripts/build_ios_deps.py", "scripts/ios_dependencies.json",
                    "cmake/ios_audio.cmake", "cmake/dxvk-static.cmake", "cmake/dxvk-sources.cmake",
                    "cmake/ios_diagnostics.cmake", "cmake/ios_steam.cmake", "cmake/steam-sources.cmake",
                    "patches/dxvk/apply.py", "scripts/package_diagnostics.py")
    project_revision = revision(ROOT)
    repository = f"https://github.com/Alextechgamer/bo1-ios/blob/{project_revision}/"
    provenance = {
        "scope": "BO1 Port Diagnostics; no gameplay engine or commercial game assets",
        "packaging_recipe_revision": project_revision,
        "sources": {
            "SDL2": lock["sdl2"], "FFmpeg": lock["ffmpeg"], "MoltenVK": lock["moltenvk"],
            "DXVK": {"url": "https://github.com/doitsujin/dxvk.git", "revision": DXVK_REVISION,
                     "alterations": "BO1 iOS Metal/static-archive patch series; not an upstream DXVK release"},
            "native_audio": {
                "url": "https://github.com/Zephelinn/BO1-Ascension-ARM64.git", "revision": ENGINE_REVISION,
                "files": ["src/native/native_audio.cpp", "src/native/native_audio.h"],
                "license_grant_inferred": False,
            },
            "Steam_client": {
                "url": "https://github.com/Alextechgamer/bo2-ios.git", "revision": STEAM_BO2_REVISION,
                "original_upstream": "https://github.com/kuscholar/iDeck/tree/2ac39beff91251d36f3ad6331d3f8402b3c10e18",
                "alterations": "BO1 package selection, UIKit integration, staging/recovery and content verification",
            },
        },
        "build_recipes": [{"path": path, "url": repository + path,
                           "sha256": hashlib.sha256(required_file(ROOT / path)).hexdigest()}
                          for path in recipe_paths],
        "dxvk_patches": [{"path": str(path.relative_to(ROOT)),
                          "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
                         for path in sorted((ROOT / "patches/dxvk").glob("[0-9][0-9][0-9][0-9]-*.patch"))],
        "steam_sources": [{"path": str(path.relative_to(ROOT)),
                           "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
                          for directory in (ROOT / "ios/SteamAuth", ROOT / "ios/SteamServices")
                          for path in sorted(directory.rglob("*"))
                          if path.is_file() and path.suffix in (".swift", ".c", ".h")],
        "notices": {name: {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
                    for name, data in sorted(files.items())},
        "receipts": ["audio-build.json", "MoltenVK-build.json"],
        "license_scope": "Preserved dependency notices; no project-wide or BO1 license grant is inferred.",
    }
    files["provenance.json"] = (json.dumps(provenance, indent=2) + "\n").encode()
    return files, provenance


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path,
                        default=Path("dist/BO1-Port-Diagnostics-Unsigned.ipa"))
    parser.add_argument("--source-root", type=Path, default=ROOT / "vendor",
                        help="Pinned SDL2, FFmpeg, DXVK and bo1-engine checkouts (default: vendor)")
    parser.add_argument("--deps-root", type=Path, default=ROOT / "third_party/ios",
                        help="Actual iOS dependency install and receipts (default: third_party/ios)")
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
    if (app / "ThirdPartyNotices").exists():
        parser.error("The built app already has ThirdPartyNotices; refusing to add a second or stale set")
    try:
        notices, provenance = bundled_notices(args.source_root.resolve(), args.deps_root.resolve())
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.error(f"Dependency notices/provenance validation failed: {error}")
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
            for name, data in sorted(notices.items()):
                entry = zipfile.ZipInfo(str(Path("Payload") / app.name / "ThirdPartyNotices" / name))
                entry.create_system = 3
                entry.external_attr = 0o100644 << 16
                archive.writestr(entry, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
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
        "bundled_notices_directory": "ThirdPartyNotices",
        "bundled_notices": {name: hashlib.sha256(data).hexdigest() for name, data in sorted(notices.items())},
        "dependency_sources": provenance["sources"],
        "packaging_recipe_revision": provenance["packaging_recipe_revision"],
    }
    output.with_suffix(".json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
