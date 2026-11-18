#include "InputState.h"

namespace { bo1ios::InputState input; }

extern "C" uint64_t IOS_InputSourceEpoch(IOSInputSource source) { return input.epoch(source); }
extern "C" bool IOS_SubmitInputFrame(const IOSInputFrame *frame) { return frame && input.submit(*frame); }
extern "C" void IOS_ConsumeInput(IOSInputSample *sample) { if (sample) *sample = input.consume(); }
extern "C" void IOS_ResetInputSource(IOSInputSource source) { input.resetSource(source); }
extern "C" void IOS_ResetInput(void) { input.reset(); }
extern "C" void IOS_SetInputSuspended(bool suspended) { input.setSuspended(suspended); }
extern "C" bool IOS_IsInputSuspended(void) { return input.suspended(); }
extern "C" uint64_t IOS_InputResetEpoch(void) { return input.resetEpoch(); }
extern "C" void IOS_SetInputMenuMode(bool menuMode) { input.setMenuMode(menuMode); }
extern "C" bool IOS_GetInputMenuMode(void) { return input.menuMode(); }
extern "C" void IOS_SetInputContext(bool menuMode, bool pointerCaptured) { input.setContext(menuMode, pointerCaptured); }
extern "C" void IOS_GetInputContext(bool *menuMode, bool *pointerCaptured) {
    bool menu, captured;
    input.context(menu, captured);
    if (menuMode) *menuMode = menu;
    if (pointerCaptured) *pointerCaptured = captured;
}
extern "C" void IOS_SetInputTriggerThreshold(float threshold) { input.setTriggerThreshold(threshold); }
extern "C" void IOS_RequestControllerRumble(float low, float high) { input.requestRumble(low, high); }
extern "C" void IOS_GetControllerRumble(IOSRumbleRequest *request) { if (request) *request = input.rumble(); }
