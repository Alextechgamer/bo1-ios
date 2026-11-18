# Native D3D9 and Metal integration

This directory contains the Metal WSI provider, static native D3D9 entry
points, a real driver capability query, and link verification for the pinned
DXVK v2.6.1. `cmake/dxvk-static.cmake` builds the complete native D3D9 renderer
and its 60 shaders from the separately fetched source checkout. It does not
build the T5 engine or claim a working game renderer.

**Runtime blocker:** stock MoltenVK v1.4.2 does not advertise
`robustBufferAccess2`, `nullDescriptor`, `geometryShader`, or
`shaderCullDistance`, all required by this DXVK D3D9 path. Metal argument
buffers do not change the first two feature values in that pinned driver.
Successful compilation and static linking are separate from device creation.
See [renderer options and exact source evidence](RENDERER_OPTIONS.md) before
choosing the next rendering milestone.

## Pinned dependency

| Dependency | Revision |
| --- | --- |
| `doitsujin/dxvk`, tag `v2.6.1` | `2b1a284f8453baa2bd193709b67e5183074c74ba` |
| Its DirectX headers submodule | `9df86f2341616ef1888ae59919feaa6d4fad693d` |
| Its SPIRV-Headers submodule | `8b246ff75c6615ba4532fe4fde20f1be090c3764` |
| Its Vulkan-Headers submodule | `234c4b7370a8ea3239a214c9e871e4b17c89f4ab` |
| Its libdisplay-info submodule | `275e6459c7ab1ddd4b125f28d0440716e4888078` |
| MoltenVK, tag `v1.4.2` | `db66022459ffb663aa2b50f6b018bc2e124f5edf` |

