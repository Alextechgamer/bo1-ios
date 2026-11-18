#import "BO1InputFrontend.h"
#include "InputPolicy.h"

#if !__has_feature(objc_arc)
#error "Build BO1InputFrontend.mm with -fobjc-arc."
#endif

namespace {
uint64_t advanceSequence(uint64_t &sequence) {
    // A session cannot realistically exhaust 64 bits, but zero remains reserved.
    if (++sequence == 0) ++sequence;
    return sequence;
}
uint32_t pressed(GCControllerButtonInput *button, uint32_t bit) {
    return button.isPressed ? bit : 0;
}
}

@interface BO1InputFrontend ()
- (void)publishTouch;
- (void)publishController;
- (void)selectAvailableController;
@end

@implementation BO1InputFrontend {
    BO1TouchHUD *_touchHUD;
    GCController *_controller;
    id _connectObserver;
    id _disconnectObserver;
    BOOL _suspended;
    BOOL _resetting;
    BOOL _controllerNeedsNeutral;
    BOOL _observedEditingLayout;
    uint64_t _touchSequence, _controllerSequence;
    uint64_t _observedTouchEpoch, _rumbleRevision;
}

- (instancetype)initWithFrame:(CGRect)frame preferences:(NSUserDefaults *)preferences {
    NSAssert(NSThread.isMainThread, @"Create input on the main thread");
    self = [super init];
    if (!self) return nil;
    _suspended = YES;
    _controllerNeedsNeutral = YES;
    IOS_SetInputSuspended(true);
    IOS_ResetInput();
    _touchHUD = [[BO1TouchHUD alloc] initWithFrame:frame preferences:preferences];
    _touchHUD.userInteractionEnabled = NO;
    __weak BO1InputFrontend *weakSelf = self;
    _touchHUD.inputDidChange = ^{ [weakSelf publishTouch]; };
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    _connectObserver = [center addObserverForName:GCControllerDidConnectNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            (void)note;
            [weakSelf selectAvailableController];
        }];
    _disconnectObserver = [center addObserverForName:GCControllerDidDisconnectNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            BO1InputFrontend *strongSelf = weakSelf;
            if (strongSelf && note.object == strongSelf->_controller) {
                [strongSelf detachController];
                [strongSelf selectAvailableController];
            }
        }];
    [self selectAvailableController];
    return self;
}

- (void)dealloc {
    if (_connectObserver) [NSNotificationCenter.defaultCenter removeObserver:_connectObserver];
    if (_disconnectObserver) [NSNotificationCenter.defaultCenter removeObserver:_disconnectObserver];
    _touchHUD.inputDidChange = nil;
    _controller.extendedGamepad.valueChangedHandler = nil;
    // The host owns frontend lifetime on the main thread and suspends before
    // destruction. Clearing the bridge also prevents orphaned held controls.
    IOS_SetInputSuspended(true);
    IOS_ResetInput();
}

- (BO1TouchHUD *)touchHUD { return _touchHUD; }
- (GCController *)controller { return _controller; }
- (BOOL)isSuspended { return _suspended; }

- (void)detachController {
    NSAssert(NSThread.isMainThread, @"Controller ownership is main-thread only");
    if (_controller && self.controllerRumbleHandler)
        self.controllerRumbleHandler(_controller, 0, 0);
    _controller.extendedGamepad.valueChangedHandler = nil;
    _controller = nil;
    _controllerNeedsNeutral = YES;
    IOS_ResetInputSource(IOS_INPUT_CONTROLLER);
    IOS_RequestControllerRumble(0, 0);
}

- (void)selectAvailableController {
    NSAssert(NSThread.isMainThread, @"Controller ownership is main-thread only");
    if (_controller) return;
    for (GCController *candidate in GCController.controllers) {
        if (!candidate.extendedGamepad) continue;
        _controller = candidate;
        _controllerNeedsNeutral = YES;
        IOS_ResetInputSource(IOS_INPUT_CONTROLLER);
        candidate.handlerQueue = dispatch_get_main_queue();
        __weak BO1InputFrontend *weakSelf = self;
        __weak GCController *weakController = candidate;
        candidate.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *profile, GCControllerElement *element) {
            (void)profile; (void)element;
            BO1InputFrontend *strongSelf = weakSelf;
            if (strongSelf && strongSelf->_controller == weakController)
                [strongSelf publishController];
        };
        [self publishController];
        break; // T5's verified native backend supports one local player.
    }
}

