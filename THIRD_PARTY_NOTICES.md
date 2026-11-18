# Dependency notices and source provenance

This project builds the separately named **BO1 Port Diagnostics** app. That
binary includes platform/input code authored for this project, the independent
native audio mixer compiled from the pinned BO1 upstream, and static dependency
code. It does not include the gameplay engine or commercial game assets. No
BO2 HUD or Steam service source has been copied into this repository.

## Notices bundled in the diagnostics IPA

`scripts/package_diagnostics.py` copies the following **complete, unchanged
files** from the actual fetched sources/package into
`Payload/BO1PortDiagnostics.app/ThirdPartyNotices/`. It verifies their pinned
digests and fails if a required file is missing, empty, or different.

| Component | Exact source/package pin | Preserved notice |
| --- | --- | --- |
| SDL2 | `release-2.30.12`, `8236e01a9f758d15927624925c6043f84d8a261f` | `LICENSE.txt`, bundled as `SDL2-LICENSE.txt` |
| FFmpeg | `n7.1.3`, `f46e514491172d15bd74b4abb1814cd2f05a763e` | `COPYING.LGPLv2.1` and `LICENSE.md` |
| MoltenVK | Official `v1.4.2` iOS archive, SHA256 `b5d947b1660e6e9fed40b9cd2387e160aaab9e80b775c0cef7e14059405178c1` | Package `LICENSE`, bundled as `MoltenVK-LICENSE.txt` |
| DXVK | `v2.6.1`, `2b1a284f8453baa2bd193709b67e5183074c74ba` | `LICENSE`, bundled as `DXVK-LICENSE.txt` |

The SDL2 and DXVK files contain their upstream zlib-style notices. MoltenVK's
package preserves the Apache License 2.0 text. FFmpeg's `LICENSE.md` describes
the relationship between its components and license options; its complete
LGPL 2.1 text is included alongside that document. The project build recipe
does not enable FFmpeg's GPL, nonfree, or version-3 configure options. This
inventory records the files and configuration, rather than making a general
licensing-compliance claim.

The notice directory also contains this document, `provenance.json`,
`ios_dependencies.json`, and the actual audio and MoltenVK build receipts.
The provenance file records source revisions, package checksum, recipe and
patch hashes, upstream links, and notice hashes. The adjacent IPA manifest
records the included notice hashes as well as the executable and IPA hashes.

## Native audio source

The diagnostic compiles only `src/native/native_audio.cpp` with its header
from `Zephelinn/BO1-Ascension-ARM64` commit
`3401a66355c07d6c590049c2f42b7635c9bf00ac`. These files are byte-identical to
the inspected `SevyW/bo1-zombies-android` commit
`e121bab3412988b29534fad26c257adc24329818`; `cmake/ios_audio.cmake` checks
both file hashes before compilation. The mixer is ordinary native-pointer
code, separate from the unresolved gameplay engine ABI.

The upstream `NOTICE.md` and `THIRD_PARTY_NOTICES.md` are preserved in the
bundle as `BO1-upstream-NOTICE.md` and
`BO1-upstream-THIRD_PARTY_NOTICES.md`. They describe the upstream project's
broader scope; they are not a statement that all of its listed components
are in this diagnostics app. No license grant for BO1 or the imported native
audio source is inferred from the upstream repository's availability.

## Build recipes and project source

The reproducible source/package pins are in `scripts/ios_dependencies.json`.
`scripts/build_ios_deps.py` builds SDL2/CoreAudio and the selected FFmpeg
audio components and fetches the static MoltenVK slice.
`cmake/ios_audio.cmake`, `cmake/dxvk-static.cmake`, and
`cmake/ios_diagnostics.cmake` define the native targets. DXVK's altered iOS
source is described by the exact patch series in `patches/dxvk/`; these
changes are not represented as an upstream DXVK release. The retained DXVK
notice also remains in `graphics/DXVK-LICENSE`.

No project-wide license has been selected for the newly authored project
source. Copying a dependency's license into the bundle does not apply that
license to this whole project or to BO1. Preserved notices and provenance
are separate from the retained native object/archive build inputs and from
verification that a modified binary can be relinked and run on a device.

Primary source locations:

- [SDL2 at the selected revision](https://github.com/libsdl-org/SDL/tree/8236e01a9f758d15927624925c6043f84d8a261f)
- [FFmpeg at the selected revision](https://github.com/FFmpeg/FFmpeg/tree/f46e514491172d15bd74b4abb1814cd2f05a763e)
- [MoltenVK iOS release](https://github.com/KhronosGroup/MoltenVK/releases/tag/v1.4.2)
- [DXVK at the selected revision](https://github.com/doitsujin/dxvk/tree/2b1a284f8453baa2bd193709b67e5183074c74ba)
- [Native audio source](https://github.com/Zephelinn/BO1-Ascension-ARM64/blob/3401a66355c07d6c590049c2f42b7635c9bf00ac/src/native/native_audio.cpp)
- [Upstream BO1 notice](https://github.com/Zephelinn/BO1-Ascension-ARM64/blob/3401a66355c07d6c590049c2f42b7635c9bf00ac/NOTICE.md)
