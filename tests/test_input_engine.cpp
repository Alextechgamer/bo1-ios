#include "bo1_engine_input.h"
#include "ios_input_bridge.h"
#include <client/gpad_backend.h>
#include <cstdlib>
#include <iostream>
#include <vector>

// Test-only capture of the real upstream native queue API. Production links
// src/web/web_input.cpp; this executable deliberately does not claim to run T5.
namespace {
bool menu = false;
bool grabbed = false;
int appliedGrab = 0, motionResets = 0;
float nativeTriggerThreshold = .13f;
struct Motion { int dx, dy, x, y, width, height; };
std::vector<Motion> motions;
std::vector<int> buttons, focus;
uint64_t sequence = 0;
int checks = 0;
void check(bool condition, const char *message) {
    ++checks;
    if (!condition) { std::cerr << "FAIL: " << message << '\n'; std::exit(1); }
}
IOSInputFrame frame() {
    IOSInputFrame value{};
    value.source = IOS_INPUT_TOUCH;
    value.epoch = IOS_InputSourceEpoch(value.source);
    value.sequence = ++sequence;
    value.connected = true;
    return value;
}
void send(IOSInputFrame &value) {
    value.sequence = ++sequence;
    check(IOS_SubmitInputFrame(&value), "adapter input frame accepted");
}
}
extern "C" int bo1_native_ui_active() { return menu; }
extern "C" int bo1_native_input_wants_grab() { return grabbed; }
extern "C" void bo1_native_input_set_grabbed(int value) { appliedGrab = value; }
extern "C" void bo1_native_input_clear_motion() { ++motionResets; }
extern "C" float bo1_native_input_trigger_deadzone() { return nativeTriggerThreshold; }
extern "C" void bo1_native_input_motion(int dx,int dy,int x,int y,int w,int h) { motions.push_back({dx,dy,x,y,w,h}); }
extern "C" void bo1_native_input_buttons(int mask) { buttons.push_back(mask); }
extern "C" void bo1_native_input_focus(int value) { focus.push_back(value); }