- (void)publishTouch {
    NSAssert(NSThread.isMainThread, @"Touch publication is main-thread only");
    if (_resetting || _suspended) return;
    if (_observedEditingLayout != _touchHUD.isEditingLayout) {
        _observedEditingLayout = _touchHUD.isEditingLayout;
        IOS_ResetInputSource(IOS_INPUT_TOUCH);
    }
    const uint64_t epoch = IOS_InputSourceEpoch(IOS_INPUT_TOUCH);
    if (_observedTouchEpoch != epoch) {
        // The engine can invalidate touch ownership during a menu transition.
        // Drop old gestures before stamping a newly valid token.
        _observedTouchEpoch = epoch;
        _resetting = YES;
        bool menu, captured;
        IOS_GetInputContext(&menu, &captured);
        _touchHUD.menuMode = menu;
        _touchHUD.capturedMenu = captured;
        [_touchHUD resetInput];
        _resetting = NO;
    }
    IOSInputFrame frame = [_touchHUD takeInputFrame];
    frame.epoch = epoch;
    frame.sequence = advanceSequence(_touchSequence);
    (void)IOS_SubmitInputFrame(&frame);
}

- (IOSInputFrame)controllerFrame {
    IOSInputFrame frame{};
    frame.source = IOS_INPUT_CONTROLLER;
    frame.epoch = IOS_InputSourceEpoch(IOS_INPUT_CONTROLLER);
    frame.sequence = advanceSequence(_controllerSequence);
    GCExtendedGamepad *pad = _controller.extendedGamepad;
    frame.connected = pad != nil;
    if (!pad) return frame;
    frame.buttons = pressed(pad.buttonA, IOS_PAD_JUMP) |
        pressed(pad.buttonB, IOS_PAD_STANCE) | pressed(pad.buttonX, IOS_PAD_USE_RELOAD) |
        pressed(pad.buttonY, IOS_PAD_SWAP) | pressed(pad.leftShoulder, IOS_PAD_TACTICAL) |
        pressed(pad.rightShoulder, IOS_PAD_LETHAL) | pressed(pad.leftThumbstickButton, IOS_PAD_SPRINT) |
        pressed(pad.rightThumbstickButton, IOS_PAD_MELEE) | pressed(pad.buttonMenu, IOS_PAD_MENU) |
        pressed(pad.buttonOptions, IOS_PAD_SCORES) | pressed(pad.dpad.up, IOS_PAD_UP) |
        pressed(pad.dpad.down, IOS_PAD_DOWN) | pressed(pad.dpad.left, IOS_PAD_LEFT) |
        pressed(pad.dpad.right, IOS_PAD_RIGHT);
    frame.leftTrigger = pad.leftTrigger.value;
    frame.rightTrigger = pad.rightTrigger.value;
    frame.moveX = pad.leftThumbstick.xAxis.value;
    frame.moveY = pad.leftThumbstick.yAxis.value;
    frame.lookX = pad.rightThumbstick.xAxis.value;
    frame.lookY = pad.rightThumbstick.yAxis.value;
    return frame;
}

- (void)publishController {
    NSAssert(NSThread.isMainThread, @"Controller publication is main-thread only");
    if (_resetting || _suspended) return;
    IOSInputFrame frame = [self controllerFrame];
    if (_controllerNeedsNeutral) {
        if (bo1ios::ControllerIsNeutral(frame)) _controllerNeedsNeutral = NO;
        else frame = bo1ios::NeutralControllerFrame(frame);
    }
    (void)IOS_SubmitInputFrame(&frame);
}

- (void)submitInputAtTimestamp:(CFTimeInterval)timestamp duration:(CFTimeInterval)duration {
    NSAssert(NSThread.isMainThread, @"Display input must run on the main thread");
    (void)timestamp; (void)duration;
    // Held axes are integrated by the actual engine with its own frame duration;
    // touch deltas are already distances and must not be multiplied by dt.
    if (_suspended) return;
    [self publishTouch];
    [self publishController];
    IOSRumbleRequest rumble{};
    IOS_GetControllerRumble(&rumble);
    if (_rumbleRevision != rumble.revision) {
        _rumbleRevision = rumble.revision;
        if (_controller && self.controllerRumbleHandler)
            self.controllerRumbleHandler(_controller, rumble.low, rumble.high);
    }
}

- (void)resetInput {
    NSAssert(NSThread.isMainThread, @"Reset input on the main thread");
    _resetting = YES;
    [_touchHUD resetInput];
    IOS_ResetInput();
    _observedTouchEpoch = IOS_InputSourceEpoch(IOS_INPUT_TOUCH);
    bool menu, captured;
    IOS_GetInputContext(&menu, &captured);
    _touchHUD.menuMode = menu;
    _touchHUD.capturedMenu = captured;
    _controllerNeedsNeutral = YES;
    _resetting = NO;
    if (_controller && self.controllerRumbleHandler)
        self.controllerRumbleHandler(_controller, 0, 0);
}

- (void)setSuspended:(BOOL)suspended {
    NSAssert(NSThread.isMainThread, @"Suspend input on the main thread");
    if (_suspended == suspended) return;
    _suspended = suspended;
    IOS_SetInputSuspended(suspended);
    [self resetInput];
    _touchHUD.userInteractionEnabled = !suspended;
    if (!suspended) {
        [self publishTouch];
        [self publishController];
    }
}

@end
