#!/usr/bin/env python3
"""Compile the real pinned DXVK interface/dispatcher/loader with host bridge fakes.

Requires a recursive DXVK v2.6.1 checkout and a C++20 host compiler. Does not
require Apple SDKs, MoltenVK binaries, or game assets. Uses a temporary worktree
so the supplied reference checkout is not changed by the test.
"""
from pathlib import Path
import argparse
import os
import shlex
import subprocess
import tempfile

REVISION = "2b1a284f8453baa2bd193709b67e5183074c74ba"
VULKAN_HEADERS_REVISION = "234c4b7370a8ea3239a214c9e871e4b17c89f4ab"


def run(*args, **kwargs):
    return subprocess.run(*args, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dxvk_reference", type=Path)
    args = parser.parse_args()
    reference = args.dxvk_reference.resolve()
    bundle = Path(__file__).resolve().parents[2]
    vulkan = reference / "include/vulkan"
    actual = run(["git", "-C", str(vulkan), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    if actual != VULKAN_HEADERS_REVISION:
        raise SystemExit("The Vulkan-Headers submodule must match DXVK v2.6.1. Initialize its submodules first.")

    compiler = shlex.split(os.environ.get("CXX", "c++"))
    with tempfile.TemporaryDirectory(prefix="bo1-metal-wsi-") as directory:
        temporary = Path(directory)
        checkout = temporary / "dxvk"
        run(["git", "-C", str(reference), "worktree", "add", "--detach", str(checkout), REVISION],
            stdout=subprocess.DEVNULL)
        try:
            run(["python3", str(bundle / "patches/dxvk/apply.py"), str(checkout)])
            # The contract code is the actual upstream WsiDriver and dispatch,
            # not a copied header or a miniature reimplementation.
            command = compiler + [
                "-std=c++20", "-Wall", "-Wextra", "-Wno-unused-parameter",
                "-DDXVK_WSI_METAL=1", "-DVK_USE_PLATFORM_METAL_EXT=1",
                "-I" + str(checkout),
                "-I" + str(checkout / "include/native/windows"),
                "-I" + str(vulkan / "include"),
                "-I" + str(bundle / "ios/include"),
                str(bundle / "graphics/tests/metal_wsi_test.cpp"),
                str(checkout / "src/wsi/metal/wsi_platform_ios.cpp"),
                str(checkout / "src/wsi/wsi_platform.cpp"),
                str(checkout / "src/vulkan/vulkan_loader.cpp"),
                "-o", str(temporary / "metal_wsi_test"),
            ]
            run(command)
            run([str(temporary / "metal_wsi_test")])
        finally:
            run(["git", "-C", str(reference), "worktree", "remove", "--force", str(checkout)],
                stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
