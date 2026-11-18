# iOS dependencies

`scripts/ios_dependencies.json` pins source revisions and the MoltenVK release
checksum. `bash scripts/build_ios_deps.sh` builds device ARM64 libraries with an
iOS 16.0 deployment target. It requires macOS, Xcode, CMake, Ninja, Git and Make.
The same operation runs on GitHub Actions; a local Mac is not required to use CI.

| Dependency | Pin | Purpose |
| --- | --- | --- |
| SDL2 | 2.30.12 / `8236e01a9f758d15927624925c6043f84d8a261f` | Static CoreAudio output, threads and utility functions; its video and controller backends are disabled because UIKit and GameController own those surfaces. |
| FFmpeg | 7.1.3 / `f46e514491172d15bd74b4abb1814cd2f05a763e` | Static `avcodec`, `avformat`, `avutil`, `swresample`. The native engine uses the 7.1 API, so this follows its actual dependency family rather than the handoff's unverified 6.1.2 selection. |
| MoltenVK | 1.4.2 | Checksum-verified official static `ios-arm64` XCFramework slice; the dynamic framework is not installed. |

The FFmpeg build enables only WMA1, WMA2, WMA Pro, WMA Voice, Microsoft ADPCM,
PCM16 LE/BE and PCM32 float LE decoders; xWMA, ASF, WAV and raw PCM16 LE demuxers;
and local file access. It disables network protocols, video frameworks,
autodetected system dependencies, tools and shared libraries. The actual BO1
native mixer uses WMA2 for xWMA and decodes its PCM/ADPCM internally.

Outputs are under `third_party/ios/SDL2-ios`, `third_party/ios/ffmpeg-ios` and
`third_party/ios/MoltenVK`. An audio receipt records the compiler, SDK, source
pins, enabled formats and resulting archive hashes. Source checkouts with
different revisions or local changes are rejected instead of reset. SDK,
compiler or build-script changes select a fresh build directory.

## Commands

```sh
bash scripts/build_ios_deps.sh
# Fetch and check sources/package without requiring Xcode:
python3 scripts/build_ios_deps.py --fetch-only
# Override output location or build concurrency:
bash scripts/build_ios_deps.sh --prefix "$PWD/third_party/ios" --jobs 4
```

MoltenVK's release archive is checked against SHA256
`b5d947b1660e6e9fed40b9cd2387e160aaab9e80b775c0cef7e14059405178c1`.
Extraction copies regular files from the static package only, retains its
license, checks the XCFramework's device platform and verifies the library is
a static archive. Audio builds check all requested codec/demuxer definitions
and use `lipo` to verify ARM64 archives.

## Actual engine audio compilation

`BO1_BUILD_IOS_AUDIO=ON` compiles the unchanged native mixer selected with
`BO1_ENGINE_SOURCE_DIR`. CI uses `Zephelinn/BO1-Ascension-ARM64` revision
`3401a66355c07d6c590049c2f42b7635c9bf00ac`. Its audio source and header are byte
identical to the inspected `SevyW/bo1-zombies-android` revision
`e121bab3412988b29534fad26c257adc24329818`; both hashes are checked before building.
This mixer uses normal native pointers and is explicitly excluded from
upstream's pointer32 rewrite, so it can be verified independently of the game.

`bo1_audio_link_probe` links that mixer, real SDL2 and real FFmpeg into an ARM64
device executable, with no fake implementations or unresolved-symbol flags.
The probe is not an iOS app and is not run on the CI host. Link success does
not establish actual speaker output, interruptions, voice timing or scene
suspension. Those remain device/runtime integration work.

Sources: [SDL2 iOS CMake guidance](https://wiki.libsdl.org/SDL2/README-cmake),
[native audio source](https://github.com/SevyW/bo1-zombies-android/blob/e121bab3412988b29534fad26c257adc24329818/src/native/native_audio.cpp),
[upstream FFmpeg build](https://github.com/SevyW/bo1-zombies-android/blob/e121bab3412988b29534fad26c257adc24329818/tools/native/build-ffmpeg.sh),
[FFmpeg 7.1.3](https://github.com/FFmpeg/FFmpeg/tree/n7.1.3),
[MoltenVK 1.4.2 release](https://github.com/KhronosGroup/MoltenVK/releases/tag/v1.4.2),
[MoltenVK runtime requirements](https://github.com/KhronosGroup/MoltenVK/blob/v1.4.2/Docs/MoltenVK_Runtime_UserGuide.md).
