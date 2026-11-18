#!/usr/bin/env python3
"""Compile real Swift install/content logic; fixtures never connect to Steam or read credentials."""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sanitize", choices=["none", "address"], default="none")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    services = root / "ios/SteamServices"
    with tempfile.TemporaryDirectory(prefix="bo1-steam-swift-tests-") as directory:
        binary = str(Path(directory) / "test-steam-selection-storage")
        content = services / "Content"
        objects = []
        for name in ["steam_safe_files", "chunk_zip", "lzma_shim", "zstd_edu"]:
            target = str(Path(directory) / (name + ".o"))
            c_command = shlex.split(os.environ.get("CC", "cc"))
            c_command += ["-std=c11", "-D_DARWIN_C_SOURCE=1", "-O1", "-c",
                          str(content / (name + ".c")), "-o", target]
            if args.sanitize != "none":
                c_command += ["-g", "-fsanitize=address", "-fno-omit-frame-pointer"]
            subprocess.run(c_command, check=True, timeout=90)
            objects.append(target)
        command = shlex.split(os.environ.get("SWIFTC", "swiftc"))
        sources = [services / "BO1InstallSelection.swift", services / "BO1InstallStorage.swift",
                   services / "Library/SteamLibraryFetcher.swift", services / "Library/SteamAppInfo.swift",
                   services / "Library/SteamFileError.swift", services / "Core/SteamCMSession.swift",
                   services / "Core/SteamMessageCodec.swift", services / "Core/SteamProtocol.swift",
                   content / "DepotDownloader.swift", content / "DepotManifest.swift", content / "ContentDecryptor.swift",
                   root / "ios/SteamAuth/Proto/SteamProtoMessages.swift", root / "ios/SteamAuth/Core/SteamError.swift",
                   root / "tests/steam_host_support.swift", root / "tests/steam_selection_storage_tests.swift"]
        command += ["-swift-version", "5", "-parse-as-library", "-import-objc-header",
                    str(root / "ios/SteamSwiftBridge.h")]
        command += list(map(str, sources)) + objects + ["-lz", "-llzma", "-lcompression", "-o", binary]
        if args.sanitize != "none":
            command += ["-g", "-sanitize=" + args.sanitize]
        subprocess.run(command, check=True, timeout=180)
        subprocess.run([binary], check=True, timeout=90)


if __name__ == "__main__":
    main()
