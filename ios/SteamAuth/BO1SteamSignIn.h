// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from BO2 iOS contributors; see UPSTREAM.md and LICENSE-EXCEPTION.md.
#pragma once
#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface BO1SteamSignIn : NSObject
+ (void)presentFromViewController:(UIViewController *)presenter;
+ (nullable NSString *)accountName;
@end
NS_ASSUME_NONNULL_END
