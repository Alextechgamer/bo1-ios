#pragma once

#include "ios_input_bridge.h"
#include <array>
#include <mutex>

namespace bo1ios {

class InputState final {
public:
    uint64_t epoch(IOSInputSource source) const;
    bool submit(const IOSInputFrame &frame);
    IOSInputSample consume();
    void resetSource(IOSInputSource source);
    void reset();
    void setSuspended(bool suspended);
    bool suspended() const;
    uint64_t resetEpoch() const;
    void setMenuMode(bool menuMode);
    bool menuMode() const;
    void setContext(bool menuMode, bool pointerCaptured);
    void context(bool &menuMode, bool &pointerCaptured) const;
    void setTriggerThreshold(float threshold);
    void requestRumble(float low, float high);
    IOSRumbleRequest rumble() const;

private:
    struct Source {
        uint64_t epoch = 1, sequence = 0;
        IOSInputFrame frame{};
        uint32_t pendingPressed = 0;
        uint8_t pendingTriggers = 0;
        float peakLeft = 0, peakRight = 0;
        double deltaX = 0, deltaY = 0;
        bool pointerPressed = false, pointerReleased = false;
    };
    static bool valid(IOSInputSource source);
    uint32_t heldLocked() const;
    float triggerLocked(bool right) const;
    void clearSourceLocked(IOSInputSource source, bool advanceEpoch);
    void clearAllLocked();

    mutable std::mutex mutex_;
    std::array<Source, IOS_INPUT_SOURCE_COUNT> sources_{};
    uint32_t released_ = 0;
    bool suspended_ = true;
    bool menuMode_ = true;
    bool pointerCaptured_ = false;
    uint64_t resetEpoch_ = 1;
    float triggerThreshold_ = 0;
    IOSRumbleRequest rumble_{1, 0, 0};
};

}
