#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum IOSInputSource {
    IOS_INPUT_TOUCH = 0,
    IOS_INPUT_CONTROLLER = 1,
    IOS_INPUT_SOURCE_COUNT = 2,
    IOS_INPUT_NO_SOURCE = 255
} IOSInputSource;

// Virtual gamepad buttons, matching the verified GPadRawState backend contract.
// These are NOT T5 usercmd button_bits; the real engine performs that mapping.
enum IOSPadButton {
    IOS_PAD_UP = 0x0001, IOS_PAD_DOWN = 0x0002,
    IOS_PAD_LEFT = 0x0004, IOS_PAD_RIGHT = 0x0008,
    IOS_PAD_MENU = 0x0010, IOS_PAD_SCORES = 0x0020,
    IOS_PAD_SPRINT = 0x0040, IOS_PAD_MELEE = 0x0080,
    IOS_PAD_TACTICAL = 0x0100, IOS_PAD_LETHAL = 0x0200,
    IOS_PAD_JUMP = 0x1000, IOS_PAD_STANCE = 0x2000,
    IOS_PAD_USE_RELOAD = 0x4000, IOS_PAD_SWAP = 0x8000,
    IOS_PAD_VALID_MASK = 0xf3ff
};

typedef struct IOSInputFrame {
    IOSInputSource source;
    uint64_t epoch;       // Read with IOS_InputSourceEpoch; invalidated by reset.
    uint64_t sequence;    // Strictly increasing, nonzero, within this epoch.
    bool connected;
    uint32_t buttons;     // Held state. Short presses are latched until consumption.
    float leftTrigger, rightTrigger; // ADS/fire, 0..1.
    float moveX, moveY;   // Right and forward, -1..1.
    float lookX, lookY;   // Gamepad right/up, -1..1; held state, not angular deltas.
    float deltaX, deltaY; // Relative mouse pixels in a 1280x720 reference image.
    bool pointerValid;   // Touch/menu cursor normalized to the full image.
    float pointerX, pointerY;
    bool pointerDown;
} IOSInputFrame;

typedef struct IOSInputSample {
    bool suspended;
    bool connected;
    uint32_t heldButtons;
    uint32_t pressedButtons;  // Consume once. May coexist with a release for a quick tap.
    uint32_t releasedButtons;
    float leftTrigger, rightTrigger;
    float heldLeftTrigger, heldRightTrigger;
    uint8_t pressedTriggers;  // Bit 0 left, bit 1 right; union crosses the engine-published threshold.
    float moveX, moveY, lookX, lookY;
    float deltaX, deltaY;     // Consume once, including all accepted UI frames.
    IOSInputSource movementSource, lookSource;
    uint64_t touchEpoch;
    uint64_t controllerEpoch;
    uint64_t resetEpoch;     // All-source/lifecycle generation, independent of menu changes.
    bool pointerValid, pointerDown, pointerPressed, pointerReleased;
    float pointerX, pointerY;
} IOSInputSample;

typedef struct IOSRumbleRequest {
    uint64_t revision;
    float low, high;
} IOSRumbleRequest;

// Thread-safe, bounded, allocation-free after initialization. One engine-side
// consumer; independent producers may submit each source. Starts suspended.
uint64_t IOS_InputSourceEpoch(IOSInputSource source);
bool IOS_SubmitInputFrame(const IOSInputFrame *frame);
void IOS_ConsumeInput(IOSInputSample *sample);
void IOS_ResetInputSource(IOSInputSource source);
void IOS_ResetInput(void);
void IOS_SetInputSuspended(bool suspended);
bool IOS_IsInputSuspended(void);
uint64_t IOS_InputResetEpoch(void);

// The engine publishes menu ownership; UIKit never reads engine memory.
void IOS_SetInputMenuMode(bool menuMode);
bool IOS_GetInputMenuMode(void);
void IOS_SetInputContext(bool menuMode, bool pointerCaptured);
void IOS_GetInputContext(bool *menuMode, bool *pointerCaptured);
// The native adapter publishes its actual gpad_button_deadzone before consume.
// No gameplay deadzone is guessed by the UIKit frontend.
void IOS_SetInputTriggerThreshold(float threshold);

// Engine rumble output is handed to the UIKit controller frontend by revision.
void IOS_RequestControllerRumble(float low, float high);
void IOS_GetControllerRumble(IOSRumbleRequest *request);

#ifdef __cplusplus
}
#endif
