#!/usr/bin/env python3
"""Reproducible compiler/address-model experiments, never a playable-engine test.

The default runs portable representation checks and uses the iPhone SDK when
present. --require-apple makes an unavailable SDK/compiler a failure. Target
executables are inspected, never run on the build host. No PAGEZERO/ASLR flags
are changed. See docs/ENGINE_ABI.md for the distinction between each gate.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PROBES = ROOT / "engine" / "probes"
TARGET = "arm64-apple-ios16.0"
GIB = 1 << 30
REVISIONS = {
    "ascension": "3401a66355c07d6c590049c2f42b7635c9bf00ac",
    "android": "e121bab3412988b29534fad26c257adc24329818",
    "xnu": "f6217f891ac0bb64f3d375211650a4c1ff8ca1ea",
    "llvm_reference": "llvmorg-21.1.8",
}


def inspect_macho(data: bytes) -> dict:
    """Read a thin, little-endian ARM64 executable, with checked command bounds."""
    if len(data) < 32:
        raise ValueError("truncated Mach-O header")
    magic, cpu, subtype, filetype, ncmds, command_bytes, flags, _ = struct.unpack_from("<8I", data)
    if magic != 0xFEEDFACF or cpu != 0x0100000C or filetype != 2:
        raise ValueError("expected a thin 64-bit ARM64 MH_EXECUTE Mach-O")
    commands_end = 32 + command_bytes
    if commands_end > len(data) or ncmds > command_bytes // 8:
        raise ValueError("load commands exceed the file")
    segments = []
    ios_target = False
    position = 32
    for _ in range(ncmds):
        if position + 8 > commands_end:
            raise ValueError("truncated load command")
        command, size = struct.unpack_from("<2I", data, position)
        if size < 8 or size % 8 or position + size > commands_end:
            raise ValueError("invalid load-command size")
        if command == 0x19:  # LC_SEGMENT_64
            if size < 72:
                raise ValueError("truncated LC_SEGMENT_64")
            values = struct.unpack_from("<II16sQQQQiiII", data, position)
            _, _, name, address, length, fileoff, filesize, maxprot, initprot, nsects, _ = values
            if size != 72 + 80 * nsects or address + length > (1 << 64):
                raise ValueError("invalid segment extent/section table")
            if fileoff + filesize > len(data):
                raise ValueError("segment file data exceeds file")
            segments.append({"name": name.split(b"\0", 1)[0].decode("ascii"),
                             "vmaddr": address, "vmsize": length,
                             "fileoff": fileoff, "filesize": filesize,
                             "maxprot": maxprot, "initprot": initprot})
        elif command == 0x32:  # LC_BUILD_VERSION
            if size < 24:
                raise ValueError("truncated LC_BUILD_VERSION")
            ios_target |= struct.unpack_from("<I", data, position + 8)[0] == 2
        elif command == 0x25:  # LC_VERSION_MIN_IPHONEOS
            if size < 16:
                raise ValueError("truncated LC_VERSION_MIN_IPHONEOS")
            ios_target = True
        position += size
    if position != commands_end:
        raise ValueError("load-command count/size mismatch")
    zeros = [s for s in segments if s["name"] == "__PAGEZERO"]
    texts = [s for s in segments if s["name"] == "__TEXT"]
    mapped = [s for s in segments if s["name"] != "__PAGEZERO" and s["vmsize"]]
    if len(zeros) != 1 or len(texts) != 1 or not mapped:
        raise ValueError("missing/duplicate __PAGEZERO or __TEXT")
    zero, text = zeros[0], texts[0]
    hard_pagezero = (zero["vmaddr"] == 0 and zero["vmsize"] >= 4 * GIB and
                     zero["initprot"] == 0 and zero["maxprot"] == 0)
    first = min(s["vmaddr"] for s in mapped)
    last = max(s["vmaddr"] + s["vmsize"] for s in mapped)
    return {"cpu_subtype": subtype, "ios_target": ios_target,
            "pie": bool(flags & 0x200000), "hard_pagezero_4gib": hard_pagezero,
            "text_above_4gib": text["vmaddr"] >= 4 * GIB,
            "image_base": first, "image_end": last, "image_span_bytes": last - first,
            "image_fits_relative32": last - first <= 0xFFFFFFFF,
            "file_bytes": len(data), "segments": segments}


def inspect_narrow_stores(assembly: str) -> dict:
    """Fail closed if an isolated store function emits a wider store or a call."""
    evidence = {}
    for bits, allowed in ((8, {"strb", "sturb"}), (16, {"strh", "sturh"})):
        name = f"bo1_probe_store{bits}"
        match = re.search(rf"^_?{name}:.*$", assembly, re.MULTILINE)
        if not match:
            raise ValueError(f"assembly has no {name} function")
        body = assembly[match.end():]
        end = re.search(r"^\s*\.(?:globl|global|cfi_endproc|size|subsections_via_symbols)\b", body, re.MULTILINE)
        if end:
            body = body[:end.start()]
        instructions = []
        for line in body.splitlines():
            clean = line.split("//", 1)[0].strip()
            if not clean or clean.startswith((".", ";", "#")) or ":" in clean:
                continue
            instructions.append(clean.split()[0].lower())
        stores = [op for op in instructions if op.startswith(("st", "cas", "swp"))]
        if len(stores) != 1 or stores[0] not in allowed:
            raise ValueError(f"{name}: expected one {sorted(allowed)}; got {stores}")
        if any(op in {"bl", "blr"} for op in instructions):
            raise ValueError(f"{name}: unexpected helper call prevents width-only verification")
        evidence[name] = {"store_opcode": stores[0]}
    return evidence


class Runner:
    def __init__(self, output: Path):
        self.output = output
        self.results: list[dict] = []

    def command(self, name: str, arguments: list[str]) -> str:
        logfile = self.output / f"{name}.log"
        try:
            result = subprocess.run(arguments, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, timeout=120, check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            logfile.write_text(shlex.join(arguments) + "\n" + str(error) + "\n")
            raise RuntimeError(f"{name}: {error}; see {logfile}") from error
        logfile.write_text(shlex.join(arguments) + "\n\n" + result.stdout)
        if result.returncode:
            raise RuntimeError(f"{name}: exit {result.returncode}; see {logfile}")
        return result.stdout

    def stage(self, name: str, operation) -> None:
        try:
            evidence = operation()
            result = {"name": name, "status": "pass", "evidence": evidence}
        except (RuntimeError, ValueError, OSError) as error:
            result = {"name": name, "status": "fail", "reason": str(error)}
        self.results.append(result)
        print(f"{name}: {result['status']}", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "build" / "engine-abi")
    parser.add_argument("--require-apple", action="store_true")
    parser.add_argument("--clang", help="Explicit target clang; defaults to xcrun --sdk iphoneos --find clang")
    parser.add_argument("--sdk", type=Path, help="Explicit iPhoneOS SDK path; defaults to xcrun")
    parser.add_argument("--cxx", help="Host C++ compiler; defaults to CXX or c++/g++")
    parser.add_argument("--arena-mib", type=int, default=2048,
                        help="Zero-fill image arena for link inspection only (1..3072 MiB)")
    args = parser.parse_args()
    if not 1 <= args.arena_mib <= 3072:
        parser.error("--arena-mib must be between 1 and 3072")
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    runner = Runner(output)
    cxx = args.cxx or os.environ.get("CXX") or shutil.which("c++") or shutil.which("g++")

    def relative_reference():
        if not cxx:
            raise RuntimeError("no host C++ compiler found")
        binary = output / "relative-reference"
        runner.command("relative-reference-build", [cxx, "-std=c++20", "-Wall", "-Wextra", "-Werror",
                       str(PROBES / "relative_reference_test.cpp"), "-o", str(binary)])
        return json.loads(runner.command("relative-reference-run", [str(binary)]))

    def host_address_diagnostic():
        if not cxx:
            raise RuntimeError("no host C++ compiler found")
        binary = output / "host-address-probe"
        runner.command("host-address-build", [cxx, "-std=c++20", "-Wall", "-Wextra", "-Werror", "-pthread",
                       "-DBO1_ADDRESS_PROBE_STANDALONE", str(PROBES / "apple_address_probe.cpp"), "-o", str(binary)])
        runner.command("host-address-run", [str(binary)])
        return {"runtime": "build-host-only", "ios_runtime_tested": False,
                "addresses_log": str(output / "host-address-run.log")}

    runner.stage("relative-reference", relative_reference)
    runner.stage("host-address-diagnostic", host_address_diagnostic)
    clang = args.clang
    sdk = str(args.sdk.resolve()) if args.sdk else None
    discovery_error = None
    if not clang or not sdk:
        xcrun = shutil.which("xcrun")
        if xcrun:
            try:
                clang = clang or runner.command("discover-clang", [xcrun, "--sdk", "iphoneos", "--find", "clang"]).strip()
                sdk = sdk or runner.command("discover-sdk", [xcrun, "--sdk", "iphoneos", "--show-sdk-path"]).strip()
            except RuntimeError as error:
                discovery_error = str(error)
        else:
            discovery_error = "xcrun/iPhoneOS SDK unavailable; Apple target checks were not executed"

    apple_stages = ["apple-toolchain", "ptr32-frontend-layout", "ptr32-store-O0", "ptr32-store-O2",
                    "macho-baseline", "macho-arena", "ios-address-object"]
    if clang and sdk:
        target_flags = ["-target", TARGET, "-isysroot", sdk]

        def apple_toolchain():
            version = runner.command("apple-clang-version", [clang, "--version"])
            if args.require_apple and "Apple clang" not in version:
                raise ValueError("--require-apple needs the Apple Clang compiler, not an upstream Clang cross-compiler")
            return {"compiler": clang, "version": version.strip(), "sdk": sdk, "target": TARGET}

        def frontend():
            ir = output / "apple-ptr32-layout.ll"
            runner.command("ptr32-frontend", [clang, *target_flags, "-std=c++20", "-fms-extensions", "-fdeclspec",
                           "-fsigned-char", "-Werror=ignored-attributes", "-S", "-emit-llvm",
                           str(PROBES / "apple_ptr32_layout.cpp"), "-o", str(ir)])
            contents = ir.read_text()
            if "p271:32:32" not in contents or "addrspace(271)" not in contents:
                raise ValueError("IR does not preserve the expected four-byte unsigned ptr32 address space")
            return {"layout_assertions_passed": True, "ir": str(ir),
                    "native_pointer_bytes": 8, "stored_pointer_bytes": 4,
                    "base_relative_codegen": False}

        def stores(optimization: str):
            assembly = output / f"ptr32-store-{optimization}.s"
            runner.command(f"ptr32-store-{optimization}", [clang, *target_flags, "-x", "ir", "-S",
                           f"-{optimization}", str(PROBES / "ptr32_store.ll"), "-o", str(assembly)])
            evidence = inspect_narrow_stores(assembly.read_text())
            evidence["assembly"] = str(assembly)
            evidence["runtime_tested"] = False
            return evidence

        def linked_image(arena: bool):
            name = "macho-arena" if arena else "macho-baseline"
            binary = output / name
            source = PROBES / ("macho_arena.cpp" if arena else "macho_baseline.c")
            flags = ["-std=c++20", f"-DBO1_PROBE_ARENA_MIB={args.arena_mib}"] if arena else []
            runner.command(name, [clang, *target_flags, *flags, str(source), "-o", str(binary)])
            evidence = inspect_macho(binary.read_bytes())
            evidence.update({"binary": str(binary), "runtime_tested": False})
            (output / f"{name}.json").write_text(json.dumps(evidence, indent=2) + "\n")
            for required in ("ios_target", "pie", "hard_pagezero_4gib", "text_above_4gib", "image_fits_relative32"):
                if not evidence[required]:
                    raise ValueError(f"{name}: {required}=false; see {name}.json")
            if arena and evidence["image_span_bytes"] < args.arena_mib * (1 << 20):
                raise ValueError("the requested zero-fill arena was not retained by the linker")
            return evidence

        def ios_address_object():
            obj = output / "ios-address-probe.o"
            runner.command("ios-address-object", [clang, *target_flags, "-std=c++20", "-Wall", "-Wextra", "-Werror",
                           "-c", str(PROBES / "apple_address_probe.cpp"), "-o", str(obj)])
            return {"object": str(obj), "ios_runtime_tested": False,
                    "integration": "call BO1ProbeAddressModel(FILE*) explicitly from a development device app"}

        runner.stage("apple-toolchain", apple_toolchain)
        runner.stage("ptr32-frontend-layout", frontend)
        runner.stage("ptr32-store-O0", lambda: stores("O0"))
        runner.stage("ptr32-store-O2", lambda: stores("O2"))
        runner.stage("macho-baseline", lambda: linked_image(False))
        runner.stage("macho-arena", lambda: linked_image(True))
        runner.stage("ios-address-object", ios_address_object)
    else:
        reason = discovery_error or "both a target Clang and an iPhoneOS SDK are required"
        runner.results.extend({"name": name, "status": "skip", "reason": reason} for name in apple_stages)
        print(reason, flush=True)

    failed = any(r["status"] == "fail" for r in runner.results)
    skipped = any(r["status"] == "skip" for r in runner.results)
    report = {"schema": 1, "source_revisions": REVISIONS, "target": TARGET,
              "all_requested_probes_passed": not failed and not skipped,
              "engine_ready": False, "engine_compiled": False, "ios_runtime_tested": False,
              "absolute_ptr32_ios_compatibility": "incompatible-with-normal-arm64-hard-pagezero",
              "base_relative_engine_abi": "not-implemented", "stages": runner.results}
    report_path = output / "report.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Report: {report_path}\nengine_ready=false; ios_runtime_tested=false", flush=True)
    return 1 if failed or (args.require_apple and skipped) else 0


if __name__ == "__main__":
    sys.exit(main())
