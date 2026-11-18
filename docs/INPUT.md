# Native iOS input milestone

This component supplies a thread-safe input transport, a UIKit touch HUD, a
GameController frontend, and an adapter for the **real native BO1 gamepad
backend**. It does not instantiate `BO1IOSHostServices`, launch an engine, or
turn the existing platform project into a playable game.

## Verified engine boundary

The engine integration is pinned to
[`Zephelinn/BO1-Ascension-ARM64@3401a66355c07d6c590049c2f42b7635c9bf00ac`](https://github.com/Zephelinn/BO1-Ascension-ARM64/tree/3401a66355c07d6c590049c2f42b7635c9bf00ac).
`bo1_engine_input.cpp` includes that checkout's actual
[`src/client/gpad_backend.h`](https://github.com/Zephelinn/BO1-Ascension-ARM64/blob/3401a66355c07d6c590049c2f42b7635c9bf00ac/src/client/gpad_backend.h).
Compile-time assertions check every public virtual-pad bit against that header.
There is no copied `usercmd_s`, guessed byte offset, guest memory access,
`dlsym`, or weak fallback implementation.

This is a deliberate correction to the original handoff. At this revision,
`CL_CreateCmd(usercmd_s *, int)` lives in `src/client_mp/cl_input_mp.cpp`.
The command contains `bitarray<51> button_bits` with MSB-first bit numbering;
it is not a structure with one flat `uint32_t buttons` field. `CL_FinishMove`
also adds camera kick when encoding angles. Writing a guessed command at the
end of that function would bypass native input rules and risk corrupting it.
The definitions are in the pinned
[`msg_mp.h`](https://github.com/Zephelinn/BO1-Ascension-ARM64/blob/3401a66355c07d6c590049c2f42b7635c9bf00ac/src/qcommon/msg_mp.h)
and [`cl_input_mp.cpp`](https://github.com/Zephelinn/BO1-Ascension-ARM64/blob/3401a66355c07d6c590049c2f42b7635c9bf00ac/src/client_mp/cl_input_mp.cpp).

Instead, the adapter implements `GPad_Backend_MaxPorts`, `GPad_Backend_Poll`,
and `GPad_Backend_SetRumble`. The existing engine `gpad_core.cpp` and
`cl_gamepad.cpp` retain ownership of bindings, button transitions, menu repeat,
dead zones, ADS state, stance behavior, sprint restrictions, and native
gamepad aim assist. The port has one local-player input port, matching this
upstream backend's usage.

Touch swipe distances pass through the upstream `bo1_native_input_motion`
queue and then the real `IN_MouseMove` / `CL_MouseMove` path. The adapter keeps
fractional pixels between engine frames, so a slow drag is not rounded away.
Motion is expressed in a 1280 by 720 reference image; the engine retains its
normal sensitivity and view constraints. This milestone does not add a new
entity scanner or make the unverified handoff's aim-assist claims.

## Source responsibilities

| Files | Responsibility |
| --- | --- |
| `ios/include/ios_input_bridge.h` | C ABI shared by UIKit producers and the engine consumer |
| `ios/input/InputState.*`, `ios_input_bridge.cpp` | Mutex-protected state, source ownership, edges, motion, reset generations |
| `ios/input/BO1TouchHUD.*` | Touch controls, menu pointer, layout editing and persistence |
| `ios/input/BO1InputFrontend.*` | Main-thread touch publication, controller discovery/callbacks, lifecycle neutral gate |
| `ios/input/PadPulseState.h` | Sampled-pad release/repress sequencing for rapid taps |
| `ios/input/bo1_engine_input.*` | Native gamepad backend and once-per-engine-frame input pump |
| `ios/input/engine-input.patch` | Exact pinned engine changes for pump ordering and stale event rejection |
| `tests/test_input_state.cpp` | Portable state, arbitration, reset, pointer and concurrency tests |
| `tests/test_input_engine.cpp` | Adapter tests compiled against the actual pinned gamepad header |

## Transport and ownership rules

The transport starts suspended. Producers submit a complete held-state frame
with a source identifier, current source epoch, and strictly increasing
nonzero sequence number. Duplicate, older, or invalidated frames are rejected.
Each source has its own sequence space. A reset increments its epoch so a
callback captured before suspension cannot restore old controls afterward.

Buttons are held state with consume-once rising and falling edges. Relative
look is accumulated and consumed exactly once. Triggers expose both current
held pressure and the peak since the last consume, preserving a short pull.
Nonfinite values are rejected as zero; axes and pressures are bounded. Motion
is bounded to 4096 reference pixels per publication and 16384 per accumulated
sample. No allocations occur inside the transport after initialization.

Button ownership is merged across touch and controller. Releasing or
disconnecting one device does not release a button still held by the other.
Intentional controller stick movement (magnitude greater than 0.2) takes
priority over touch on the corresponding movement/look channel. A neutral
controller or small drift permits touch. Suppressed touch look is discarded
immediately, so it cannot jump the camera when the stick returns to center.
Normal gamepad dead zones remain in the engine.
Before consumption, the native adapter publishes the current engine
`gpad_button_deadzone` value to the transport. Trigger edges and pulse
sequencing use that same value. This preserves a quick pull such as
0.02 → 1.0 → 0.02 from a controller with a nonzero resting value, without
inventing a separate gameplay dead zone. The exact dvar and analog edge
behavior are in
[`gpad_core.cpp`](https://github.com/Zephelinn/BO1-Ascension-ARM64/blob/3401a66355c07d6c590049c2f42b7635c9bf00ac/src/client/gpad_core.cpp).

The native backend is sampled. `PadPulseState` inserts a release frame before
a second quick press, so two taps arriving on successive engine frames become
two rising edges. It can retain up to eight sample-level presses per control.
Multiple press/release cycles for the **same** control entirely between two
consumes coalesce to one sample-level edge. This is a bounded state transport,
not an unbounded recording of every touch event. Repeated gamepad polls within
one engine frame return the same cached state and do not consume another tap
or move the view again.

There must be exactly one engine-side consumer. UIKit is never that consumer
in a real engine app. The separate diagnostics app may consume samples while
no engine is linked.

## Touch HUD

The transparent HUD fills the Metal view. Left-side movement is a floating
stick; the right side accepts relative look swipes. Fire, ADS, and the primary
right-side action buttons can be held while dragging to aim. Independent
touches may hold the same button without one finger's release clearing the
other finger's hold.

`Edit controls` enters a layout mode in which gameplay touch commands are
neutral. Drag a control and tap `Done` to persist its normalized position in
the supplied `NSUserDefaults` store. `Reset layout` restores defaults.
Positions are clamped into the safe area, controls are at least 44 points,
and the HUD uses no separate timer or display link.

The default controls map to the pinned engine's own standard gamepad binds:

| Touch label / physical control | Backend element | Default BO1 behavior |
| --- | --- | --- |
| Fire / right trigger | `rt` | Attack |
| ADS / left trigger | `lt` | Held ADS |
| Jump / A | `GPAD_RAW_A` | Jump / stand |
| Crouch / B | `GPAD_RAW_B` | Stance; hold for prone |
| Reload / X | `GPAD_RAW_X` | Reload / use through the native combined bind |
| Swap / Y | `GPAD_RAW_Y` | Next weapon |
| Sprint / left-stick press | `GPAD_RAW_LEFT_THUMB` | Sprint / hold breath |
| Melee / right-stick press | `GPAD_RAW_RIGHT_THUMB` | Melee |
| Frag / right shoulder | `GPAD_RAW_RIGHT_SHOULDER` | Lethal equipment |
| Tactical / left shoulder | `GPAD_RAW_LEFT_SHOULDER` | Tactical equipment |
| Menu / Menu | `GPAD_RAW_START` | Toggle menu |
| Scores / Options when present | `GPAD_RAW_BACK` | Scores |
| Direction pad | Four raw D-pad bits | Action slots in gameplay; native menu navigation |

Menus need two distinct paths. Ordinary pointer menus receive normalized
pointer coordinates, followed by a click after two hover frames and a later
release. This follows the pinned native SDL implementation, which explains
that immediate clicks only changed the highlight. D-pad, `SELECT` (A), and
`BACK` (B) remain visible in menus. The 3D front-end TV menus capture the mouse;
there the right side supplies relative look while the visible native buttons
drive selection. `IOS_SetInputContext` communicates both menu and capture
ownership without exposing engine memory to UIKit. Context transitions cancel
ongoing touch gestures and pending clicks.
The upstream behavior is documented in
[`native_video.cpp`](https://github.com/Zephelinn/BO1-Ascension-ARM64/blob/3401a66355c07d6c590049c2f42b7635c9bf00ac/src/native/native_video.cpp)
and implemented through
[`web_input.cpp`](https://github.com/Zephelinn/BO1-Ascension-ARM64/blob/3401a66355c07d6c590049c2f42b7635c9bf00ac/src/web/web_input.cpp).

## Controller frontend and host integration

`BO1InputFrontend` owns one `GCExtendedGamepad` input callback and selects the
first connected controller that supports that profile. Connection and input
callbacks use the main queue. It publishes on input changes and from the
host display link; event publication preserves short presses between display
ticks. No additional frame-rate multiplier is applied to held sticks or touch
distances. Apple documents these profile elements and callback behavior in
[GCExtendedGamepad](https://developer.apple.com/documentation/gamecontroller/gcextendedgamepad)
and [handlerQueue](https://developer.apple.com/documentation/gamecontroller/gcdevice/handlerqueue).

The required real `BO1IOSHostServices` adapter can retain one frontend and
delegate its existing interface as follows:

| Host service / lifecycle step | Frontend operation |
| --- | --- |
| Create HUD | Initialize `BO1InputFrontend` with the host view frame and preferences; return `touchHUD` |
| `submitInputAtTimestamp:duration:` | Forward the same timestamp and duration to the frontend |
| `resetInput` | Call the frontend's `resetInput` |
| Suspend | Call `setSuspended:YES` before stopping and draining the actual engine/render workers |
| Resume succeeds | Call `setSuspended:NO` after the real engine resume/preparation succeeds |
| Resume fails | Keep input suspended; the existing host failure path still drains prepared engine resources |

The frontend requires all held physical controller controls to return to
neutral after reset, controller replacement, or suspension. This prevents a
trigger held through an interruption from immediately firing on return.
Touch contacts are cleared and must begin again. A zero rumble request is
published on reset. An optional main-thread `controllerRumbleHandler` can
connect those requests to hardware haptics; this milestone supplies the
request transport and does not claim hardware vibration support without that
handler. Input suspension does not wait for the GPU or replace the renderer's
real stop/drain acknowledgment.

## Required engine/build integration

1. Use the pinned native engine checkout and run
   `python3 ios/input/apply_engine_input.py /path/to/BO1-Ascension-ARM64`.
   The script verifies HEAD, checks the patch before mutation, and accepts an
   already-applied patch. It refuses a different revision or conflicting edit.
2. Compile `InputState.cpp` and `ios_input_bridge.cpp` once. Compile the two
   UIKit `.mm` files with ARC and link Foundation, UIKit, QuartzCore, and
   GameController. Xcode targets need `CLANG_ENABLE_OBJC_ARC=YES`, in addition
   to the portable `.mm` source option.
3. Compile `bo1_engine_input.cpp` against the **actual** pinned engine `src`
   include directory, together with `ios/include` and `ios/input`. It has
   strong references to native queue exports. A missing real engine is a
   link error, not a successful fallback.
4. Select this backend instead of upstream native/web/Windows gamepad backend
   implementations. Keep the real `gpad_core.cpp`, `cl_gamepad.cpp`, and
   BO1-native input queue. Do not link duplicate `GPad_Backend_*` definitions.
5. **Exclude the SDL input producer in `native_video.cpp`.** Its renderer/pump
   path can also submit input; selecting a different gamepad backend alone is
   insufficient. The queue is single-producer. The patch disables its call
   from `bo1_web_input_pump` on iOS; the eventual native iOS engine source set
   must also replace the Android/SDL video host and any other path that calls
   that producer. UIKit only writes the portable bridge.
6. With `PLATFORM_IOS=1`, the pinned patch calls `IOS_BO1_PumpInput()` once at
   the top of `IN_Frame`, before both `IN_MouseMove` and `IN_GamepadsMove`.
   It tags native queue events and motion with the consumed lifecycle reset
   generation. The existing serialized native consumer discards events from
   older generations; stale mouse accumulators are cleared/ignored. This
   covers pause/resume even when no engine frame saw the paused state.
   In-flight engine work still needs the host's real suspend safe point.

The platform build can compile these into independent static archives while
the engine port gate remains closed. The engine adapter is not linked into
the diagnostics app. Its test executable supplies explicit test-only captures
of the native queue exports; these fixtures are never production sources.

## Verification

The portable tests exercise held and edge buttons, quick trigger pulls,
consume-once motion, source arbitration, shared-button disconnects, stale
epochs, reset/suspend/resume, pointer ownership, invalid values, rumble
transport, the controller neutral policy, and concurrent producers/consumer.
The adapter tests include repeated native polls, successive rapid taps,
fractional motion, menu click timing, captured-menu input, and a pause/resume
that happens entirely between engine polls. They compile the actual pinned
gamepad header, rather than a test copy of its ABI.

On a host with a C++20 compiler, the independent commands are:

```sh
c++ -std=c++20 -pthread -Wall -Wextra -Werror \
  -Iios/include -Iios/input \
  ios/input/InputState.cpp tests/test_input_state.cpp \
  -o /tmp/bo1-input-state
/tmp/bo1-input-state

c++ -std=c++20 -pthread -Wall -Wextra -Werror \
  -Iios/include -Iios/input -I/path/to/BO1-Ascension-ARM64/src \
  ios/input/InputState.cpp ios/input/ios_input_bridge.cpp \
  ios/input/bo1_engine_input.cpp tests/test_input_engine.cpp \
  -o /tmp/bo1-input-engine
/tmp/bo1-input-engine
```

These tests and Apple SDK compilation validate input components and their
boundary contracts. They do not establish that T5 gameplay, its address model,
native renderer, or the complete engine lifecycle works on an iPhone.