int main() {
    check(GPad_Backend_MaxPorts() == 1, "one verified local player port");
    IOS_SetInputSuspended(false);
    IOS_BO1_PumpInput(); // Publish initial menu ownership before touches begin.
    check(focus.size() == 1 && focus.back() == 1, "foreground focus forwarded on engine thread");
    auto input = frame();
    input.buttons = IOS_PAD_JUMP;
    send(input);
    input.buttons = 0;
    send(input);
    IOS_BO1_PumpInput();
    GPadRawState a{}, b{};
    check(GPad_Backend_Poll(0, &a) && GPad_Backend_Poll(0, &b) && a.buttons == GPAD_RAW_A && b.buttons == GPAD_RAW_A,
          "repeated native polling observes the same latched quick press");
    IOS_BO1_PumpInput(); GPad_Backend_Poll(0, &a);
    check(a.buttons == 0, "following engine frame releases quick press");
    for (int tap = 0; tap < 2; ++tap) {
        input.buttons = IOS_PAD_JUMP; send(input);
        input.buttons = 0; send(input);
        IOS_BO1_PumpInput(); GPad_Backend_Poll(0, &a);
        check(a.buttons == (tap == 0 ? GPAD_RAW_A : 0), "successive short taps receive an intervening release frame");
    }
    IOS_BO1_PumpInput(); GPad_Backend_Poll(0, &a);
    check(a.buttons == GPAD_RAW_A, "second queued tap gets its own native rising edge");
    IOS_BO1_PumpInput(); GPad_Backend_Poll(0, &a);
    check(a.buttons == 0, "second tap releases without sticking");
    for (int tap = 0; tap < 2; ++tap) {
        input.rightTrigger = 1; send(input);
        input.rightTrigger = 0; send(input);
        IOS_BO1_PumpInput(); GPad_Backend_Poll(0, &a);
        check(a.rt == (tap == 0 ? 1 : 0), "successive short trigger pulls receive an intervening release frame");
    }
    IOS_BO1_PumpInput(); GPad_Backend_Poll(0, &a);
    check(a.rt == 1, "second queued trigger pull gets its own rising edge");
    IOS_BO1_PumpInput(); GPad_Backend_Poll(0, &a);
    check(a.rt == 0, "second trigger pull releases");
    input.rightTrigger = .02f; send(input); IOS_BO1_PumpInput();
    for (int tap = 0; tap < 2; ++tap) {
        input.rightTrigger = 1; send(input);
        input.rightTrigger = .02f; send(input);
        IOS_BO1_PumpInput(); GPad_Backend_Poll(0, &a);
        check(a.rt == (tap == 0 ? 1 : 0), "nonzero trigger rest preserves quick pulls using the actual native deadzone");
    }
    IOS_BO1_PumpInput(); GPad_Backend_Poll(0, &a);
    check(a.rt == 1, "second nonzero-rest pull receives its own edge");
    IOS_BO1_PumpInput(); GPad_Backend_Poll(0, &a);
    check(a.rt == .02f, "nonzero-rest trigger returns to its real resting pressure");
    input.rightTrigger = 0; send(input); IOS_BO1_PumpInput();
    a.buttons = 0xffff; a.connected = true;
    check(!GPad_Backend_Poll(1, &a) && !a.connected && a.buttons == 0 && !GPad_Backend_Poll(0, nullptr), "unsupported ports and null outputs handled");
    motions.clear();
    for (int i = 0; i < 4; ++i) {
        input.deltaX = .25f; input.deltaY = -.25f;
        send(input); IOS_BO1_PumpInput();
        GPad_Backend_Poll(0, &a); GPad_Backend_Poll(0, &b);
    }
    check(motions.size() == 1 && motions[0].dx == 1 && motions[0].dy == -1, "fractional touch pixels accumulate across frames without poll replay");
    IOS_BO1_PumpInput();
    check(motions.size() == 1, "no new movement without new producer delta");
    input.deltaX = .75f; input.deltaY = 0; send(input); IOS_BO1_PumpInput();
    IOS_ResetInput(); input = frame(); input.deltaX = .25f; send(input); IOS_BO1_PumpInput();
    check(motions.size() == 1, "reset discards fractional look remainder");
    IOSInputFrame controller{};
    controller.source = IOS_INPUT_CONTROLLER;
    controller.epoch = IOS_InputSourceEpoch(controller.source);
    controller.sequence = 1; controller.connected = true;
    controller.buttons = IOS_PAD_MELEE; controller.leftTrigger = .8f;
    controller.moveY = 1; controller.lookX = .5f;
    check(IOS_SubmitInputFrame(&controller), "controller sample accepted");
    IOS_BO1_PumpInput(); GPad_Backend_Poll(0, &a);
    check(a.buttons == GPAD_RAW_RIGHT_THUMB && a.lt == .8f && a.ly == 1 && a.rx == .5f, "real header raw controller contract preserved");
    menu = true; IOS_BO1_PumpInput();
    input = frame(); input.pointerValid = input.pointerDown = true;
    input.pointerX = .25f; input.pointerY = .75f;
    send(input); input.pointerDown = false; send(input);
    buttons.clear(); motions.clear(); IOS_BO1_PumpInput();
    check(buttons.empty(), "menu pointer moves before click is emitted");
    check(motions.size() == 1 && motions[0].x == 320 && motions[0].y == 540 &&
          motions[0].width == 1280 && motions[0].height == 720 && motions[0].dx == 0, "normalized pointer uses native menu image coordinates");
    IOS_BO1_PumpInput(); IOS_BO1_PumpInput();
    check(buttons.size() == 1 && buttons[0] == 1, "menu click follows two hover frames");
    IOS_BO1_PumpInput(); IOS_BO1_PumpInput();
    check(buttons.size() == 2 && buttons[1] == 0, "menu click release arrives in a later frame");
    controller.lookX = 0; controller.buttons = 0; controller.sequence = 2;
    check(IOS_SubmitInputFrame(&controller), "controller look returns to neutral before touch menu look");
    grabbed = true; IOS_BO1_PumpInput();
    input = frame(); input.deltaX = 8; input.buttons = IOS_PAD_DOWN;
    send(input); motions.clear(); IOS_BO1_PumpInput(); GPad_Backend_Poll(0, &a);
    bool menuContext = false, capturedContext = false;
    IOS_GetInputContext(&menuContext, &capturedContext);
    check(menuContext && capturedContext && appliedGrab == 1 &&
          motions.size() == 1 && motions[0].dx == 8 && motions[0].x == -64 &&
          (a.buttons & GPAD_RAW_DPAD_DOWN), "3D title menus receive native D-pad controls and right-side relative look");
    GPad_Backend_SetRumble(0, .4f, .7f);
    IOSRumbleRequest rumble{}; IOS_GetControllerRumble(&rumble);
    check(rumble.low == .4f && rumble.high == .7f, "engine rumble request reaches frontend transport");
    IOS_SetInputSuspended(true); IOS_BO1_PumpInput();
    check(focus.back() == 0 && !GPad_Backend_Poll(0, &a), "suspension removes cached gamepad and forwards focus loss");
    IOS_GetControllerRumble(&rumble);
    check(rumble.low == 0 && rumble.high == 0, "suspension zeroes rumble");
    IOS_SetInputSuspended(false); IOS_BO1_PumpInput();
    check(focus.back() == 1 && !GPad_Backend_Poll(0, &a), "resume requires new producer state");
    const auto focusCount = focus.size();
    const int resetCount = motionResets;
    IOS_SetInputSuspended(true); IOS_SetInputSuspended(false);
    IOS_BO1_PumpInput();
    check(focus.size() == focusCount + 2 && focus[focusCount] == 0 && focus[focusCount + 1] == 1 && motionResets > resetCount,
          "pause and resume between engine polls still resets native focus and motion");
    check(IOS_BO1_InputEpoch() == IOS_InputResetEpoch(), "native queue generation matches the consumed reset epoch");
    check(!IOS_SubmitInputFrame(nullptr), "null C producer frame rejected");
    IOS_ConsumeInput(nullptr); IOS_GetControllerRumble(nullptr);
    std::cout << "Pinned engine input adapter: " << checks << " checks passed\n";
}