The Android BO1 upstream pins this DXVK version in
[`tools/native/build-dxvk.sh`](https://github.com/SevyW/bo1-zombies-android/blob/e121bab3412988b29534fad26c257adc24329818/tools/native/build-dxvk.sh).
Its backend is SDL2 WSI with Android loader-specific patches. This iOS overlay
implements the actual `dxvk::wsi::WsiDriver` interface, including monitor and
window methods; it is not a replacement for an assumed Android-only class.

## Apply the overlay

From the project root, choose an **empty** separate dependency destination:

```sh
git clone --branch v2.6.1 --depth 1 --recurse-submodules --shallow-submodules \
  https://github.com/doitsujin/dxvk.git vendor/dxvk
python3 patches/dxvk/apply.py vendor/dxvk
```

Do not clone into `graphics/dxvk/`: that directory intentionally holds only
the new overlay source. The script verifies the exact upstream commit,
checks patch applicability before modifying files, and refuses to overwrite
a different existing provider. Running it again with the same overlay is
supported.

The first patch makes these changes:

- Registers `MetalWSI` in `wsi_platform.h` and `wsi_platform.cpp`, with `Metal`
  as the default provider for a `DXVK_WSI_METAL` build.
- Adds `metal/wsi_platform_ios.cpp` to `src/wsi/meson.build`.
- Adds a Metal selection path to the upstream Meson configuration, avoiding
  the otherwise mandatory SDL/GLFW WSI dependency.
- Makes `vulkan_loader.cpp` take the statically linked
  `vkGetInstanceProcAddr`; it does not try to load `libvulkan.so` on iOS.
- Makes the native Win32 compatibility declarations available on Apple
  platforms, where `__unix__` alone is not a sufficient guard.

The second patch adds Apple's executable-path and thread-name APIs, prefixes
the static D3D9 factory/export names to prevent collisions with the engine
shim, and enables `VK_KHR_portability_subset` plus only the portability
features reported by the actual driver. Neither patch invents unsupported
Vulkan features or removes the renderer's feature requirements.

The third patch resolves Darwin's distinct `size_t` and `uint64_t` typedefs
when selecting the leading-zero-count overload for vector capacity growth.
It retains the original 32-bit or 64-bit calculation width.

For a CMake integration, compile the patched WSI dispatcher, the provider,
and the patched Vulkan loader with `DXVK_WSI_METAL=1` and
`VK_USE_PLATFORM_METAL_EXT=1`. Add `ios/include`, DXVK's native Windows headers,
and the pinned Vulkan headers to the include paths. The final app must link
the static MoltenVK library and the other real DXVK component libraries.
Do not set `VK_NO_PROTOTYPES` for these translation units: the static loader
deliberately takes the linked Vulkan entry-point address.

The upstream Meson switch is:

```text
-Ddxvk_native_wsi=metal
-Dios_platform_bridge_include=/absolute/path/to/bo1-ios/ios/include
```

Those switches select this provider. The full static iOS build uses the
CMake module below: upstream's non-Windows Meson D3D9 shared-library target
still has ELF linker options unsuitable for the static Apple target.

## Full static build and link verification

The existing root CMake configuration provides this build on a Mac with the
iOS SDK, the fetched dependencies, Python 3, Git, and a **host**
`glslangValidator` or `glslang` executable:

```sh
cmake -S . -B build/ios-native -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
  -DBO1_BUILD_IOS_PLATFORM=ON -DBO1_BUILD_IOS_DXVK=ON \
  -DBO1_DXVK_SOURCE_DIR="$PWD/vendor/dxvk" \
  -DBO1_IOS_DEPS_DIR="$PWD/third_party/ios"
cmake --build build/ios-native --config Release --target bo1_dxvk_link_probe
```

The module rejects an unexpected DXVK revision, mismatched submodule pins,
or an incomplete patch series. Its explicit source manifest comes from the
pinned upstream Meson lists. It builds D3D9, DXSO, DXVK, SPIR-V, Vulkan, native
utilities, WSI, and the real EDID parser; it does not glob unrelated D3D11 or
Windows VR source into the target. Shader headers use the upstream symbol
names and Vulkan 1.3 target. All 60 shader basenames are distinct.

The archive exports `BO1_DXVK_Direct3DCreate9` and
`BO1_DXVK_Direct3DCreate9Ex`. Include `graphics/include/bo1_dxvk_d3d9.h` from
the native 64-bit side of the engine adapter. Do not mix the engine's pointer
representation or D3D9 compatibility headers into these translation units.

The link probe force-loads every object in the DXVK archive and links the
actual UIKit platform bridge plus the actual arm64 static MoltenVK slice.
It has no fake renderer functions, unresolved-symbol escape, UIKit game app,
or downloaded game assets. It takes the factory/query addresses and performs
no GPU work. This verifies symbol/SDK linkage; it cannot establish that the
renderer can create a device or draw a frame.

Do not link both `bo1_dxvk_platform` and `bo1_dxvk_d3d9` into an executable:
the full renderer already contains the WSI and Vulkan loader objects. The
smaller platform archive is retained as an independent platform compile
target.

## Driver capability report

`graphics/include/bo1_dxvk_capabilities.h` exposes
`BO1_DXVK_QueryD3D9Baseline`. Given a physical device belonging to a live
instance from the linked Vulkan implementation, it queries the driver for
the exact pinned D3D9 baseline and sends each requirement name and support
value to the supplied callback. The function creates no device, surface,
command buffer, or GPU submission. It returns:

- `VK_SUCCESS` when all checked baseline features, device extensions, and a
  combined graphics/compute queue family are advertised;
- `VK_ERROR_FEATURE_NOT_PRESENT` plus a nonzero `missingRequirements` count
  when the baseline is unsupported;
- the Vulkan enumeration error, initialization error, or host allocation
  error when the query itself cannot complete.

The engine adapter should call this before attempting renderer creation and
show the missing requirements in its startup diagnostic. This is a callable
diagnostic, not an already connected engine integration. A successful query
does not test surface presentation, texture format details, SPIR-V/MSL
translation, device limits, or correct output.

## Host bridge contract

The shared declarations are in `ios/include/ios_platform_bridge.h`.

| Provider need | Host contract |
| --- | --- |
| Window identity | D3D9 `hDeviceWindow` and `hFocusWindow` must contain `IOS_GetMetalWindowHandle()`. The provider rejects unrelated handles. |
| Layer lifetime | Register the layer before creating DXVK; retain it until rendering has stopped and Vulkan surfaces are destroyed. |
| Pixel dimensions | Publish `CAMetalLayer.drawableSize` through `IOS_UpdateDrawableMetrics` from main-thread layout. Worker queries read the published snapshot. |
| Refresh information | Publish the window screen's maximum refresh rate with the metrics. A requested CADisplayLink rate does not promise game FPS. |
| Surface | `IOS_CreateVulkanMetalSurface` returns the real `VkResult` and clears the output on failure. The instance must use the linked MoltenVK loader. |
| Instance extensions | Enable `VK_KHR_surface` and `VK_EXT_metal_surface`, which the provider advertises. A preprocessor definition alone does not enable them at runtime. |
| Pause state | `IOS_RequestScenePause` supplies visibility state only. The engine adapter must stop and drain all GPU submission workers separately. |

The provider performs no UIKit calls, resizes, main-queue synchronous
dispatches, audio operations, or device-idle waits. It exposes one current
screen mode and lets the DXVK presenter scale a different-sized D3D9
backbuffer. It does not claim that it can change iOS display modes.

`createSurface` checks that the DXVK loader proc equals the linked
`vkGetInstanceProcAddr`. The static bridge does not accept a foreign loader
instance. To support another loader in the future, extend the bridge to
accept that loader's proc and use it consistently throughout instance,
surface, and device creation.

## Verification boundaries

The full pinned source archive and all 60 shaders have compiled with a
Linux host C++20 compiler and real glslang 15.1.0. A whole-archive relocatable
link resolved the internal DXVK symbols and retained the expected platform
and Vulkan imports. This host result cannot validate Apple SDK declarations
or MoltenVK rendering; the Apple CI link target is the separate SDK gate.
The small capability-query source has also compiled against the pinned
Vulkan headers. It has not been executed on an iPhone.

On a machine with Git and a C++20 compiler:

```sh
python3 graphics/tests/run_wsi_tests.py /absolute/path/to/dxvk-v2.6.1
```

The supplied checkout needs its pinned Vulkan-Headers submodule. The script
creates a temporary worktree at the exact DXVK commit, applies the patch and
provider, compiles the **real** driver contract/dispatcher/loader, then runs
behavioral assertions. It removes the temporary worktree afterward.

The harness covers provider registration and reference counting; extension
names; registered/foreign/null window handles; optional size outputs; size
changes; empty drawable and pause visibility; monitor and display-mode
behavior; surface argument validation; loader identity; surface error
propagation; unregistration; and the linked Vulkan-loader path. Only the
host bridge and Vulkan proc are deterministic fakes. Passing this test does
not establish Metal rendering, Objective-C compilation, performance, or
safe backgrounding on a phone.

## Lifecycle boundary

Apple requires stopping new Metal commits when the app deactivates and
ensuring previously committed work is scheduled before returning from the
background callback. A pause bool alone does not drain DXVK's workers.
Calling `vkDeviceWaitIdle` from UIKit while DXVK still accesses its queues
also violates Vulkan's queue synchronization requirement. Implement that
handshake in the real renderer/engine adapter before claiming background
suspension support.

Primary references:

- [DXVK v2.6.1 WsiDriver](https://github.com/doitsujin/dxvk/blob/v2.6.1/src/wsi/wsi_platform.h)
- [DXVK v2.6.1 Vulkan loader](https://github.com/doitsujin/dxvk/blob/v2.6.1/src/vulkan/vulkan_loader.cpp)
- [MoltenVK runtime guide](https://github.com/KhronosGroup/MoltenVK/blob/main/Docs/MoltenVK_Runtime_UserGuide.md)
- [Apple: preparing Metal for background execution](https://developer.apple.com/documentation/metal/preparing-your-metal-app-to-run-in-the-background)
- [Vulkan: device-idle host synchronization](https://docs.vulkan.org/refpages/latest/refpages/source/vkDeviceWaitIdle.html)

The upstream license is preserved in `DXVK-LICENSE`. The overlay and patch
are altered/additional sources and are not represented as upstream DXVK.
