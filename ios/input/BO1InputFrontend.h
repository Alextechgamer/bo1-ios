#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import "BO1TouchHUD.h"

NS_ASSUME_NONNULL_BEGIN

// One frontend per running host. Owns the selected extended gamepad's input
// callback; all methods and callbacks run on the main thread. The engine-side
// bridge is independent and is the only cross-thread communication path.
@interface BO1InputFrontend : NSObject
@property(nonatomic, strong, readonly) BO1TouchHUD *touchHUD;
@property(nonatomic, strong, readonly, nullable) GCController *controller;
@property(nonatomic, readonly, getter=isSuspended) BOOL suspended;
// Optional hardware output supplied by a controller haptics adapter. Called on
// the main thread, including zero on reset/disconnect. No haptics are synthesized
// when this is nil; input support does not require vibration support.
@property(nonatomic, copy, nullable) void (^controllerRumbleHandler)(GCController *controller, float low, float high);
- (instancetype)initWithFrame:(CGRect)frame preferences:(NSUserDefaults *)preferences NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// Delegate BO1IOSHostServices submitInputAtTimestamp:duration: here. Button
// callbacks also publish immediately so taps between display ticks are retained.
- (void)submitInputAtTimestamp:(CFTimeInterval)timestamp duration:(CFTimeInterval)duration;
- (void)resetInput;
// Starts suspended. A real host adapter calls NO after engine resume succeeds,
// and YES before it stops/drains rendering. This does not synchronize the GPU.
- (void)setSuspended:(BOOL)suspended;
@end

NS_ASSUME_NONNULL_END
