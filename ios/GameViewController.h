#pragma once

#import <UIKit/UIKit.h>
#import "include/BO1IOSHostServices.h"

NS_ASSUME_NONNULL_BEGIN

@interface BO1GameViewController : UIViewController
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithHostServices:(id<BO1IOSHostServices>)services NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithNibName:(nullable NSString *)name bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
- (void)setApplicationActive:(BOOL)active;
@end

NS_ASSUME_NONNULL_END
