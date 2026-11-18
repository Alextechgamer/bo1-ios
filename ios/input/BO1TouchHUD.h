#import <UIKit/UIKit.h>
#include "ios_input_bridge.h"

NS_ASSUME_NONNULL_BEGIN

// UIKit-only producer. The host's CADisplayLink owns timing; this view creates
// no timer and never reads engine objects or writes usercmd memory.
@interface BO1TouchHUD : UIView
@property(nonatomic, copy, nullable) void (^inputDidChange)(void);
@property(nonatomic, getter=isMenuMode) BOOL menuMode;
@property(nonatomic, getter=isCapturedMenu) BOOL capturedMenu;
@property(nonatomic, readonly, getter=isEditingLayout) BOOL editingLayout;
- (instancetype)initWithFrame:(CGRect)frame preferences:(NSUserDefaults *)preferences NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(CGRect)frame;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
// Snapshot held controls and consume relative motion accumulated by this view.
// The frontend supplies the source epoch and sequence immediately afterward.
- (IOSInputFrame)takeInputFrame;
- (void)resetInput;
- (void)resetLayout;
@end

NS_ASSUME_NONNULL_END
