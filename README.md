# BO1 iOS

Native ARM64 iOS port work for Black Ops, targeting iOS 16 or later. Intended game scope is Zombies, offline Combat Training, and eventually campaign.

**The game is not playable yet.** This repository contains real platform, input, graphics and audio integration work, plus a separately named **BO1 Port Diagnostics** app for collecting iPhone evidence. A diagnostics IPA is not a Black Ops game build. No commercial game files or Steam credentials are bundled.

## What is implemented

| Component | Implementation and boundary |
| --- | --- |
| UIKit game host | CAMetalLayer, physical pixel sizing, adaptive display link up to 120 Hz, Files startup gate, checked 64 MiB pthread launch and explicit lifecycle contracts. The real engine adapter remains required. |
| Touch and controllers | New draggable HUD with saved positions, native GameController input, thread-safe held/edge state and consume-once look deltas. Uses the actual BO1 gamepad and native input interfaces, without BO2 guest-memory offsets. |
| Native input adapter | Exact-header implementation of GPad_Backend, plus a checked IN_Frame hook. Native engine queue symbols are deliberately unresolved until the real engine is linked. |
| DXVK | Complete pinned v2.6.1 D3D9 static build, 60 generated shaders, Metal WSI, Apple portability fixes, isolated factory exports and a whole-archive link probe against static MoltenVK. Runtime feature compatibility is blocked below. |
| Audio | Pinned CoreAudio SDL2 and minimal FFmpeg builds; compilation of the actual native BO1 software mixer and a real device link probe. |
| Diagnostics app | Separate entrypoint for checking real Vulkan capabilities and Metal surface creation, memory addresses, touch/controller input and an explicit PCM audio test. It invokes no engine and needs no game files. |
| Engine ABI experiments | Actual Apple compiler layout/codegen checks, ordinary iOS Mach-O/PIE/PAGEZERO checks, image-arena experiments and a device address diagnostic. |
| CI | Host behavior tests, Apple SDK compilation, complete native-library linkage, diagnostics packaging, and a separate strict engine-ABI experiment workflow. |

Exact tested revisions, results and limits are in [Validation](docs/VALIDATION.md). Requested 120 Hz callbacks do not establish game frame rate or device performance.

## Confirmed blockers

**The engine pointer model needs a real port.** The Android native build stores four-byte absolute pointers to objects below 4 GiB. Apple's ordinary ARM64 loader protects that address range. The tested Xcode 16.4 compiler also gives the engine's `__ptr32` declarations eight-byte storage, failing the necessary layout assertions. A larger pthread stack does not change either condition. See [the ABI evidence and replacement-design requirements](docs/ENGINE_ABI.md).

**Stock DXVK and MoltenVK do not form a working D3D9 runtime here.** The pinned DXVK requires `robustBufferAccess2`, `nullDescriptor`, `geometryShader` and `shaderCullDistance`; pinned MoltenVK 1.4.2 does not expose them. The build and capability query preserve those requirements. BO1's existing GLES3 shim is a concrete alternative to evaluate, with documented limitations. See [renderer options](graphics/RENDERER_OPTIONS.md).

The original handoff is a design specification; its claims of completed engine/input/downloader/IPA integration were not treated as verified source.

## Diagnostics on an iPhone

The `Verify iOS platform source` workflow uploads `BO1-Port-Diagnostics-Unsigned` after the real app links and packaging checks succeed. Download the artifact from the [Actions page](https://github.com/Alextechgamer/bo1-ios/actions), unzip it, and sign/install the contained `.ipa` with your sideloading setup. The bundle has no distribution signature or provisioning profile.

The IPA includes the pinned dependencies' notices and build provenance. The same run retains native objects, static libraries and link metadata in `BO1-Diagnostics-Link-Inputs`; these are build inputs, not a separately verified relinking tool.

Use **Run checks** to collect memory and Vulkan evidence, **Control test** to test the HUD/controller, and **Test audio** for the generated test tone. **Share report** exports results only when tapped. Installation and execution on an actual iPhone are separate from CI's successful app build.

This app uses its own entrypoint. It does not supply a fake `BO1IOSCreateHostServices` implementation or pretend to launch `Sys_Main`. The actual upstream engine enters its file-local `EngineMain`; that boundary still needs the compatible engine address model and synchronized lifecycle.

## Build and verify

The GitHub workflows run the Apple SDK builds without requiring a local Mac. For portable tests with Python 3 and a C++20 compiler:

```sh
python3 scripts/run_host_tests.py
python3 engine/probes/test_probe_engine_abi.py
python3 scripts/probe_engine_abi.py --output-dir build/engine-abi
```

The last command explicitly skips Apple-only stages on Linux. To test the real native input header as well, pass `--engine-source /path/to/bo1-ascension` to `scripts/run_host_tests.py`.

For the complete build on a Mac with Xcode, CMake, Ninja and host glslang:

```sh
git init vendor/bo1-engine
git -C vendor/bo1-engine remote add origin https://github.com/Zephelinn/BO1-Ascension-ARM64.git
git -C vendor/bo1-engine fetch --depth 1 origin 3401a66355c07d6c590049c2f42b7635c9bf00ac
git -C vendor/bo1-engine checkout --detach FETCH_HEAD
git clone --branch v2.6.1 --depth 1 --recurse-submodules --shallow-submodules https://github.com/doitsujin/dxvk.git vendor/dxvk
python3 patches/dxvk/apply.py vendor/dxvk
bash scripts/build_ios_deps.sh
cmake -S . -B build-ios-native -G Xcode -DCMAKE_TOOLCHAIN_FILE=cmake/ios.cmake -DBUILD_TESTING=OFF -DBO1_BUILD_IOS_PLATFORM=ON -DBO1_BUILD_IOS_DXVK=ON -DBO1_BUILD_IOS_AUDIO=ON -DBO1_BUILD_DIAGNOSTICS=ON -DBO1_ENGINE_SOURCE_DIR="$PWD/vendor/bo1-engine" -DBO1_DXVK_SOURCE_DIR="$PWD/vendor/dxvk"
cmake --build build-ios-native --config Release -- CODE_SIGNING_ALLOWED=NO
python3 scripts/package_diagnostics.py --app build-ios-native/Release-iphoneos/BO1PortDiagnostics.app
```

The separate [engine-ABI workflow](.github/workflows/probe-engine-abi.yml) retains failures and uploads its evidence even when the compiler is incompatible. Its red result must not be hidden by removing the layout assertions. Every ABI report states `engine_ready=false` until a replacement engine implementation is actually validated.

## Integration documents

- [Engine port gates](docs/ENGINE_PORT_GATES.md): entrypoint, rendering/audio lifecycle, asset delivery and gameplay work still required.
- [Native input](docs/INPUT.md): frame ownership, bindings, menus, suspension, patch application and engine source selection.
- [Dependencies](docs/DEPENDENCIES.md): exact pins, enabled audio formats, checksums, compiler receipts and static library builds.
- [Graphics](graphics/README.md): full D3D9 build, WSI, static exports and the real driver capability query.
- [Source provenance](THIRD_PARTY_NOTICES.md): dependency and source notices.

Steam sign-in, entitlement/depot selection and downloads have not been wired into this project. The eventual game host's Files gate checks only the presence of a readable nonempty startup archive; it is not a complete installation check. The upstream feature table lists campaign as unavailable, so campaign remains separate engine work after the iOS foundation is solved.
