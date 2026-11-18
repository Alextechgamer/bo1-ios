#pragma once
#include "ios_input_bridge.h"
#include <cmath>

namespace bo1ios {
// After suspension or a controller switch, require physical controls to return
// to rest before accepting a held trigger/button again. Small stick drift is
// allowed; the native engine continues to own normal gameplay deadzones.
inline bool ControllerIsNeutral(const IOSInputFrame &frame) {
    return frame.buttons == 0 && frame.leftTrigger <= .05f && frame.rightTrigger <= .05f &&
        std::hypot(frame.moveX, frame.moveY) <= .2f &&
        std::hypot(frame.lookX, frame.lookY) <= .2f;
}

inline IOSInputFrame NeutralControllerFrame(const IOSInputFrame &frame) {
    IOSInputFrame result{};
    result.source = frame.source;
    result.epoch = frame.epoch;
    result.sequence = frame.sequence;
    result.connected = frame.connected;
    return result;
}
}
