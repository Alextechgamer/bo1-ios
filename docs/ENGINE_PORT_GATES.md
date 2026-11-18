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

This is now a confirmed incompatibility with the stock setup. The tested
AppleClang 17/Xcode 16.4 layout probe gives the required four-byte pointer
objects eight-byte storage. Apple's pinned ARM64 loader requires a protected
first 4 GiB. The normal iOS link and 2 GiB zero-fill image-arena experiments
preserve that protection and pass, but do not implement the engine's pointer
semantics. See [the actual compiler evidence and replacement ABI work](ENGINE_ABI.md).

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
The full static D3D9 CMake target now compiles the renderer, real EDID parser
and 60 shaders. CI force-loads the archive in a device link probe with real
static MoltenVK. [Validation](VALIDATION.md) records the exact observed build.

The BO1 native renderer also dynamically loads `libdxvk_d3d9.so`, selects SDL2,
and passes an SDL window handle. Replace that engine boundary with the intended
static D3D9 entry, Metal selection and `IOS_GetMetalWindowHandle()` token.
Avoid symbol collisions with the engine's separate D3D9 compatibility shim.

The pinned dependency script now builds CoreAudio SDL2 and minimal FFmpeg,
verifies a static MoltenVK package, and compiles the actual native audio mixer.
See [dependencies](DEPENDENCIES.md). A device capability query reports actual
Vulkan requirements before renderer creation. Stock MoltenVK 1.4.2 does not
provide the robustness/null-descriptor and geometry/cull features required by
this DXVK D3D9 path. Argument buffers do not fix that mismatch. Evaluate a real
fallback or compatible implementation using [the renderer evidence](../graphics/RENDERER_OPTIONS.md).

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

This repository now supplies a new draggable HUD, GameController frontend,
portable input transport and native BO1 gamepad adapter. It uses the actual
gamepad/native queue seam instead of importing BO2 guest-memory code or guessing
usercmd fields. The full engine still needs its checked `IN_Frame` patch,
exclusive input-producer ownership and lifecycle reset hook. The diagnostics
app tests input transport; gameplay and menu behavior remain separate checks.
See [the input integration contract](INPUT.md).

The BO2 Swift Steam authentication/content client is now adapted into a BO1
Game Files controller. It uses BO1 ownership AppIDs, current PICS manifests,
explicit package/language selection and Documents/game. It stages content,
verifies resumed chunks and publishes with recovery bookkeeping; an unfinished
publication marker closes the native host's asset gate. Account-change and
background cancellation must drain writers before a host completion callback.
The diagnostics app exposes this controller independently of the engine.
See [Steam downloads](STEAM_DOWNLOADS.md); a live account/download still needs
device verification and does not establish gameplay support.

Sources: [BO2 touch overlay](https://github.com/Alextechgamer/bo2-ios/blob/26aad790810596cf1038a5bca42bcf8789ccb54f/ios/TouchOverlay.m),
[BO2 Steam downloader](https://github.com/Alextechgamer/bo2-ios/blob/26aad790810596cf1038a5bca42bcf8789ccb54f/ios/SteamServices/BO2GameDownload.swift).

## 5. Prove gameplay, then package a real IPA

Start with one supported Zombies map and demonstrate engine initialization,
rendering, audio, controls, foreground/background transitions and repeated play.
The upstream feature table explicitly lists campaign as unavailable. Campaign
remains a separate implementation milestone, not an automatic result of the
iOS platform port. Combat Training likewise needs its own iOS validation.

After a real game target links, package and validate the game IPA. The current
separately named diagnostics app has its own entrypoint and no engine. Its IPA
can collect actual iPhone capability/input/audio evidence without claiming a
playable port. It does not satisfy this gameplay milestone.

Sources: [upstream feature scope](https://github.com/Zephelinn/BO1-Ascension-ARM64/blob/3401a66355c07d6c590049c2f42b7635c9bf00ac/README.md),
[Apple background GPU requirements](https://developer.apple.com/documentation/metal/preparing-your-metal-app-to-run-in-the-background),
[Vulkan queue synchronization](https://docs.vulkan.org/refpages/latest/refpages/source/vkDeviceWaitIdle.html).
