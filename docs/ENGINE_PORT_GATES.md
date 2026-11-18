# Engine integration gates

The project begins from a proposed architecture. The following observations
come from pinned upstream source, not a successful iPhone run.

## Inspected revisions

| Source | Revision |
| --- | --- |
| Zephelinn/BO1-Ascension-ARM64 | `3401a66355c07d6c590049c2f42b7635c9bf00ac` |
| SevyW/bo1-zombies-android | `e121bab3412988b29534fad26c257adc24329818` |
| Alextechgamer/bo2-ios | `26aad790810596cf1038a5bca42bcf8789ccb54f` |
| doitsujin/dxvk v2.6.1 | `2b1a284f8453baa2bd193709b67e5183074c74ba` |

## 1. Establish a correct iOS engine address model

The Android ARM64 build keeps four-byte pointer objects inside a 64-bit process.
It rewrites the source through `tools/p32`, uses `__ptr32 __uptr`, and depends
on a patched Clang toolchain. Engine-addressable data, code, globals and stacks
must stay below 4 GiB. The Android loader and ELF linker arrangement establish
that property there; an ordinary Apple Clang source glob does not.

Before linking gameplay, prove an iOS/Mach-O implementation of the address
scheme or implement and validate a different layout-preserving approach.
Keep the engine's structure assertions enabled. Exercise stored pointers,
function pointers, variadic boundaries, allocation and thread-stack addresses.
Dropping pointer annotations without fixing the underlying layout assumptions
would change asset/structure representations.

The requested 64 MiB pthread in this project controls stack capacity only.
Upstream uses `pthread_attr_setstack` with a low-heap allocation. Its 16 MiB
stack is deliberately located below 4 GiB. A larger ordinary pthread stack is
not a substitute for that address requirement.

Sources: [native pointer definitions](https://github.com/SevyW/bo1-zombies-android/blob/e121bab3412988b29534fad26c257adc24329818/src/native/native_p32.h),
[low-memory allocator](https://github.com/SevyW/bo1-zombies-android/blob/e121bab3412988b29534fad26c257adc24329818/src/native/native_lowmem.c),
[native architecture](https://github.com/Zephelinn/BO1-Ascension-ARM64/blob/3401a66355c07d6c590049c2f42b7635c9bf00ac/docs/android-port.md),
[native CMake](https://github.com/SevyW/bo1-zombies-android/blob/e121bab3412988b29534fad26c257adc24329818/cmake/native.cmake).

## 2. Adapt the actual engine entry and frame loop

The inspected native build enters `EngineMain` in `src/web/web_main.cpp` through
`bo1_android_main` on Android or ordinary `main` elsewhere. There is no
`Sys_Main` matching the handoff. The frame loop also lives in that file, not
the proposed `engine/src/universal/win_main.cpp`.

Expose an explicit iOS engine entry without importing Android's dynamic loader.
Its argument/storage lifetimes and pointer conversions must meet the chosen
engine ABI. Wire scene suspension into all rendering paths, including the
engine's separate render worker and DXVK submission workers.

Source: [actual entry and frame loop](https://github.com/SevyW/bo1-zombies-android/blob/e121bab3412988b29534fad26c257adc24329818/src/web/web_main.cpp).

## 3. Complete the static renderer and audio build

The supplied Metal provider replaces the actual DXVK v2.6.1 SDL2 WSI path.
It implements the full `WsiDriver` contract, not only two free functions.
Its factory and loader patches are included. Full iOS DXVK compilation and
linking still need the remaining Apple platform changes and shader generation.

The BO1 native renderer also dynamically loads `libdxvk_d3d9.so`, selects SDL2,
and passes an SDL window handle. Replace that engine boundary with the intended
static D3D9 entry, Metal selection and `IOS_GetMetalWindowHandle()` token.
Avoid symbol collisions with the engine's separate D3D9 compatibility shim.

Build and verify pinned static MoltenVK, SDL2 and the required FFmpeg libraries
for the device SDK. Inspect actual Vulkan features/extensions before renderer
creation. An environment variable is not proof that a required feature works.
No dependency binaries or completed cross-compilation scripts are included in
this initial project.

The handoff's `dxvk.maxDeviceMemory` / `dxvk.maxSharedMemory` keys do not exist
in pinned DXVK. `dxgi.maxDeviceMemory` / `dxgi.maxSharedMemory` belong to DXGI.
The D3D9 option is `d3d9.maxAvailableMemory`, which controls its initial tracked
and reported texture-memory value; it is not an iOS process/Jetsam hard cap.
Choose actual memory policy after measuring the complete engine on the device.

Sources: [engine DXVK bridge](https://github.com/SevyW/bo1-zombies-android/blob/e121bab3412988b29534fad26c257adc24329818/src/native/vk/bo1vk_dxvk.cpp),
[DXVK options](https://github.com/doitsujin/dxvk/blob/v2.6.1/dxvk.conf),
[D3D9 memory reporting](https://github.com/doitsujin/dxvk/blob/v2.6.1/src/d3d9/d3d9_device.cpp).

## 4. Connect native controls and verified asset delivery

BO2's current reusable UI is `ios/TouchOverlay.h/.m`, not a `TouchHUD/` module.
It resolves BO2 exports with `dlsym` and reads lifted BO2 guest-memory offsets.
Reuse its layout/editor behavior only after replacing that runtime boundary
with real BO1 input and menu-state callbacks. Keep held input separate from
one-time accumulated look deltas. Validate any entity/death/trace constants
against the selected engine revision before enabling aim assist.

The current Steam implementation is a Swift service in
`ios/SteamServices/BO2GameDownload.swift`, driven by the launcher, not a ready
download view controller. It selects BO2 AppIDs and a different destination.
Its completion flag also represents errors/cancellation. Shared depot/DLC
eligibility logic must be adapted, rather than just replacing a depot table.

Sources: [BO2 touch overlay](https://github.com/Alextechgamer/bo2-ios/blob/26aad790810596cf1038a5bca42bcf8789ccb54f/ios/TouchOverlay.m),
[BO2 Steam downloader](https://github.com/Alextechgamer/bo2-ios/blob/26aad790810596cf1038a5bca42bcf8789ccb54f/ios/SteamServices/BO2GameDownload.swift).

## 5. Prove gameplay, then package a real IPA

Start with one supported Zombies map and demonstrate engine initialization,
rendering, audio, controls, foreground/background transitions and repeated play.
The upstream feature table explicitly lists campaign as unavailable. Campaign
remains a separate implementation milestone, not an automatic result of the
iOS platform port. Combat Training likewise needs its own iOS validation.

After a real game target links, add unsigned app-bundle/IPA packaging to CI.
The current verification workflow intentionally builds platform archives only.
Creating an IPA around a missing engine would not establish a playable port.

Sources: [upstream feature scope](https://github.com/Zephelinn/BO1-Ascension-ARM64/blob/3401a66355c07d6c590049c2f42b7635c9bf00ac/README.md),
[Apple background GPU requirements](https://developer.apple.com/documentation/metal/preparing-your-metal-app-to-run-in-the-background),
[Vulkan queue synchronization](https://docs.vulkan.org/refpages/latest/refpages/source/vkDeviceWaitIdle.html).
