# Validation — platform project

## GitHub verification — November 17, 2026 (Pacific time)

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

- Linking the complete DXVK renderer and static MoltenVK for iOS.
- A compatible iOS implementation of the BO1 ptr32/low-address memory model.
- The real `BO1IOSCreateHostServices` engine/HUD/input/lifecycle adapter.
- Steam sign-in, ownership/depot selection or downloads through this project.
- A rendered game frame, map loading, audio, touch/controller gameplay,
  aim assist, memory behavior, safe backgrounding or performance on an iPhone.
- A generated, signed or installed IPA.

The on-push verification workflow is active in `Alextechgamer/bo1-ios`.
The latest observed run above verifies the exact code revision recorded there.
