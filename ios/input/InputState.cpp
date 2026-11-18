#include "InputState.h"
#include <algorithm>
#include <cmath>

namespace bo1ios {
namespace {
float finiteClamp(float value, float minimum, float maximum) {
    return std::isfinite(value) ? std::clamp(value, minimum, maximum) : 0.0f;
}
bool activeStick(float x, float y, float threshold) {
    return x * x + y * y > threshold * threshold;
}
uint64_t nextEpoch(uint64_t epoch) { return epoch == UINT64_MAX ? 1 : epoch + 1; }
}

bool InputState::valid(IOSInputSource source) {
    return source == IOS_INPUT_TOUCH || source == IOS_INPUT_CONTROLLER;
}

uint64_t InputState::epoch(IOSInputSource source) const {
    if (!valid(source)) return 0;
    std::lock_guard lock(mutex_);
    return sources_[source].epoch;
}

uint32_t InputState::heldLocked() const {
    return sources_[0].frame.buttons | sources_[1].frame.buttons;
}

float InputState::triggerLocked(bool right) const {
    return right ? std::max(sources_[0].frame.rightTrigger, sources_[1].frame.rightTrigger) :
        std::max(sources_[0].frame.leftTrigger, sources_[1].frame.leftTrigger);
}

void InputState::clearSourceLocked(IOSInputSource source, bool advanceEpoch) {
    Source &state = sources_[source];
    const uint32_t before = heldLocked();
    const uint32_t pending = state.pendingPressed;
    const uint8_t pendingTriggers = state.pendingTriggers;
    const bool pointerWasDown = state.frame.pointerDown || state.pointerReleased;
    const uint64_t epoch = advanceEpoch ? nextEpoch(state.epoch) : state.epoch;
    const uint64_t sequence = advanceEpoch ? 0 : state.sequence;
    state = Source{};
    state.epoch = epoch;
    state.sequence = sequence;
    state.pointerReleased = pointerWasDown;
    const uint32_t after = heldLocked();
    released_ |= before & ~after;
    // If a second source still holds the same button, its pending first press
    // survives the other device's reset/disconnect.
    for (Source &other : sources_) {
        other.pendingPressed |= pending & other.frame.buttons;
        if (other.frame.leftTrigger > triggerThreshold_) other.pendingTriggers |= pendingTriggers & 1;
        if (other.frame.rightTrigger > triggerThreshold_) other.pendingTriggers |= pendingTriggers & 2;
    }
}

void InputState::clearAllLocked() {
    const uint32_t before = heldLocked();
    const bool pointerWasDown = sources_[IOS_INPUT_TOUCH].frame.pointerDown ||
        sources_[IOS_INPUT_TOUCH].pointerReleased;
    for (Source &source : sources_) {
        const uint64_t epoch = nextEpoch(source.epoch);
        source = Source{};
        source.epoch = epoch;
    }
    sources_[IOS_INPUT_TOUCH].pointerReleased = pointerWasDown;
    released_ |= before;
    resetEpoch_ = nextEpoch(resetEpoch_);
    rumble_ = {nextEpoch(rumble_.revision), 0, 0};
}

bool InputState::submit(const IOSInputFrame &incoming) {
    if (!valid(incoming.source) || incoming.sequence == 0) return false;
    std::lock_guard lock(mutex_);
    Source &source = sources_[incoming.source];
    if (suspended_ || incoming.epoch != source.epoch || incoming.sequence <= source.sequence) return false;
    if (!incoming.connected) {
        clearSourceLocked(incoming.source, source.frame.connected);
        source.sequence = incoming.sequence;
        return true;
    }
    const uint32_t before = heldLocked();
    const float leftBefore = triggerLocked(false), rightBefore = triggerLocked(true);
    const bool oldPointerDown = source.frame.pointerDown;
    IOSInputFrame frame = incoming;
    frame.buttons &= IOS_PAD_VALID_MASK;
    frame.leftTrigger = finiteClamp(frame.leftTrigger, 0, 1);
    frame.rightTrigger = finiteClamp(frame.rightTrigger, 0, 1);
    frame.moveX = finiteClamp(frame.moveX, -1, 1);
    frame.moveY = finiteClamp(frame.moveY, -1, 1);
    frame.lookX = finiteClamp(frame.lookX, -1, 1);
    frame.lookY = finiteClamp(frame.lookY, -1, 1);
    frame.deltaX = finiteClamp(frame.deltaX, -4096, 4096);
    frame.deltaY = finiteClamp(frame.deltaY, -4096, 4096);
    frame.pointerX = finiteClamp(frame.pointerX, 0, 1);
    frame.pointerY = finiteClamp(frame.pointerY, 0, 1);
    // Only the touch source owns the menu pointer.
    frame.pointerValid = incoming.source == IOS_INPUT_TOUCH && frame.pointerValid;
    frame.pointerDown = frame.pointerValid && frame.pointerDown;
    source.frame = frame;
    source.sequence = frame.sequence;
    const uint32_t after = heldLocked();
    source.pendingPressed |= after & ~before;
    if (leftBefore <= triggerThreshold_ && triggerLocked(false) > triggerThreshold_) source.pendingTriggers |= 1;
    if (rightBefore <= triggerThreshold_ && triggerLocked(true) > triggerThreshold_) source.pendingTriggers |= 2;
    released_ |= before & ~after;
    source.peakLeft = std::max(source.peakLeft, frame.leftTrigger);
    source.peakRight = std::max(source.peakRight, frame.rightTrigger);
    source.deltaX = std::clamp(source.deltaX + frame.deltaX, -16384.0, 16384.0);
    source.deltaY = std::clamp(source.deltaY + frame.deltaY, -16384.0, 16384.0);
    source.pointerPressed |= frame.pointerDown && !oldPointerDown;
    source.pointerReleased |= oldPointerDown && !frame.pointerDown;
    return true;
}

IOSInputSample InputState::consume() {
    std::lock_guard lock(mutex_);
    IOSInputSample output{};
    output.suspended = suspended_;
    output.movementSource = output.lookSource = IOS_INPUT_NO_SOURCE;
    output.touchEpoch = sources_[IOS_INPUT_TOUCH].epoch;
    output.controllerEpoch = sources_[IOS_INPUT_CONTROLLER].epoch;
    output.resetEpoch = resetEpoch_;
    output.releasedButtons = released_;
    released_ = 0;
    Source &touch = sources_[IOS_INPUT_TOUCH];
    Source &controller = sources_[IOS_INPUT_CONTROLLER];
    if (!suspended_) {
        output.connected = touch.frame.connected || controller.frame.connected;
        output.heldButtons = heldLocked();
        output.heldLeftTrigger = triggerLocked(false);
        output.heldRightTrigger = triggerLocked(true);
        for (const Source &source : sources_) {
            output.pressedButtons |= source.pendingPressed;
            output.pressedTriggers |= source.pendingTriggers;
            output.leftTrigger = std::max(output.leftTrigger, std::max(source.frame.leftTrigger, source.peakLeft));
            output.rightTrigger = std::max(output.rightTrigger, std::max(source.frame.rightTrigger, source.peakRight));
        }
        // Intentional controller deflection wins. Neutral/stick drift does not
        // block touch movement; the engine still applies its own deadzones.
        IOSInputSource movement = activeStick(controller.frame.moveX, controller.frame.moveY, 0.2f)
            || !activeStick(touch.frame.moveX, touch.frame.moveY, 0.0001f) ? IOS_INPUT_CONTROLLER : IOS_INPUT_TOUCH;
        if (sources_[movement].frame.connected) {
            output.movementSource = movement;
            output.moveX = sources_[movement].frame.moveX;
            output.moveY = sources_[movement].frame.moveY;
        }
        const bool touchLook = touch.deltaX != 0 || touch.deltaY != 0 ||
            activeStick(touch.frame.lookX, touch.frame.lookY, 0.0001f);
        IOSInputSource look = activeStick(controller.frame.lookX, controller.frame.lookY, 0.2f)
            || !touchLook ? IOS_INPUT_CONTROLLER : IOS_INPUT_TOUCH;
        if (sources_[look].frame.connected) {
            output.lookSource = look;
            output.lookX = sources_[look].frame.lookX;
            output.lookY = sources_[look].frame.lookY;
            output.deltaX = (float)sources_[look].deltaX;
            output.deltaY = (float)sources_[look].deltaY;
        }
        output.pointerValid = touch.frame.pointerValid;
        output.pointerDown = touch.frame.pointerDown;
        output.pointerPressed = touch.pointerPressed;
        output.pointerX = touch.frame.pointerX;
        output.pointerY = touch.frame.pointerY;
    }
    output.pointerReleased = touch.pointerReleased;
    for (Source &source : sources_) {
        source.pendingPressed = 0;
        source.pendingTriggers = 0;
        source.peakLeft = source.peakRight = 0;
        source.deltaX = source.deltaY = 0;
        source.pointerPressed = source.pointerReleased = false;
    }
    return output;
}

void InputState::resetSource(IOSInputSource source) {
    if (!valid(source)) return;
    std::lock_guard lock(mutex_);
    clearSourceLocked(source, true);
}
void InputState::reset() { std::lock_guard lock(mutex_); clearAllLocked(); }
void InputState::setSuspended(bool suspended) {
    std::lock_guard lock(mutex_);
    if (suspended_ == suspended) return;
    clearAllLocked();
    suspended_ = suspended;
}
bool InputState::suspended() const { std::lock_guard lock(mutex_); return suspended_; }
uint64_t InputState::resetEpoch() const { std::lock_guard lock(mutex_); return resetEpoch_; }
void InputState::setMenuMode(bool menuMode) {
    setContext(menuMode, false);
}
void InputState::setContext(bool menuMode, bool pointerCaptured) {
    std::lock_guard lock(mutex_);
    pointerCaptured = menuMode && pointerCaptured;
    if (menuMode_ == menuMode && pointerCaptured_ == pointerCaptured) return;
    clearSourceLocked(IOS_INPUT_TOUCH, true);
    menuMode_ = menuMode;
    pointerCaptured_ = pointerCaptured;
}
bool InputState::menuMode() const { std::lock_guard lock(mutex_); return menuMode_; }
void InputState::context(bool &menuMode, bool &pointerCaptured) const {
    std::lock_guard lock(mutex_);
    menuMode = menuMode_;
    pointerCaptured = pointerCaptured_;
}
void InputState::setTriggerThreshold(float threshold) {
    std::lock_guard lock(mutex_);
    threshold = finiteClamp(threshold, 0, 1);
    if (triggerThreshold_ == threshold) return;
    triggerThreshold_ = threshold;
    // Reclassify retained peaks if the engine initialized/changed its dvar
    // since publication; a short pull before the first pump is still visible.
    for (Source &source : sources_) {
        source.pendingTriggers = 0;
        if (std::max(source.frame.leftTrigger, source.peakLeft) > threshold) source.pendingTriggers |= 1;
        if (std::max(source.frame.rightTrigger, source.peakRight) > threshold) source.pendingTriggers |= 2;
    }
}
void InputState::requestRumble(float low, float high) {
    std::lock_guard lock(mutex_);
    low = suspended_ ? 0 : finiteClamp(low, 0, 1);
    high = suspended_ ? 0 : finiteClamp(high, 0, 1);
    if (low != rumble_.low || high != rumble_.high)
        rumble_ = {nextEpoch(rumble_.revision), low, high};
}
IOSRumbleRequest InputState::rumble() const { std::lock_guard lock(mutex_); return rumble_; }

}
