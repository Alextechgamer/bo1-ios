# Renderer compatibility and the next experiment

Source review: 2026-11-18. No renderer in this document has been demonstrated
running BO1 on iOS by this project. The present DXVK source/archive/link work
is retained as a reproducible integration baseline.

## Why upstream DXVK 2.6.1 plus stock MoltenVK does not work yet

The blocker is observable in the pinned code, independent of environment
variable tuning:

| Requirement | DXVK v2.6.1 source | Stock MoltenVK v1.4.2 source |
| --- | --- | --- |
| `robustBufferAccess2` | `DxvkAdapter::createDevice` always enables it and explains that alignment behavior is relied on | `MVKPhysicalDevice::getFeatures` writes `false` |
| `nullDescriptor` | Always enabled; the backend's old null-resource fallback has been removed | The same robustness2 feature query writes `false` |
| `geometryShader` | `D3D9DeviceEx::GetDeviceFeatures` requires it for internal operations | Core features begin cleared; `initFeatures` never enables it |
| `shaderCullDistance` | Required by the D3D9 device feature set | Never enabled by `initFeatures` |
| `textureCompressionBC` | Required by the D3D9 device feature set | Depends on the GPU's reported BC texture capability |

Exact sources:

- [DXVK adapter/device requirements at the project pin](https://github.com/doitsujin/dxvk/blob/2b1a284f8453baa2bd193709b67e5183074c74ba/src/dxvk/dxvk_adapter.cpp)
- [DXVK D3D9 feature set at the project pin](https://github.com/doitsujin/dxvk/blob/2b1a284f8453baa2bd193709b67e5183074c74ba/src/d3d9/d3d9_device.cpp)
- [MoltenVK feature query and initialization at v1.4.2](https://github.com/KhronosGroup/MoltenVK/blob/db66022459ffb663aa2b50f6b018bc2e124f5edf/MoltenVK/MoltenVK/GPUObjects/MVKDevice.mm)

The two false robustness feature values do not depend on Metal argument
buffers in that source. Enabling argument buffers or deleting a capability
check cannot supply the missing resource semantics. This project does
neither. `BO1_DXVK_QueryD3D9Baseline` can report the actual phone's feature
values before renderer creation.

There is also a distinct shader issue to validate even after device creation:
D3D9 samplers can produce multiple typed images at one descriptor binding.
An upstream [MoltenVK issue](https://github.com/KhronosGroup/MoltenVK/issues/2768)
reports invalid MSL for this DXVK pattern with and without argument buffers.
A real fix assigns distinct bindings and updates descriptor binding logic;
an environment flag alone is not that fix.

## Candidate routes

### 1. BO1's existing D3D9-to-GLES3 shim: best next bounded experiment

The Android BO1 source already contains a separate D3D9 shim translating
shader-model-3 bytecode through MojoShader into GLSL ES 3.00. Its native host
interface supplies context creation, resize, and presentation. The native
build treats DXVK as optional; the project README offers OpenGL ES 3 as a
slower fallback when Vulkan 1.3 is unavailable.

This gives a concrete next experiment: compile that existing shim and its
shader test/sample against an iOS GLES host or an iOS ANGLE Metal build,
then test the actual BO1 shader corpus and image output. It avoids adding
Vulkan robustness and geometry-shader emulation to stock MoltenVK. It does
not remove the separate engine ABI/toolchain problem.

The shim's limits must remain visible. The reviewed source exposes one
simultaneous render target and no MSAA. Its documentation describes
approximated occlusion results, unsupported state behavior, and skipped
draws after shader translation errors. It contains real CPU DXT decoding
when S3TC is unavailable, but expanded texture memory needs measurement.
Upstream reports WebGL/ANGLE Metal test results; those are not evidence of
an iOS-native game run. GLES would require a matching context/drawable host;
the current CAMetalLayer Vulkan surface cannot simply be passed to EAGL.
ANGLE would add another pinned dependency and its own iOS lifecycle checks.

Reviewed BO1 revision: `e121bab3412988b29534fad26c257adc24329818`:

- [Native rendering options](https://github.com/SevyW/bo1-zombies-android/blob/e121bab3412988b29534fad26c257adc24329818/README.md)
- [Native SDL GLES context](https://github.com/SevyW/bo1-zombies-android/blob/e121bab3412988b29534fad26c257adc24329818/src/native/native_video.cpp)
- [Shim host interface](https://github.com/SevyW/bo1-zombies-android/blob/e121bab3412988b29534fad26c257adc24329818/src/web/d3d9/include/d3d9shim.h)
- [Shim coverage, test claims, and limitations](https://github.com/SevyW/bo1-zombies-android/blob/e121bab3412988b29534fad26c257adc24329818/src/web/d3d9/README.md)
- [Actual capability policy](https://github.com/SevyW/bo1-zombies-android/blob/e121bab3412988b29534fad26c257adc24329818/src/web/d3d9/d3d9_direct3d.cpp)
- [Texture formats and CPU decoding](https://github.com/SevyW/bo1-zombies-android/blob/e121bab3412988b29534fad26c257adc24329818/src/web/d3d9/d3d9_formats.cpp)

### 2. Legacy DXVK with targeted compatibility work

DXVK v1.10.3, commit `e4fd5e9e8d335e8a2c0814829207cbd421f7e40e`, has a
real missing-resource implementation. `DxvkUnboundResources` creates and
clears buffers and typed image views; the descriptor update path substitutes
them when resources are absent. D3D9 copies the driver's robustness2 support
instead of forcing it on. This is substantive fallback code, not a false
capability claim.

However, this older D3D9 feature set still requires geometry shaders and
cull distances. Its legacy Windows build also predates the current native
WSI integration. A downgrade alone therefore does not produce an iOS
renderer. It would require a suitable native legacy base, explicit handling
of the missing internal operations, and the D3D9 sampler fix.

- [Legacy dummy resource allocation and clearing](https://github.com/doitsujin/dxvk/blob/e4fd5e9e8d335e8a2c0814829207cbd421f7e40e/src/dxvk/dxvk_unbound.cpp)
- [Legacy conditional descriptor behavior](https://github.com/doitsujin/dxvk/blob/e4fd5e9e8d335e8a2c0814829207cbd421f7e40e/src/dxvk/dxvk_context.cpp)
- [Legacy D3D9 required features](https://github.com/doitsujin/dxvk/blob/e4fd5e9e8d335e8a2c0814829207cbd421f7e40e/src/d3d9/d3d9_device.cpp)

DXVK-Sarek at `52a1b172518143550f440cf5f095cf6b0ee4419c` retains those
fallbacks and has an actual MoltenVK-specific `d3d9.splitSamplerSlots`
implementation. That is a useful source for a bounded compatibility change.
The project also deliberately makes many otherwise-required extensions
optional and documents degraded rendering. Its successful device creation
must not be substituted for a correctness test, and its broad relaxation
policy should not be imported without checking each required BO1 operation.

- [Sarek rationale and degraded-feature policy](https://github.com/pythonlover02/dxvk-sarek/blob/52a1b172518143550f440cf5f095cf6b0ee4419c/README.md)
- [MoltenVK-only sampler option selection](https://github.com/pythonlover02/dxvk-sarek/blob/52a1b172518143550f440cf5f095cf6b0ee4419c/src/d3d9/d3d9_options.cpp)
- [Sarek descriptor binding implementation](https://github.com/pythonlover02/dxvk-sarek/blob/52a1b172518143550f440cf5f095cf6b0ee4419c/src/d3d9/d3d9_device.cpp)
- [Sarek shader binding implementation](https://github.com/pythonlover02/dxvk-sarek/blob/52a1b172518143550f440cf5f095cf6b0ee4419c/src/dxso/dxso_compiler.cpp)

### 3. macOS forks are research inputs, not verified iOS replacements

Gcenx's published DXVK-macOS release explicitly supports D3D10/11 and removes
the D3D9 DLL from its repack. It is not evidence that our D3D9 path works:
[release notes](https://github.com/Gcenx/DXVK-macOS/releases/tag/v1.10.3-20230507-repack).

The newer metalsharp/DXVK-MacOS, reviewed at
`e847475b8ea97b92bc65385bad0eb88ef1f79ebf`, contains D3D9 sampler and
render-target hazard fixes. It still requires robustness2/null-descriptor
support in the renderer and explicitly depends on its matching customized
MoltenVK. Its advertised packages target macOS/Wine, including ARM64X
Windows DLLs, not iOS static libraries.

The companion custom driver patch at
`2178b9019e771c090188657562834b8a22f3a8b4` includes real shader bounds-check
plumbing and a zero buffer for null vertex bindings. It is more than feature
bit changes. It is also a large driver/compiler patch set with additional
platform assumptions; this review does not establish complete Vulkan
semantics, an iOS 16 build, or iPhone rendering correctness. Adopting it would
mean a separately validated custom-driver port, not replacing one archive.

- [metalsharp renderer requirements and packaging](https://github.com/metalsharp/DXVK-MacOS/blob/e847475b8ea97b92bc65385bad0eb88ef1f79ebf/README.md)
- [Its required feature checks](https://github.com/metalsharp/DXVK-MacOS/blob/e847475b8ea97b92bc65385bad0eb88ef1f79ebf/src/dxvk/dxvk_device_info.cpp)
- [Companion MoltenVK implementation patch](https://github.com/metalsharp/VKD3D-Proton-MacOS/blob/2178b9019e771c090188657562834b8a22f3a8b4/patches/moltenvk/metalsharp-vkmt.diff)

## Decision

Keep the full DXVK compile/link target as a reproducible native integration
check. Use the real capability report on hardware to record the device and
driver state. For the shortest independent rendering experiment, evaluate
the existing BO1 GLES3 shim with a small real shader/draw sample before
committing to either a legacy DXVK port or a custom MoltenVK fork. A sample
must verify textures, depth, alpha, clipping, presentation, and background
resume; a successful factory call is insufficient. No second backend or
unverified feature emulation has been added in this change.
