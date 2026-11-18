# Validation — platform, native libraries, and diagnostics

## Diagnostics app build — November 17, 2026 (Pacific time)

Code revision: `9e54ea9fedda8592df80c0f4601e62c12d5cef62`.
[Successful workflow run](https://github.com/Alextechgamer/bo1-ios/actions/runs/44246156402).

| Job / artifact | Observed result |
| --- | --- |
| `host-tests` | PASS: 14 platform, 49 portable input and 60 actual-header native adapter checks with sanitizers, plus the real DXVK WSI harness |
| `apple-sdk-compile` | PASS: UIKit host, touch/controller frontend, Metal bridge and patched DXVK platform sources compiled for device ARM64 |
| `apple-native-link` | PASS: actual SDL/FFmpeg/native mixer and complete DXVK/MoltenVK link probes, plus the independent diagnostics app |
| Diagnostics package | Unsigned IPA produced and downloaded; checksum, executable permission, bundle identifier, plist, Mach-O load commands and all 12 bundled notice/provenance files verified |
| Retained link inputs | Downloaded and checked: 160 object files, 13 static archives, 14 link-file lists, dependency headers and generated Xcode project; all four diagnostics objects and required libraries are present |

The executable is ARM64 iPhoneOS with a 16.0 minimum OS, built against SDK
18.5. Its load commands preserve PIE and the protected first 4 GiB. `otool -L`
lists Apple system libraries/frameworks only; SDL, FFmpeg and MoltenVK do not
require separately installed dynamic libraries. The bundle ID is
`com.alextechgamer.bo1ios.diagnostics` and its displayed name is
`BO1 Port Diagnostics`.

The [diagnostics artifact](https://github.com/Alextechgamer/bo1-ios/actions/runs/44246156402/artifacts/14401573282)
contains the IPA and its JSON manifest. The IPA is **1,884,421 bytes** with SHA256:

```text
d956e639e0b4d3a32bb7bfd2ff714f5d1619ba8100205e84e0efa2d3f2736af8
```

The executable embeds the tested source revision. Its SHA256, each notice
hash, source pins and recipe hashes match the manifest/provenance. The
[native build evidence](https://github.com/Alextechgamer/bo1-ios/actions/runs/44246156402/artifacts/14401867477)
and [retained link inputs](https://github.com/Alextechgamer/bo1-ios/actions/runs/44246156402/artifacts/14401702970)
are separate artifacts. Retaining link inputs does not establish that a
modified binary has been successfully relinked or run on a phone.

No iPhone installation or execution has been observed. The app contains no engine;
its successful link does not resolve the failed engine ABI or missing Vulkan
features. Its explicit PCM tone does not test xWMA decoding.

## Native library link milestone — November 17, 2026 (Pacific time)

Code revision: `f226d374c853512878b89911edc653581a6c03f2`.
[Workflow run](https://github.com/Alextechgamer/bo1-ios/actions/runs/44243665503).
The host and Apple platform jobs passed. The native job printed
`BUILD SUCCEEDED` after linking the real audio probe and the complete
DXVK/MoltenVK renderer probe. Its subsequent evidence-recording step failed
because it looked for the audio executable outside the Xcode-created `.app`
wrapper. The workflow now uses the observed bundle path.

This establishes a complete native-library link, not a rendered frame or an
on-device run. The SDL2/CoreAudio and selected FFmpeg libraries were compiled
from pinned sources. The DXVK probe force-loads the complete D3D9 archive,
including generated shader code, and resolves it against static MoltenVK
without allowing unresolved symbols. Earlier CI failures found and corrected
`lipo` argument order, Xcode C-source definitions, and an Apple `size_t`
overload ambiguity; the actual successful link covers those corrections.

The later [ABI experiment run](https://github.com/Alextechgamer/bo1-ios/actions/runs/44245260295)
at `3f3fa3ed551c2740dbec480f68a09cb947062cae` failed only its four-byte
pointer-layout assertions under Apple Clang 17/Xcode 16.4. The other eight
stages passed, including isolated narrow stores, ordinary PIE/PAGEZERO and
image-arena links, and the corrected public-VM address diagnostic object.
That object is compiled for iPhoneOS; it has not run on an iPhone. Full
results and distinctions are in
[ENGINE_ABI.md](ENGINE_ABI.md).

## Native input and diagnostics source checks

The expanded host suite passes 14 platform checks, 49 portable input checks,
and 60 native-adapter checks against the actual pinned upstream gamepad
header. AddressSanitizer and UndefinedBehaviorSanitizer pass; only leak
detection is disabled locally because the executor runs under ptrace.
CMake generation, build and CTest pass all three registered suites. The ABI
evidence parser's 12 checks pass. The pinned native input patch applies
cleanly and recognizes an already-applied patch.

Input review covered rapid repeated taps, menu pointer timing and native
button navigation, nonzero trigger-rest values, stale-event generations,
controller replacement, and pause/resume occurring between engine polls.
The diagnostics frontend consumes input only when no engine consumer is
linked. These tests do not run UIKit or T5 gameplay on a phone.

The separately named `BO1 Port Diagnostics` target and packaging workflow
are supplied for actual device evidence. The successful Apple app build and
artifact inspection are recorded above; device execution remains separate.

## Initial platform verification — November 17, 2026 (Pacific time)

Code revision: `fc8db4d5cc566d0a2ff786338fe3887d161458a7`.
[Successful workflow run](https://github.com/Alextechgamer/bo1-ios/actions/runs/44236856910).

| Job | Result | Evidence and scope |
| --- | --- | --- |
| `host-tests` | PASS | 14 production-code platform checks with AddressSanitizer/UndefinedBehaviorSanitizer, followed by the real DXVK WSI/dispatcher/loader harness |
| `apple-sdk-compile` | PASS | UIKit host, app entrypoint, Metal bridge, DXVK Metal provider, dispatcher and static-loader sources compiled for device ARM64; platform archives created |

The Apple job used the `macos-15` runner, Xcode 16.4, AppleClang
17.0.0.17000013 and the iPhoneOS 18.5 SDK, with an iOS 16.0 deployment target.
No code compilation warnings were reported. The dependency clone emitted an
annotated-tag warning, then checked out the exact revision and passed its pin
verification.

The initial run at `847b3338e67d04dc063c023983e11685e20b1076` caught missing
ARC on the mixed C++/Objective-C++ Xcode target. The fix sets ARC explicitly
on the `.mm` sources and enables Xcode's ARC target setting. The bridge's
compile-time ARC requirement remains enabled. The successful rerun covers
that fix.

This verifies compilation of static platform libraries and the entrypoint.
It does not resolve the required engine factory, link a full application,
link the complete DXVK/MoltenVK renderer, or produce an IPA.

## Earlier local checks

Executed on the Linux x86-64 workspace on November 16, 2026 (Pacific time).
These results cover the source in this package, not a compiled iPhone game.

| Check | Result | What this establishes |
| --- | --- | --- |
| `scripts/run_host_tests.py` | PASS, 14 checks | Startup archive presence rules and published display-state behavior using the production portable code |
| AddressSanitizer + UndefinedBehaviorSanitizer | PASS, same 14 checks | No detected address/undefined-behavior error in this host suite; leak detection disabled because this executor runs under ptrace |
| Coherent size publication | PASS within host suite | 200,000 concurrent size updates did not expose a mixed width/height pair |
| `graphics/tests/run_wsi_tests.py` | PASS | Actual pinned DXVK driver interface, dispatcher and patched loader compile and satisfy the behavioral harness |
| DXVK patch applicability/reapplication | PASS | Applies to the pinned upstream revision and safely recognizes an already-applied patch |
| CMake configure, build and CTest on Linux | PASS, 1/1 test target | Portable project generation, compilation and test registration work with CMake 3.31.6 / GCC 14.2 |
| Python syntax | PASS | All three project Python tools compile |
| Info.plist parsing | PASS | Valid plist; iOS 16, Files sharing, in-place opening and ProMotion keys checked |
| Independent source review | Completed, fixes applied | Partial-start/resume cleanup, downloader cancellation ownership, and surface failure-output handling corrected |

The WSI harness uses the real DXVK v2.6.1 WSI header, dispatch implementation,
and patched Vulkan loader. It substitutes deterministic platform state and
Vulkan entry points. It verifies registration, reference counting, advertised
extensions, window/monitor validation, dimension changes, pause/empty-window
visibility, mode behavior, surface errors and loader identity. It does not
exercise a real Vulkan driver or a UIKit view.

## Not yet demonstrated

- A compatible iOS implementation of the BO1 ptr32/low-address memory model.
- The real `BO1IOSCreateHostServices` engine/HUD/input/lifecycle adapter.
- Steam sign-in, ownership/depot selection or downloads through this project.
- A rendered game frame, map loading, audio, touch/controller gameplay,
  aim assist, memory behavior, safe backgrounding or performance on an iPhone.
- Successful signing/installation or execution of the diagnostics IPA on an iPhone.

The on-push verification workflow is active in `Alextechgamer/bo1-ios`.
Each observed run above verifies the exact code revision recorded with it.
