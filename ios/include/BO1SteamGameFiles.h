#pragma once
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
// Real Steam authentication and content UI. The factory never calls completion
// synchronously. Done/Cancel drains joined filesystem tasks before completion
// on the main queue; the caller then dismisses and rechecks the game directory.
@interface BO1SteamGameFiles : NSObject
+ (UIViewController *)makeViewControllerForDirectory:(NSURL *)directory
                                        completion:(void (^)(NSError * _Nullable error))completion;
// Call from applicationDidEnterBackground, not applicationWillResignActive.
// Pauses content writes without cancelling a Steam Guard/QR sign-in flow.
+ (void)applicationDidEnterBackground;
@end
NS_ASSUME_NONNULL_END
