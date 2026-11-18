#pragma once
#include "ios_input_bridge.h"
#include <algorithm>
#include <array>

namespace bo1ios {
// A sampled native gamepad needs a low frame between two rising edges. Preserve
// quick taps arriving on successive engine frames instead of turning them into
// one hold. The transport coalesces repeated rises within a single sample; this
// sequencer bounds backlog to eight sample-level presses per control.
class PadPulseState final {
public:
    struct Output { uint32_t buttons; float leftTrigger, rightTrigger; };
    void reset() { *this = {}; }
    Output advance(const IOSInputSample &sample, float triggerThreshold) {
        Output result{};
        for (unsigned index = 0; index < pending_.size(); ++index) {
            const uint32_t bit = 1u << index;
            if (sample.pressedButtons & bit) pending_[index] = std::min<unsigned>(8, pending_[index] + 1);
            bool down;
            if ((previous_ & bit) && pending_[index]) down = false;
            else if (pending_[index]) { down = true; --pending_[index]; }
            else down = (sample.heldButtons & bit) != 0;
            if (down) result.buttons |= bit;
        }
        previous_ = result.buttons;
        result.leftTrigger = advanceTrigger(left_, sample.heldLeftTrigger, sample.leftTrigger, sample.pressedTriggers & 1, triggerThreshold);
        result.rightTrigger = advanceTrigger(right_, sample.heldRightTrigger, sample.rightTrigger, sample.pressedTriggers & 2, triggerThreshold);
        return result;
    }
private:
    struct Trigger { unsigned pending = 0; float peak = 0; bool down = false; };
    static float advanceTrigger(Trigger &trigger, float held, float peak, bool pressed, float threshold) {
        if (pressed) {
            trigger.pending = std::min(8u, trigger.pending + 1);
            trigger.peak = std::max(trigger.peak, peak);
        }
        float output;
        if (trigger.down && trigger.pending) output = 0;
        else if (trigger.pending) {
            --trigger.pending;
            output = std::max(held, trigger.peak);
            if (!trigger.pending) trigger.peak = 0;
        } else output = held;
        trigger.down = output > threshold;
        return output;
    }
    std::array<uint8_t, 16> pending_{};
    uint32_t previous_ = 0;
    Trigger left_, right_;
};
}
