# BO1 Port Diagnostics

This is a separately named, installable **platform diagnostic**. The game
engine is unavailable; the app does not launch BO1, load game assets, or
claim that an engine ABI or renderer works. Its bundle identifier is
`com.alextechgamer.bo1ios.diagnostics` and its output is
`BO1PortDiagnostics.app`.

## On-device checks

**Report** shows the execution environment and check results. Tap **Run
checks** to create a real Vulkan instance through the linked MoltenVK,
create a real surface from the registered `CAMetalLayer`, query each
physical device's DXVK D3D9 requirements and surface support, then destroy
the surface and instance. The check creates no logical device, swapchain,
command buffer, or GPU submission. The same run captures
`BO1ProbeAddressModel` from the actual installed process, including its
ordinary and 64 MiB pthread addresses and safe allocation observations.
The report identifies physical-device, simulator, and host evidence
explicitly; a host build result does not establish phone behavior.

**Control test** mounts the real `BO1InputFrontend`/TouchHUD and consumes
its thread-safe input samples as the only consumer. It shows controller
name, sources, axes, triggers, relative touch motion, and held/pressed/
released button masks. Its single display link requests up to 120 Hz,
bounded by the current screen. Reported cadence is display-link cadence,
not game FPS. The HUD's edit/reset controls use a diagnostics-specific
preferences suite. Input resets when leaving this mode or deactivating.

**Test audio** is optional and never starts automatically. It sends a
generated, low-level 440 Hz PCM tone lasting 0.35 seconds through the
actual native mixer/SDL audio output. The PCM allocation remains alive
until the mixer is stopped. The report distinguishes output opening,
buffer completion, timeout, and interruption. Buffer completion does not
prove that the user heard it, and the tone does not exercise xWMA decoding.
Deactivation, route disconnection, interruption, or leaving the view stops
the tone; it does not resume automatically.

**Share report** opens `UIActivityViewController` only after a tap. There
is no automatic upload, message, or clipboard write. The report contains
device/OS information, non-unique controller name, process addresses, and
observed capability/input/audio results; no game files are required.

The app uses a landscape UI on iPhone/iPad. It has no background execution
mode, extra memory entitlement, game services factory, or engine adapter.
Vulkan checks run serially off the UI thread. The registered layer remains
alive until their cleanup finishes; UIKit and input callbacks stay on the
main thread. Deactivation cancels subsequent check phases and resets input.

## Build contract

Enable the root diagnostics option after the real `bo1_ios_host`,
`bo1_dxvk_d3d9`, `bo1_native_audio`, and `bo1_input_frontend` targets are
configured. `cmake/ios_diagnostics.cmake` adds `bo1_port_diagnostics`:

```sh
cmake --build build-ios-native --config Release --target bo1_port_diagnostics
```

The Xcode output is
`build-ios-native/Release-iphoneos/BO1PortDiagnostics.app`. The root
packaging workflow creates the separately named unsigned diagnostics IPA
for signing/sideloading. Do not force-load `bo1_ios_host` with `-all_load`
or `-ObjC`: this app uses its C bridge and has its own app delegate. There
is deliberately no substitute for the unfinished engine host factory.

SDK compilation, real-device installation, and on-device UI/audio checks
are separate verification steps. This source alone is not evidence of a
successful phone run.
