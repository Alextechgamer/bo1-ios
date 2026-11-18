# BO1 iOS — initial platform project

Target: `arm64-apple-ios`, iOS 16 or later. Intended game scope is Zombies,
offline Combat Training, and eventually campaign.

This initial project implements the UIKit launch host and a Metal WSI provider
for the real DXVK v2.6.1 interface. **It is not a runnable Black Ops port and
does not contain an IPA.** The supplied handoff is treated as a specification,
not evidence that its engine, input bridge, downloader, or build already exists.

## Implemented here

| Component | Behavior and current limit |
| --- | --- |
| UIKit app host | App delegate, CAMetalLayer view, physical pixel sizing, landscape layout, Files instructions and startup gate. Apple SDK/device execution remains unverified. |
| Game thread | One checked launch attempt on a detached 64 MiB pthread; explicit initialization, exception and return handling. This does not solve the engine's low-address pointer ABI. |
| Input/HUD integration | A real HUD is mounted through the required native adapter and input is submitted each display tick. No native BO1 HUD implementation is supplied yet. |
| Lifecycle | Resign-active requests pause, resets input and calls an explicit renderer drain contract; foreground prepares resources before releasing pause. The actual engine/DXVK submission synchronization remains to be implemented. |
| Download integration | A real BO1 downloader can supply a view controller through the adapter. Files import is the immediate UI path. No BO2 downloader is silently repurposed. |
| Metal/Vulkan bridge | Retained CAMetalLayer, stable opaque HWND token, atomic drawable dimensions, static MoltenVK surface creation and explicit errors. |
| DXVK WSI | Complete v2.6.1 driver, factory registration, native build selection, static Vulkan loader patch and source-level behavioral tests against upstream. Not the whole DXVK renderer. |
| Build checks | Portable tests and an iOS static-library CMake target. A GitHub Actions workflow is provided for host tests and Apple SDK compilation; it has not run as part of this initial local delivery. |

The mandatory `BO1IOSCreateHostServices` factory has no default implementation.
An app link therefore cannot succeed until the actual engine, native input/HUD,
graphics configuration and suspend/resume adapter are supplied. This is intentional:
a platform-only launcher must not be presented as working gameplay.

## Files

| Path | Purpose |
| --- | --- |
| `ios/AppDelegate.mm`, `ios/GameViewController.mm`, `ios/main.mm` | UIKit entry, display/input loop, launch and lifecycle control |
| `ios/include/BO1IOSHostServices.h` | Explicit adapter contract for the real engine/HUD/downloader |
| `ios/ios_platform_bridge.mm` | Retained layer, published state, static MoltenVK surface creation |
| `ios/bo1_asset_gate.cpp` | Readable nonempty startup archive presence check |
| `graphics/dxvk/src/wsi/metal/wsi_platform_ios.cpp` | New Metal WSI provider overlay |
| `patches/dxvk/` | Pinned, checked, repeatable upstream integration patch |
| `tests/`, `graphics/tests/` | Executable host verification |
| `cmake/ios.cmake`, `CMakeLists.txt` | iOS 16 ARM64 static-platform compile targets |
| `.github/workflows/verify-platform.yml` | On-push/PR platform verification, not IPA publication |
| `docs/ENGINE_PORT_GATES.md` | Verified upstream assumptions and remaining work |
| `docs/VALIDATION.md` | Results and practical limits of verification |

No commercial game assets, proprietary executables, Steam credentials or
unbuilt dependency binaries are included.

## Run the checks

With Python 3, Git and a C++20 compiler on Linux or macOS:

```sh
python3 scripts/run_host_tests.py
git clone --branch v2.6.1 --depth 1 https://github.com/doitsujin/dxvk.git vendor/dxvk
git -C vendor/dxvk submodule update --init --depth 1 include/vulkan
python3 graphics/tests/run_wsi_tests.py vendor/dxvk
```

The WSI test applies the patch in a temporary worktree, compiles the real
upstream interface/dispatcher/loader, and removes that worktree afterward.
It uses deterministic host/Vulkan fakes; it does not render a frame.

To compile the platform archives against a real iPhone SDK on a Mac:

```sh
python3 patches/dxvk/apply.py vendor/dxvk
cmake -S . -B build-ios -G Xcode \
  -DCMAKE_TOOLCHAIN_FILE=cmake/ios.cmake \
  -DBO1_BUILD_IOS_PLATFORM=ON -DBUILD_TESTING=OFF \
  -DBO1_DXVK_SOURCE_DIR="$PWD/vendor/dxvk"
cmake --build build-ios --config Release -- CODE_SIGNING_ALLOWED=NO
```

This compiles `bo1_ios_host`, `bo1_ios_entrypoint`, and `bo1_dxvk_platform`.
It does not link a game or prove missing engine symbols exist. The eventual
game target must use the complete DXVK library, not both its platform objects
and duplicate copies from this verification archive.

For CMake-based portable testing:

```sh
cmake -S . -B build-host
cmake --build build-host
ctest --test-dir build-host --output-on-failure
```

## Adapter responsibilities

Implement `BO1IOSCreateHostServices` using the actual engine port, then link it
with `ios/main.mm` and the host. The adapter configures `BO1_IOS_BASEPATH` to
the supplied `Documents/game` directory before initialization. It selects the
Metal WSI and supplies `IOS_GetMetalWindowHandle()` to D3D9. It links static
MoltenVK and the complete iOS DXVK renderer, enables the advertised surface
extensions, and verifies actual required Vulkan device features.

The adapter must supply real native touch/controller input with held-state and
one-time look-delta semantics. The host owns the display link; do not create a
second one in the HUD. Requested 120 Hz input/display callbacks are not a claim
that the game renders at 120 FPS.

Suspension is a renderer synchronization operation. Stop new work, serialize
and drain submission workers, pause audio, and leave the gate closed even if
draining reports an error. Never synchronously dispatch to the UIKit thread
while it is waiting for this acknowledgment. Do not simply call
`vkDeviceWaitIdle` from the app delegate while other threads submit commands.

The optional downloader must write to the same game directory, stop all writes
before completion, and provide its own Cancel control. Its sheet cannot be
gesture-dismissed. A reported error/cancellation never auto-launches the game.
The archive gate checks only a readable, nonempty `zone/Common/common.ff` or
`common_zombie.ff`; it cannot establish that all selected-mode files are valid.

See [the engine port gates](docs/ENGINE_PORT_GATES.md) before connecting a
native engine. The largest blocker is its pointer/address model, not UIKit.
