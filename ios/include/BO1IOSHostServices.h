#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Implemented by the real BO1 engine/HUD/downloader integration. This header
// deliberately supplies no fallback implementation: the app must not report a
// working engine, touch controls, downloader or renderer without those pieces.
// Unless stated otherwise, every method below is called on the UIKit main
// thread. The same object is retained for the entire native-engine session.
@protocol BO1IOSHostServices <NSObject>

// Set the engine's Documents/game base path and graphics environment before
// creating any Vulkan instance/device, renderer workers, or audio device.
- (BOOL)configureGraphicsForGameDirectory:(NSURL *)gameDirectory
                                    error:(NSError * _Nullable * _Nullable)error;

// Return actual controls that feed the native BO1 input bridge. A nil result is
// a launch failure. Do not use BO2's guest-memory offsets or dynamic-mode ABI.
// The controller owns the display link; this HUD must not start a second one.
- (nullable UIView *)makeTouchHUDWithFrame:(CGRect)frame
                                    error:(NSError * _Nullable * _Nullable)error;

// Publish held touch/controller state and consume accumulated look deltas once
// per display tick. The implementation must serialize its engine-side input
// consumer. timestamp and duration are in seconds, from CADisplayLink.
- (void)submitInputAtTimestamp:(CFTimeInterval)timestamp duration:(CFTimeInterval)duration;
// Must be safe before graphics/engine initialization and after engine return.
- (void)resetInput;

// The ONLY method called on the dedicated 64 MiB-stack pthread. argv and its
// strings remain valid for the whole call. Adapt to the engine's actual entry
// point; do not introduce a stub Sys_Main. Stack capacity does not guarantee
// the below-4-GiB stack addressing expected by upstream ptr32 code; the adapter
// must resolve that engine ABI requirement before entry. Native exit/crash
// semantics remain its responsibility. Returning ends this process's one game
// session; UIKit never launches the engine again in the same process.
- (int)runEngineWithArgc:(int)argc argv:(char * _Nonnull const * _Nonnull)argv;

// Lifecycle handshake, including the race where the pthread exists but the
// renderer has not initialized yet. IOS_RequestScenePause(true) is set first.
// Stop/gate ALL engine render workers and future GPU submissions, drain work
// already submitted, and pause audio before returning. vkDeviceWaitIdle alone
// is insufficient. The submission gate MUST remain closed even when reporting
// a device error. Do not synchronously dispatch to the main queue, which is
// making this call. Keep this bounded to avoid the iOS lifecycle watchdog.
- (BOOL)suspendAndDrainEngineWithError:(NSError * _Nullable * _Nullable)error;

// Prepare audio/render resources for foreground operation. This may be called
// before the engine pthread is launched. No background GPU work is permitted.
// The shared scene-pause flag stays true during this call and is cleared only
// after success; engine workers must also honor that flag at a safe boundary.
// On failure keep every submission gate closed; report the partial setup error.
- (BOOL)resumeEngineWithError:(NSError * _Nullable * _Nullable)error;

@optional

// Provide a real BO1 download flow, with the correct account/ownership checks,
// AppIDs and target directory. No BO2 downloader is selected implicitly.
// Call completion on the main queue after completion, cancellation or error.
// Supply a visible Cancel control, stop all writes, then invoke completion
// with a cancellation error. The host disables interactive sheet dismissal,
// preserving the provider's own presentation delegate. Stop any writes before
// invoking completion so engine startup cannot race a repair/download. UIKit
// rechecks files after success; cancellation/errors require an explicit Check
// Files action before launch. Return nil with an error if UI creation fails.
// Do not invoke completion synchronously from this creation method.
- (nullable UIViewController *)makeGameDownloadViewControllerForDirectory:(NSURL *)gameDirectory
                                                              completion:(void (^)(NSError * _Nullable error))completion
                                                                   error:(NSError * _Nullable * _Nullable)error;

@end

// Required, strongly linked factory supplied by the engine integration.
// Return nil only with an initialization failure, never a silent stub object.
FOUNDATION_EXPORT id<BO1IOSHostServices> _Nullable
BO1IOSCreateHostServices(NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
