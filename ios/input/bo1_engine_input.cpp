#include "bo1_engine_input.h"
#include "ios_input_bridge.h"
#include "PadPulseState.h"
#include <client/gpad_backend.h>
#include <cmath>

// Exact exported BO1_NATIVE input functions at Ascension revision
// 3401a66355c07d6c590049c2f42b7635c9bf00ac, src/web/web_input.cpp.
extern "C" void bo1_native_input_motion(int, int, int, int, int, int);
extern "C" void bo1_native_input_buttons(int);
extern "C" void bo1_native_input_focus(int);
extern "C" int bo1_native_ui_active(void);
extern "C" int bo1_native_input_wants_grab(void);
extern "C" void bo1_native_input_set_grabbed(int);
extern "C" void bo1_native_input_clear_motion(void); // Added by the pinned iOS input patch.
extern "C" float bo1_native_input_trigger_deadzone(void); // Reads the actual engine dvar.

static_assert(IOS_PAD_JUMP == GPAD_RAW_A && IOS_PAD_STANCE == GPAD_RAW_B);
static_assert(IOS_PAD_USE_RELOAD == GPAD_RAW_X && IOS_PAD_SWAP == GPAD_RAW_Y);
static_assert(IOS_PAD_MENU == GPAD_RAW_START && IOS_PAD_SCORES == GPAD_RAW_BACK);
static_assert(IOS_PAD_SPRINT == GPAD_RAW_LEFT_THUMB && IOS_PAD_MELEE == GPAD_RAW_RIGHT_THUMB);
static_assert(IOS_PAD_TACTICAL == GPAD_RAW_LEFT_SHOULDER && IOS_PAD_LETHAL == GPAD_RAW_RIGHT_SHOULDER);
static_assert(IOS_PAD_UP == GPAD_RAW_DPAD_UP && IOS_PAD_DOWN == GPAD_RAW_DPAD_DOWN);
static_assert(IOS_PAD_LEFT == GPAD_RAW_DPAD_LEFT && IOS_PAD_RIGHT == GPAD_RAW_DPAD_RIGHT);

namespace {
GPadRawState cachedPad{};
double remainderX = 0, remainderY = 0;
uint64_t touchEpoch = 0, controllerEpoch = 0, producerEpoch = 0;
bool mouseDown = false, focusKnown = false, focused = false;
unsigned tapDown = 0, tapUp = 0;
bo1ios::PadPulseState pulses;
float previousTriggerThreshold = -1;

int takePixels(double &remainder, float delta) {
    remainder += delta;
    const int pixels = (int)std::trunc(remainder);
    remainder -= pixels;
    return pixels;
}
}

extern "C" uint64_t IOS_BO1_InputEpoch(void) { return producerEpoch; }

extern "C" void IOS_BO1_PumpInput(void) {
    const bool menu = bo1_native_ui_active() != 0;
    const bool grabbed = bo1_native_input_wants_grab() != 0;
    const bool pointerMenu = menu && !grabbed;
    IOS_SetInputContext(menu, grabbed);
    const float threshold = bo1_native_input_trigger_deadzone();
    const float triggerThreshold = std::isfinite(threshold) ? std::clamp(threshold, 0.0f, 1.0f) : 1.0f;
    IOS_SetInputTriggerThreshold(triggerThreshold);
    if (triggerThreshold != previousTriggerThreshold) {
        pulses.reset();
        previousTriggerThreshold = triggerThreshold;
    }
    IOSInputSample sample{};
    IOS_ConsumeInput(&sample);
    const bool lifecycleReset = producerEpoch != sample.resetEpoch;
    producerEpoch = sample.resetEpoch;
    if (sample.touchEpoch != touchEpoch) {
        remainderX = remainderY = 0;
        tapDown = tapUp = 0;
        bo1_native_input_clear_motion();
        if (mouseDown) bo1_native_input_buttons(0);
        mouseDown = false;
        pulses.reset();
        touchEpoch = sample.touchEpoch;
    }
    if (controllerEpoch != sample.controllerEpoch) {
        pulses.reset();
        controllerEpoch = sample.controllerEpoch;
    }
    // UIKit may suspend and resume while IN_Frame is stopped. The generation
    // records that reset even if no consumer observed suspended == true.
    if (lifecycleReset && focusKnown) {
        bo1_native_input_focus(0);
        focused = false;
    }
    const bool nextFocused = !sample.suspended;
    if (!focusKnown || nextFocused != focused) {
        bo1_native_input_focus(nextFocused ? 1 : 0);
        focusKnown = true;
        focused = nextFocused;
        if (!focused) mouseDown = false;
    }
    cachedPad = {};
    if (sample.suspended) {
        remainderX = remainderY = 0;
        pulses.reset();
        return;
    }
    bo1_native_input_set_grabbed(grabbed ? 1 : 0);
    const auto sequenced = pulses.advance(sample, triggerThreshold);
    cachedPad.connected = sample.connected;
    cachedPad.buttons = sequenced.buttons;
    cachedPad.lt = sequenced.leftTrigger;
    cachedPad.rt = sequenced.rightTrigger;
    cachedPad.lx = sample.moveX;
    cachedPad.ly = sample.moveY;
    cachedPad.rx = sample.lookX;
    cachedPad.ry = sample.lookY;

    const int dx = pointerMenu ? 0 : takePixels(remainderX, sample.deltaX);
    const int dy = pointerMenu ? 0 : takePixels(remainderY, sample.deltaY);
    if (dx || dy || (pointerMenu && sample.pointerValid)) {
        const int x = pointerMenu && sample.pointerValid ? (int)std::lround(sample.pointerX * 1280) : (menu ? -64 : 640);
        const int y = pointerMenu && sample.pointerValid ? (int)std::lround(sample.pointerY * 720) : (menu ? -64 : 360);
        bo1_native_input_motion(dx, dy, x, y, 1280, 720);
    }
    // Native BO1 menus need time to move their highlight before a touch click.
    // Match the pinned SDL path's two hover frames and separate press/release.
    if (!pointerMenu || !sample.pointerValid) {
        tapDown = tapUp = 0;
        if (mouseDown) bo1_native_input_buttons(0);
        mouseDown = false;
    } else {
        if (tapDown && --tapDown == 0) { bo1_native_input_buttons(1); mouseDown = true; }
        if (tapUp && --tapUp == 0) { bo1_native_input_buttons(0); mouseDown = false; }
        if (sample.pointerPressed) {
            if (mouseDown) { bo1_native_input_buttons(0); mouseDown = false; }
            tapDown = 2;
            tapUp = 0;
        }
        if (sample.pointerReleased) tapUp = tapDown ? tapDown + 2 : 1;
    }
}

int GPad_Backend_MaxPorts() { return 1; }

bool GPad_Backend_Poll(int port, GPadRawState *output) {
    if (!output) return false;
    *output = {};
    if (port != 0 || !cachedPad.connected) return false;
    *output = cachedPad;
    return true;
}

void GPad_Backend_SetRumble(int port, float low, float high) {
    if (port == 0) IOS_RequestControllerRumble(low, high);
}
