# DXVK Metal WSI integration

This directory contains an **original iOS provider overlay for DXVK v2.6.1**,
not a complete copy of DXVK and not a working game renderer. The companion
patch changes upstream registration, source selection, and Vulkan loading.
The provider and patch have host-side contract tests against the actual
upstream headers, dispatcher, and loader. They have not rendered on iOS.

## Pinned dependency

| Dependency | Revision |
| --- | --- |
| `doitsujin/dxvk`, tag `v2.6.1` | `2b1a284f8453baa2bd193709b67e5183074c74ba` |
| Its Vulkan-Headers submodule | `234c4b7370a8ea3239a214c9e871e4b17c89f4ab` |

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

The patch makes these changes:

- Registers `MetalWSI` in `wsi_platform.h` and `wsi_platform.cpp`, with `Metal`
  as the default provider for a `DXVK_WSI_METAL` build.
- Adds `metal/wsi_platform_ios.cpp` to `src/wsi/meson.build`.
- Adds a Metal selection path to the upstream Meson configuration, avoiding
  the otherwise mandatory SDL/GLFW WSI dependency.
- Makes `vulkan_loader.cpp` take the statically linked
  `vkGetInstanceProcAddr`; it does not try to load `libvulkan.so` on iOS.
- Makes the native Win32 compatibility declarations available on Apple
  platforms, where `__unix__` alone is not a sufficient guard.

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

Those switches select this provider; **they do not make the entire unmodified
DXVK library an iOS-ready target**. For example, v2.6.1's D3D9 Meson target
still uses an ELF version-script linker flag on non-Windows platforms, and
`util_env::getExePath()` lacks an Apple implementation. Full DXVK archive
packaging, shader generation, Apple compilation, device capability checks,
and its Vulkan device-extension configuration remain integration work.

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

## Verification

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
