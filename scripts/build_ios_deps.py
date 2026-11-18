#!/usr/bin/env python3
"""Build pinned SDL2/CoreAudio and FFmpeg for iOS, and fetch static MoltenVK.

No game source, credentials, or commercial assets are downloaded by this script.
Use --fetch-only on non-Apple hosts; compilation requires Xcode's device SDK.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import plistlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
LOCK = json.loads((ROOT / "scripts/ios_dependencies.json").read_text())
DECODERS = "wmav1,wmav2,wmapro,wmavoice,adpcm_ms,pcm_s16le,pcm_s16be,pcm_f32le"
DEMUXERS = "xwma,asf,wav,pcm_s16le"


def run(command, cwd=None, capture=False):
    print("+ " + " ".join(map(str, command)), flush=True)
    result = subprocess.run(list(map(str, command)), cwd=cwd, check=True,
                            text=True, stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else None


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def checkout(name, source_root):
    pin = LOCK[name]
    destination = source_root / name
    if not destination.exists():
        run(["git", "clone", "--depth", "1", "--branch", pin["ref"],
             pin["url"], destination])
    actual = run(["git", "-C", destination, "rev-parse", "HEAD"], capture=True)
    if actual != pin["revision"]:
        raise RuntimeError(f"{destination}: expected {pin['revision']}, got {actual}; refusing to reset it")
    if run(["git", "-C", destination, "status", "--porcelain"], capture=True):
        raise RuntimeError(f"{destination}: source has local edits; use a separate clean checkout")
    return destination


def fetch_moltenvk(prefix, archive=None):
    pin = LOCK["moltenvk"]
    destination = prefix / "MoltenVK"
    receipt_path = destination / "bo1-source.json"
    library = destination / pin["library"]
    if destination.exists():
        if not receipt_path.is_file():
            raise RuntimeError(f"{destination} exists without a receipt; refusing to replace it")
        receipt = json.loads(receipt_path.read_text())
        if (receipt.get("archive_sha256") != pin["sha256"] or not library.is_file()
                or not (destination / "LICENSE").is_file()
                or receipt.get("library_sha256") != sha256(library)):
            raise RuntimeError(f"{destination}: MoltenVK version or library digest mismatch")
        return library
    prefix.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="bo1-mvk-", dir=prefix) as temporary:
        temporary = Path(temporary)
        if archive is None:
            archive = temporary / "MoltenVK-ios.tar"
            print(f"Downloading pinned MoltenVK {pin['version']}", flush=True)
            request = urllib.request.Request(pin["url"], headers={"User-Agent": "bo1-ios-dependency-build"})
            with urllib.request.urlopen(request, timeout=120) as response, archive.open("wb") as output:
                shutil.copyfileobj(response, output)
        if sha256(archive) != pin["sha256"]:
            raise RuntimeError("MoltenVK archive checksum does not match ios_dependencies.json")
        staging = temporary / "package"
        staging.mkdir()
        # Copy only regular files from the static distribution and headers. No
        # archive symlinks, device files or arbitrary extractall paths are used.
        with tarfile.open(archive, "r:") as package:
            for member in package:
                path = PurePosixPath(member.name)
                if path.is_absolute() or ".." in path.parts:
                    raise RuntimeError("Unexpected unsafe path in MoltenVK distribution")
                if member.name == "MoltenVK/LICENSE" and member.isfile():
                    with package.extractfile(member) as source, (staging / "LICENSE").open("wb") as output:
                        shutil.copyfileobj(source, output)
                    continue
                try:
                    relative = path.relative_to("MoltenVK/MoltenVK")
                except ValueError:
                    continue
                if not relative.parts or relative.parts[0] not in ("static", "include", "LICENSE"):
                    continue
                if member.isfile():
                    target = staging.joinpath(*relative.parts)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with package.extractfile(member) as source, target.open("wb") as output:
                        shutil.copyfileobj(source, output)
        static_library = staging / pin["library"]
        if not (staging / "LICENSE").is_file():
            raise RuntimeError("MoltenVK distribution is missing its license notice")
        with static_library.open("rb") as source:
            if source.read(8) != b"!<arch>\n":
                raise RuntimeError("MoltenVK device slice is not a static archive")
        info = plistlib.loads((staging / "static/MoltenVK.xcframework/Info.plist").read_bytes())
        if not any(item.get("SupportedPlatform") == "ios"
                   and not item.get("SupportedPlatformVariant")
                   and item.get("SupportedArchitectures") == ["arm64"]
                   and item.get("LibraryIdentifier") == "ios-arm64"
                   for item in info["AvailableLibraries"]):
            raise RuntimeError("Missing iphoneos ARM64 slice in MoltenVK XCFramework")
        (staging / "bo1-source.json").write_text(json.dumps({
            "version": pin["version"], "archive_sha256": pin["sha256"],
            "library_sha256": sha256(static_library)}, indent=2) + "\n")
        staging.rename(destination)
    return library


def verify_archive(path):
    if not path.is_file():
        raise RuntimeError(f"Expected static library missing: {path}")
    run(["xcrun", "lipo", "-verify_arch", "arm64", path])


def build(args, sources):
    sdk = run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], capture=True)
    cc = run(["xcrun", "--sdk", "iphoneos", "--find", "clang"], capture=True)
    cxx = run(["xcrun", "--sdk", "iphoneos", "--find", "clang++"], capture=True)
    version = run([cc, "--version"], capture=True)
    # A different SDK/compiler/script uses a separate build directory; an old
    # configure result can never silently stand in for a new set of options.
    fingerprint = hashlib.sha256((json.dumps(LOCK, sort_keys=True) + sdk + version
        + args.deployment_target + str(args.prefix)
        + Path(__file__).read_text()).encode()).hexdigest()[:16]
    build_root = args.build_root / fingerprint
    build_root.mkdir(parents=True, exist_ok=True)
    sdl_build = build_root / "sdl2"
    sdl_prefix = args.prefix / "SDL2-ios"
    run(["cmake", "-S", sources["sdl2"], "-B", sdl_build, "-G", "Ninja",
        "-DCMAKE_SYSTEM_NAME=iOS", f"-DCMAKE_OSX_SYSROOT={sdk}",
        "-DCMAKE_OSX_ARCHITECTURES=arm64", f"-DCMAKE_OSX_DEPLOYMENT_TARGET={args.deployment_target}",
        "-DCMAKE_BUILD_TYPE=Release", f"-DCMAKE_INSTALL_PREFIX={sdl_prefix}",
        "-DCMAKE_POLICY_VERSION_MINIMUM=3.5", "-DSDL_SHARED=OFF", "-DSDL_STATIC=ON",
        "-DSDL_TEST=OFF", "-DSDL_TESTS=OFF", "-DSDL2_DISABLE_SDL2MAIN=ON",
        "-DSDL_AUDIO=ON", "-DSDL_VIDEO=OFF", "-DSDL_RENDER=OFF", "-DSDL_HAPTIC=OFF",
        "-DSDL_JOYSTICK=OFF", "-DSDL_SENSOR=OFF", "-DSDL_POWER=OFF", "-DSDL_MISC=OFF",
        "-DSDL_DISKAUDIO=OFF", "-DSDL_DUMMYAUDIO=OFF", "-DSDL_SYSTEM_ICONV=OFF"])
    run(["cmake", "--build", sdl_build, "--parallel", args.jobs])
    run(["cmake", "--install", sdl_build])
    config_headers = list(sdl_build.rglob("SDL_config.h"))
    if not any("#define SDL_AUDIO_DRIVER_COREAUDIO 1" in path.read_text() for path in config_headers):
        raise RuntimeError("SDL2 was built without the CoreAudio backend")

    ffmpeg_build = build_root / "ffmpeg"
    ffmpeg_build.mkdir(exist_ok=True)
    ffmpeg_prefix = args.prefix / "ffmpeg-ios"
    flags = f"-arch arm64 -isysroot {sdk} -miphoneos-version-min={args.deployment_target}"
    configure = [sources["ffmpeg"] / "configure", f"--prefix={ffmpeg_prefix}",
        "--enable-cross-compile", "--target-os=darwin", "--arch=aarch64", "--cpu=armv8-a",
        f"--cc={cc}", f"--cxx={cxx}", f"--sysroot={sdk}", f"--extra-cflags={flags}",
        f"--extra-ldflags={flags}", "--disable-everything", "--disable-autodetect",
        "--disable-programs", "--disable-doc", "--disable-debug", "--disable-network",
        "--disable-avdevice", "--disable-avfilter", "--disable-swscale", "--disable-postproc",
        "--disable-audiotoolbox", "--disable-videotoolbox", "--disable-securetransport",
        "--disable-iconv", "--disable-zlib", "--disable-bzlib", "--disable-lzma",
        "--enable-static", "--disable-shared", "--enable-pic", "--enable-pthreads",
        "--enable-avcodec", "--enable-avformat", "--enable-avutil", "--enable-swresample",
        f"--enable-decoder={DECODERS}", f"--enable-demuxer={DEMUXERS}", "--enable-protocol=file"]
    for tool in ("ar", "nm", "ranlib", "strip"):
        configure.append(f"--{tool}=" + run(["xcrun", "--sdk", "iphoneos", "--find", tool], capture=True))
    run(configure, cwd=ffmpeg_build)
    run(["make", f"-j{args.jobs}"], cwd=ffmpeg_build)
    run(["make", "install"], cwd=ffmpeg_build)
    config = (ffmpeg_build / "config_components.h").read_text()
    for name, suffix in [(item, "DECODER") for item in DECODERS.split(",")] + [
            (item, "DEMUXER") for item in DEMUXERS.split(",")]:
        if f"#define CONFIG_{name.upper()}_{suffix} 1" not in config:
            raise RuntimeError(f"FFmpeg did not enable {name} {suffix.lower()}")
    libraries = [sdl_prefix / "lib/libSDL2.a"] + [
        ffmpeg_prefix / f"lib/lib{name}.a" for name in ("avformat", "avcodec", "swresample", "avutil")]
    for library in libraries:
        verify_archive(library)
    (args.prefix / "audio-build.json").write_text(json.dumps({
        "target": "arm64-apple-ios", "deployment_target": args.deployment_target,
        "sdk": sdk, "compiler": version, "sources": {name: LOCK[name] for name in sources},
        "decoders": DECODERS.split(","), "demuxers": DEMUXERS.split(","),
        "archives": {str(path.relative_to(args.prefix)): sha256(path) for path in libraries},
    }, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=ROOT / "vendor")
    parser.add_argument("--prefix", type=Path, default=ROOT / "third_party/ios")
    parser.add_argument("--build-root", type=Path, default=ROOT / "build-deps")
    parser.add_argument("--deployment-target", default="16.0")
    parser.add_argument("--jobs", type=int, default=min(8, os.cpu_count() or 2))
    parser.add_argument("--fetch-only", action="store_true")
    parser.add_argument("--moltenvk-only", action="store_true")
    parser.add_argument("--moltenvk-archive", type=Path, help="Use a local copy; the same SHA256 is required")
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    if not args.fetch_only and not args.moltenvk_only and platform.system() != "Darwin":
        parser.error("iOS dependency compilation requires macOS/Xcode; use --fetch-only on this host")
    for attribute in ("source_root", "prefix", "build_root"):
        setattr(args, attribute, getattr(args, attribute).resolve())
    args.prefix.mkdir(parents=True, exist_ok=True)
    library = fetch_moltenvk(args.prefix, args.moltenvk_archive)
    print(f"Static MoltenVK: {library}", flush=True)
    if args.moltenvk_only:
        return
    args.source_root.mkdir(parents=True, exist_ok=True)
    sources = {name: checkout(name, args.source_root) for name in ("sdl2", "ffmpeg")}
    if not args.fetch_only:
        build(args, sources)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f"Dependency build failed: {error}")
