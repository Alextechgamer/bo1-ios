#include "InputState.h"
#include "InputPolicy.h"
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <thread>

namespace {
int checks = 0;
void check(bool condition, const char *description) {
    ++checks;
    if (!condition) { std::cerr << "FAIL: " << description << '\n'; std::exit(1); }
}
bool near(float a, float b) { return std::abs(a - b) < .0001f; }
struct Writer {
    bo1ios::InputState &state;
    IOSInputSource source;
    uint64_t sequence = 0;
    IOSInputFrame frame() {
        IOSInputFrame result{};
        result.source = source;
        result.epoch = state.epoch(source);
        result.sequence = ++sequence;
        result.connected = true;
        return result;
    }
    bool send(IOSInputFrame frame) {
        frame.sequence = ++sequence;
        return state.submit(frame);
    }
};

void testEdges() {
    bo1ios::InputState state;
    Writer touch{state, IOS_INPUT_TOUCH};
    auto frame = touch.frame();
    check(!state.submit(frame), "initial suspension rejects input");
    state.setSuspended(false);
    frame = touch.frame();
    frame.buttons = IOS_PAD_JUMP;
    check(state.submit(frame), "first press accepted");
    auto sample = state.consume();
    check(sample.heldButtons == IOS_PAD_JUMP && sample.pressedButtons == IOS_PAD_JUMP, "press is held and edged once");
    check(touch.send(frame), "repeat held accepted");
    sample = state.consume();
    check(sample.heldButtons == IOS_PAD_JUMP && sample.pressedButtons == 0, "held button does not repeatedly press");
    frame.buttons = 0;
    touch.send(frame);
    sample = state.consume();
    check(sample.heldButtons == 0 && sample.releasedButtons == IOS_PAD_JUMP, "release is delivered");
    check(state.consume().releasedButtons == 0, "release is consumed once");
    frame.buttons = IOS_PAD_USE_RELOAD;
    touch.send(frame);
    frame.buttons = 0;
    touch.send(frame);
    sample = state.consume();
    check(sample.heldButtons == 0 && sample.pressedButtons == IOS_PAD_USE_RELOAD &&
          sample.releasedButtons == IOS_PAD_USE_RELOAD, "complete tap between engine frames is preserved");
    sample = state.consume();
    check(sample.pressedButtons == 0 && sample.releasedButtons == 0, "short tap is not replayed");
    frame.rightTrigger = 1;
    touch.send(frame);
    frame.rightTrigger = 0;
    touch.send(frame);
    sample = state.consume();
    check(near(sample.rightTrigger, 1) && sample.heldRightTrigger == 0 && (sample.pressedTriggers & 2), "short trigger pull is latched separately from held state");
    check(near(state.consume().rightTrigger, 0), "short trigger pull is consumed once");
    frame.leftTrigger = .7f;
    touch.send(frame);
    check(near(state.consume().leftTrigger, .7f) && near(state.consume().leftTrigger, .7f), "held ADS trigger persists");
}

void testMotionAndArbitration() {
    bo1ios::InputState state;
    state.setSuspended(false);
    Writer touch{state, IOS_INPUT_TOUCH}, controller{state, IOS_INPUT_CONTROLLER};
    auto t = touch.frame();
    t.moveX = .4f; t.moveY = .5f; t.deltaX = 3.25f; t.deltaY = -2;
    state.submit(t);
    t.deltaX = 1.5f; t.deltaY = .5f;
    touch.send(t);
    auto sample = state.consume();
    check(near(sample.deltaX, 4.75f) && near(sample.deltaY, -1.5f), "motion accumulates across UI frames");
    check(sample.lookSource == IOS_INPUT_TOUCH && sample.movementSource == IOS_INPUT_TOUCH, "touch owns active axes");
    sample = state.consume();
    check(near(sample.deltaX, 0) && near(sample.deltaY, 0) && near(sample.moveY, .5f), "motion consumes once while movement stays held");
    auto c = controller.frame();
    c.moveX = .8f; c.lookX = -.7f;
    state.submit(c);
    t.deltaX = 12; t.deltaY = 0;
    touch.send(t);
    sample = state.consume();
    check(sample.movementSource == IOS_INPUT_CONTROLLER && sample.lookSource == IOS_INPUT_CONTROLLER &&
          near(sample.moveX, .8f) && near(sample.lookX, -.7f) && near(sample.deltaX, 0), "intentional controller axes win without adding touch motion");
    c.moveX = .05f; c.lookX = 0;
    controller.send(c);
    sample = state.consume();
    check(sample.movementSource == IOS_INPUT_TOUCH && near(sample.moveX, .4f) && near(sample.deltaX, 0), "neutral controller permits touch and suppressed motion never replays");
    t.deltaX = .5f; t.deltaY = 0;
    touch.send(t);
    sample = state.consume();
    check(sample.lookSource == IOS_INPUT_TOUCH && near(sample.deltaX, .5f), "touch look works with neutral connected controller");
    t.buttons = IOS_PAD_JUMP;
    t.deltaX = 0;
    touch.send(t);
    c.buttons = IOS_PAD_MELEE;
    controller.send(c);
    sample = state.consume();
    check(sample.heldButtons == (IOS_PAD_JUMP | IOS_PAD_MELEE), "independent source buttons merge");
}

void testResetAndOwnership() {
    bo1ios::InputState state;
    state.setSuspended(false);
    Writer touch{state, IOS_INPUT_TOUCH}, controller{state, IOS_INPUT_CONTROLLER};
    auto t = touch.frame(); t.buttons = IOS_PAD_JUMP;
    auto c = controller.frame(); c.buttons = IOS_PAD_JUMP;
    state.submit(t); state.submit(c);
    state.resetSource(IOS_INPUT_TOUCH);
    auto sample = state.consume();
    check(sample.heldButtons == IOS_PAD_JUMP && sample.pressedButtons == IOS_PAD_JUMP && sample.releasedButtons == 0,
          "resetting one source preserves a shared held button and its pending press");
    c.connected = false;
    controller.send(c);
    sample = state.consume();
    check(sample.heldButtons == 0 && sample.releasedButtons == IOS_PAD_JUMP && !sample.connected, "last source disconnect releases the shared button");
    t = touch.frame(); t.buttons = IOS_PAD_LETHAL; t.deltaX = 20;
    state.submit(t);
    const auto previousEpoch = t.epoch;
    state.reset();
    t.sequence += 500;
    check(!state.submit(t) && state.epoch(IOS_INPUT_TOUCH) != previousEpoch, "reset rejects a late producer frame using the old epoch");
    sample = state.consume();
    check(!sample.connected && sample.pressedButtons == 0 && sample.deltaX == 0 && sample.heldButtons == 0, "reset cancels pending commands and look");
    t = touch.frame(); t.buttons = IOS_PAD_MELEE;
    state.submit(t); state.consume();
    t.buttons = 0; touch.send(t);
    state.reset(); state.setSuspended(true); state.setSuspended(false);
    sample = state.consume();
    check(sample.releasedButtons == IOS_PAD_MELEE, "release survives reset and suspension before consumption");
    state.setSuspended(true);
    t = touch.frame(); t.buttons = IOS_PAD_JUMP;
    check(!state.submit(t), "background input rejected even with current epoch");
    check(state.consume().suspended, "consumer observes suspension");
    state.setSuspended(false);
    check(!state.submit(t), "resume invalidates captured background frames");
    sample = state.consume();
    check(sample.heldButtons == 0 && sample.pressedButtons == 0 && sample.deltaX == 0, "resume has no stale state");
}

void testPointerAndValidation() {
    bo1ios::InputState state;
    state.setSuspended(false);
    Writer touch{state, IOS_INPUT_TOUCH}, controller{state, IOS_INPUT_CONTROLLER};
    auto t = touch.frame();
    t.pointerValid = t.pointerDown = true; t.pointerX = .25f; t.pointerY = .75f;
    state.submit(t);
    t.pointerDown = false; touch.send(t);
    auto sample = state.consume();
    check(sample.pointerValid && !sample.pointerDown && sample.pointerPressed && sample.pointerReleased &&
          near(sample.pointerX, .25f), "menu pointer tap is retained between frames");
    sample = state.consume();
    check(!sample.pointerPressed && !sample.pointerReleased, "pointer edges consume once");
    t.pointerDown = true; touch.send(t); state.consume();
    state.resetSource(IOS_INPUT_TOUCH); state.resetSource(IOS_INPUT_TOUCH);
    check(state.consume().pointerReleased, "pointer release survives repeated resets");
    auto c = controller.frame(); c.pointerValid = c.pointerDown = true;
    state.submit(c);
    check(!state.consume().pointerValid, "controller cannot take menu pointer ownership");
    t = touch.frame();
    t.buttons = UINT32_MAX; t.moveX = 4; t.moveY = -3;
    t.lookX = std::numeric_limits<float>::quiet_NaN();
    t.deltaX = std::numeric_limits<float>::infinity(); t.deltaY = 50000;
    t.leftTrigger = -5; t.rightTrigger = 8;
    state.submit(t);
    check(!state.submit(t), "duplicate sequence rejected");
    sample = state.consume();
    check(sample.heldButtons == IOS_PAD_VALID_MASK && near(sample.moveX, 1) && near(sample.moveY, -1), "button mask and axes bounded");
    check(near(sample.lookX, 0) && near(sample.deltaX, 0) && near(sample.deltaY, 4096), "nonfinite and excessive deltas sanitized");
    check(near(sample.leftTrigger, 0) && near(sample.rightTrigger, 1), "trigger range clamped");
    t.source = IOS_INPUT_NO_SOURCE;
    check(!state.submit(t) && state.epoch(IOS_INPUT_NO_SOURCE) == 0, "invalid source rejected");
    const auto epoch = state.epoch(IOS_INPUT_TOUCH);
    const auto resetEpoch = state.resetEpoch();
    state.setMenuMode(false);
    check(state.epoch(IOS_INPUT_TOUCH) != epoch && state.consume().heldButtons == 0, "menu transition invalidates old touch gestures");
    check(state.resetEpoch() == resetEpoch, "menu ownership changes do not masquerade as lifecycle resets");
    state.setContext(true, true);
    bool menu = false, captured = false;
    state.context(menu, captured);
    check(menu && captured, "captured 3D menu context is distinct from pointer menus");
}

void testRumbleAndNeutralPolicy() {
    bo1ios::InputState state;
    state.requestRumble(1, 1);
    check(state.rumble().low == 0 && state.rumble().high == 0, "suspended engine cannot start rumble");
    state.setSuspended(false);
    const auto previous = state.rumble().revision;
    state.requestRumble(3, -.5f);
    const auto rumble = state.rumble();
    check(rumble.low == 1 && rumble.high == 0 && rumble.revision != previous, "rumble request bounded and versioned");
    state.reset();
    check(state.rumble().low == 0 && state.rumble().revision != rumble.revision, "reset stops rumble with a new revision");
    IOSInputFrame c{}; c.source = IOS_INPUT_CONTROLLER; c.connected = true; c.epoch = 4; c.sequence = 7;
    c.moveX = .03f;
    check(bo1ios::ControllerIsNeutral(c), "small stick drift allows post-resume neutral gate");
    c.rightTrigger = 1; c.buttons = IOS_PAD_MELEE;
    check(!bo1ios::ControllerIsNeutral(c), "held trigger and button block post-resume gate");
    auto neutral = bo1ios::NeutralControllerFrame(c);
    check(neutral.connected && neutral.epoch == 4 && neutral.sequence == 7 && neutral.buttons == 0 && neutral.rightTrigger == 0,
          "neutral gate keeps source metadata but clears commands");
}

void testConcurrentProducers() {
    bo1ios::InputState state;
    state.setSuspended(false);
    constexpr int count = 12000;
    std::atomic<int> finished{0};
    std::atomic<bool> accepted{true};
    auto produce = [&](IOSInputSource source) {
        Writer writer{state, source};
        for (int i = 0; i < count; ++i) {
            auto frame = writer.frame();
            if (source == IOS_INPUT_TOUCH) frame.deltaX = .125f;
            else { frame.moveX = .7f; frame.buttons = (i & 1) ? IOS_PAD_MELEE : 0; }
            if (!state.submit(frame)) accepted.store(false);
        }
        finished.fetch_add(1);
    };
    std::thread touch(produce, IOS_INPUT_TOUCH), controller(produce, IOS_INPUT_CONTROLLER);
    double total = 0;
    while (finished.load() != 2) { total += state.consume().deltaX; std::this_thread::yield(); }
    touch.join(); controller.join();
    total += state.consume().deltaX;
    check(accepted.load(), "concurrent source sequences remain valid");
    check(std::abs(total - count * .125) < .0001, "concurrent producer/consumer never drops or repeats touch motion");
    check(state.consume().deltaX == 0, "final concurrent delta consumed once");
}
}

int main() {
    testEdges(); testMotionAndArbitration(); testResetAndOwnership(); testPointerAndValidation();
    testRumbleAndNeutralPolicy(); testConcurrentProducers();
    std::cout << "Input state: " << checks << " checks passed\n";
}
