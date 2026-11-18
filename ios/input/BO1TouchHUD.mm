#import "BO1TouchHUD.h"
#import <QuartzCore/QuartzCore.h>
#include <algorithm>
#include <cmath>

#if !__has_feature(objc_arc)
#error "Build BO1TouchHUD.mm with -fobjc-arc."
#endif

namespace {
NSString *const LayoutKey = @"BO1TouchHUD.layout.v1";
enum class ContactRole { Ignored, Move, Look, Button, Pointer, Edit };
constexpr CGFloat StickRadius = 52;
CGFloat clamp(CGFloat value, CGFloat low, CGFloat high) {
    return std::isfinite(value) ? std::max(low, std::min(value, high)) : low;
}
}

@interface BO1HUDControl : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, strong) UILabel *view;
@property(nonatomic) CGPoint initialPosition;
@property(nonatomic) CGPoint position;
@property(nonatomic) CGFloat diameter;
@property(nonatomic) uint32_t button;
@property(nonatomic) NSInteger trigger;
@property(nonatomic) BOOL movement;
@property(nonatomic) BOOL allowsLook;
@property(nonatomic, copy) NSString *gameplayTitle;
@property(nonatomic) BOOL menuControl;
@end
@implementation BO1HUDControl
@end

@interface BO1HUDContact : NSObject
@property(nonatomic) ContactRole role;
@property(nonatomic, strong, nullable) BO1HUDControl *control;
@property(nonatomic) CGPoint previous;
@property(nonatomic) CGPoint origin;
@property(nonatomic) CGPoint dragOffset;
@end
@implementation BO1HUDContact
@end

@interface BO1TouchHUD ()
- (void)notifyInputChanged;
@end

@implementation BO1TouchHUD {
    NSUserDefaults *_preferences;
    NSMutableArray<BO1HUDControl *> *_controls;
    NSMapTable<UITouch *, BO1HUDContact *> *_contacts;
    UIButton *_editButton;
    UIButton *_resetButton;
    UILabel *_editHelp;
    UIView *_stickBase;
    UIView *_stickKnob;
    BOOL _editingLayout;
    float _moveX, _moveY, _deltaX, _deltaY;
    BOOL _pointerValid, _pointerDown;
    CGPoint _pointer;
}
@synthesize menuMode = _menuMode;
@synthesize capturedMenu = _capturedMenu;

- (instancetype)initWithFrame:(CGRect)frame {
    return [self initWithFrame:frame preferences:NSUserDefaults.standardUserDefaults];
}

- (instancetype)initWithFrame:(CGRect)frame preferences:(NSUserDefaults *)preferences {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _preferences = preferences;
    _contacts = [NSMapTable strongToStrongObjectsMapTable];
    _controls = [NSMutableArray array];
    _menuMode = YES;
    self.backgroundColor = UIColor.clearColor;
    self.multipleTouchEnabled = YES;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    [self addControl:@"move" title:@"MOVE" position:CGPointMake(.17, .76) size:104 button:0 trigger:0 movement:YES look:NO];
    [self addControl:@"fire" title:@"FIRE" position:CGPointMake(.89, .39) size:64 button:0 trigger:2 movement:NO look:YES];
    [self addControl:@"ads" title:@"ADS" position:CGPointMake(.74, .42) size:54 button:0 trigger:1 movement:NO look:YES];
    [self addControl:@"jump" title:@"JUMP" position:CGPointMake(.94, .65) size:54 button:IOS_PAD_JUMP trigger:0 movement:NO look:YES];
    [self addControl:@"stance" title:@"CROUCH\nhold PRONE" position:CGPointMake(.84, .83) size:58 button:IOS_PAD_STANCE trigger:0 movement:NO look:YES];
    [self addControl:@"use" title:@"RELOAD\nhold USE" position:CGPointMake(.71, .80) size:58 button:IOS_PAD_USE_RELOAD trigger:0 movement:NO look:YES];
    [self addControl:@"swap" title:@"SWAP" position:CGPointMake(.60, .91) size:44 button:IOS_PAD_SWAP trigger:0 movement:NO look:YES];
    [self addControl:@"melee" title:@"MELEE" position:CGPointMake(.94, .91) size:44 button:IOS_PAD_MELEE trigger:0 movement:NO look:YES];
    [self addControl:@"sprint" title:@"SPRINT" position:CGPointMake(.18, .43) size:48 button:IOS_PAD_SPRINT trigger:0 movement:NO look:NO];
    [self addControl:@"lethal" title:@"FRAG" position:CGPointMake(.72, .17) size:44 button:IOS_PAD_LETHAL trigger:0 movement:NO look:NO];
    [self addControl:@"tactical" title:@"TACTICAL" position:CGPointMake(.61, .17) size:48 button:IOS_PAD_TACTICAL trigger:0 movement:NO look:NO];
    [self addControl:@"menu" title:@"MENU" position:CGPointMake(.94, .08) size:44 button:IOS_PAD_MENU trigger:0 movement:NO look:NO];
    [self addControl:@"scores" title:@"SCORES" position:CGPointMake(.83, .08) size:44 button:IOS_PAD_SCORES trigger:0 movement:NO look:NO];
    [self addControl:@"up" title:@"1 ↑" position:CGPointMake(.43, .58) size:44 button:IOS_PAD_UP trigger:0 movement:NO look:NO];
    [self addControl:@"left" title:@"3 ←" position:CGPointMake(.36, .75) size:44 button:IOS_PAD_LEFT trigger:0 movement:NO look:NO];
    [self addControl:@"right" title:@"4 →" position:CGPointMake(.50, .75) size:44 button:IOS_PAD_RIGHT trigger:0 movement:NO look:NO];
    [self addControl:@"down" title:@"2 ↓" position:CGPointMake(.43, .91) size:44 button:IOS_PAD_DOWN trigger:0 movement:NO look:NO];
    [self loadLayout];

    _stickBase = [self circleWithDiameter:StickRadius * 2 alpha:.15];
    _stickKnob = [self circleWithDiameter:38 alpha:.40];
    [self addSubview:_stickBase];
    [self addSubview:_stickKnob];
    _stickBase.hidden = _stickKnob.hidden = YES;

    _editButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_editButton setTitle:@"Edit controls" forState:UIControlStateNormal];
    [_editButton addTarget:self action:@selector(toggleLayoutEditing) forControlEvents:UIControlEventTouchUpInside];
    _editButton.accessibilityLabel = @"Edit touch control positions";
    [self addSubview:_editButton];
    _resetButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_resetButton setTitle:@"Reset layout" forState:UIControlStateNormal];
    [_resetButton addTarget:self action:@selector(resetLayout) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_resetButton];
    for (UIButton *button in @[_editButton, _resetButton]) {
        button.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:.55];
        button.tintColor = UIColor.whiteColor;
        button.layer.cornerRadius = 9;
        button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    }
    _editHelp = [UILabel new];
    _editHelp.text = @"Drag controls, then tap Done.";
    _editHelp.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    _editHelp.textColor = UIColor.whiteColor;
    _editHelp.textAlignment = NSTextAlignmentCenter;
    _editHelp.numberOfLines = 2;
    _editHelp.userInteractionEnabled = NO;
    [self addSubview:_editHelp];
    [self updateVisibility];
    return self;
}

- (UIView *)circleWithDiameter:(CGFloat)diameter alpha:(CGFloat)alpha {
    UIView *view = [[UIView alloc] initWithFrame:CGRectMake(0, 0, diameter, diameter)];
    view.userInteractionEnabled = NO;
    view.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:alpha];
    view.layer.borderColor = [UIColor.whiteColor colorWithAlphaComponent:.6].CGColor;
    view.layer.borderWidth = 1;
    view.layer.cornerRadius = diameter / 2;
    return view;
}

- (void)addControl:(NSString *)identifier title:(NSString *)title position:(CGPoint)position
              size:(CGFloat)size button:(uint32_t)button trigger:(NSInteger)trigger
          movement:(BOOL)movement look:(BOOL)look {
    BO1HUDControl *control = [BO1HUDControl new];
    control.identifier = identifier;
    control.position = control.initialPosition = position;
    control.diameter = size;
    control.button = button;
    control.trigger = trigger;
    control.movement = movement;
    control.allowsLook = look;
    control.gameplayTitle = title;
    control.menuControl = (button & (IOS_PAD_UP | IOS_PAD_DOWN | IOS_PAD_LEFT | IOS_PAD_RIGHT | IOS_PAD_JUMP | IOS_PAD_STANCE)) != 0;
    UILabel *label = [UILabel new];
    label.text = title;
    label.font = [UIFont systemFontOfSize:movement ? 13 : 10 weight:UIFontWeightBold];
    label.numberOfLines = 2;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = UIColor.whiteColor;
    label.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:.30];
    label.layer.borderWidth = 1;
    label.layer.borderColor = [UIColor.whiteColor colorWithAlphaComponent:.50].CGColor;
    label.clipsToBounds = YES;
    label.userInteractionEnabled = NO;
    label.accessibilityLabel = title;
    control.view = label;
    [_controls addObject:control];
    [self addSubview:label];
}

- (CGRect)usableRect {
    CGRect rect = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    rect = CGRectInset(rect, 6, 6);
    if (rect.size.width < 1 || rect.size.height < 1) return self.bounds;
    return rect;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    const CGRect rect = [self usableRect];
    for (BO1HUDControl *control in _controls) {
        const CGFloat radius = control.diameter / 2;
        const CGFloat x = clamp(rect.origin.x + control.position.x * rect.size.width,
                                CGRectGetMinX(rect) + radius, CGRectGetMaxX(rect) - radius);
        const CGFloat y = clamp(rect.origin.y + control.position.y * rect.size.height,
                                CGRectGetMinY(rect) + radius, CGRectGetMaxY(rect) - radius);
        control.view.frame = CGRectMake(x - radius, y - radius, control.diameter, control.diameter);
        control.view.layer.cornerRadius = radius;
    }
    _editButton.frame = CGRectMake(CGRectGetMinX(rect), CGRectGetMinY(rect), 108, 44);
    _resetButton.frame = CGRectMake(CGRectGetMinX(rect) + 116, CGRectGetMinY(rect), 108, 44);
    _editHelp.frame = CGRectMake(CGRectGetMinX(rect) + 232, CGRectGetMinY(rect),
                                 std::max<CGFloat>(0, rect.size.width - 360), 44);
}

- (void)loadLayout {
    NSDictionary *saved = [_preferences dictionaryForKey:LayoutKey];
    for (BO1HUDControl *control in _controls) {
        id item = saved[control.identifier];
        if (![item isKindOfClass:NSDictionary.class]) continue;
        id x = item[@"x"], y = item[@"y"];
        if (![x isKindOfClass:NSNumber.class] || ![y isKindOfClass:NSNumber.class]) continue;
        const double px = [x doubleValue], py = [y doubleValue];
        if (std::isfinite(px) && std::isfinite(py))
            control.position = CGPointMake(clamp(px, 0, 1), clamp(py, 0, 1));
    }
}

- (void)saveLayout {
    NSMutableDictionary *saved = [NSMutableDictionary dictionary];
    for (BO1HUDControl *control in _controls)
        saved[control.identifier] = @{@"x": @(control.position.x), @"y": @(control.position.y)};
    [_preferences setObject:saved forKey:LayoutKey];
}

- (void)resetLayout {
    [self resetInput];
    for (BO1HUDControl *control in _controls) control.position = control.initialPosition;
    [_preferences removeObjectForKey:LayoutKey];
    [self setNeedsLayout];
}

- (BOOL)isEditingLayout { return _editingLayout; }

- (void)toggleLayoutEditing {
    [self resetInput];
    _editingLayout = !_editingLayout;
    if (!_editingLayout) [self saveLayout];
    [_editButton setTitle:_editingLayout ? @"Done" : @"Edit controls" forState:UIControlStateNormal];
    [self updateVisibility];
    [self notifyInputChanged];
}

- (void)setMenuMode:(BOOL)menuMode {
    if (_menuMode == menuMode) return;
    _menuMode = menuMode;
    if (_editingLayout) [self saveLayout];
    _editingLayout = NO;
    [_editButton setTitle:@"Edit controls" forState:UIControlStateNormal];
    [self resetInput];
    [self updateVisibility];
}

- (void)setCapturedMenu:(BOOL)capturedMenu {
    if (_capturedMenu == capturedMenu) return;
    _capturedMenu = capturedMenu;
    [self resetInput];
}

- (void)updateVisibility {
    for (BO1HUDControl *control in _controls) {
        control.view.hidden = _menuMode && !control.menuControl;
        if (_menuMode && control.button == IOS_PAD_JUMP) control.view.text = @"SELECT";
        else if (_menuMode && control.button == IOS_PAD_STANCE) control.view.text = @"BACK";
        else if (_menuMode && control.button == IOS_PAD_UP) control.view.text = @"↑";
        else if (_menuMode && control.button == IOS_PAD_DOWN) control.view.text = @"↓";
        else if (_menuMode && control.button == IOS_PAD_LEFT) control.view.text = @"←";
        else if (_menuMode && control.button == IOS_PAD_RIGHT) control.view.text = @"→";
        else control.view.text = control.gameplayTitle;
    }
    _editButton.hidden = _menuMode;
    _resetButton.hidden = _menuMode || !_editingLayout;
    _editHelp.hidden = _menuMode || !_editingLayout;
    if (_menuMode || _editingLayout) _stickBase.hidden = _stickKnob.hidden = YES;
    [self updateButtonAppearance];
}

- (void)updateButtonAppearance {
    for (BO1HUDControl *control in _controls) {
        BOOL pressed = NO;
        for (BO1HUDContact *contact in _contacts.objectEnumerator)
            if (contact.control == control && contact.role == ContactRole::Button) pressed = YES;
        control.view.backgroundColor = [(pressed ? UIColor.systemOrangeColor : UIColor.blackColor)
            colorWithAlphaComponent:pressed ? .55 : (_editingLayout ? .60 : .30)];
    }
}

- (BOOL)hasContactRole:(ContactRole)role {
    for (BO1HUDContact *contact in _contacts.objectEnumerator)
        if (contact.role == role) return YES;
    return NO;
}

- (BO1HUDControl *)controlAtPoint:(CGPoint)point {
    for (BO1HUDControl *control in _controls.reverseObjectEnumerator)
        if (!control.view.hidden && CGRectContainsPoint(control.view.frame, point)) return control;
    return nil;
}

- (void)updatePointer:(CGPoint)point {
    _pointerValid = YES;
    _pointer = CGPointMake(clamp(point.x / std::max<CGFloat>(1, self.bounds.size.width), 0, 1),
                           clamp(point.y / std::max<CGFloat>(1, self.bounds.size.height), 0, 1));
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    for (UITouch *touch in touches) {
        CGPoint point = [touch locationInView:self];
        BO1HUDContact *contact = [BO1HUDContact new];
        contact.previous = contact.origin = point;
        contact.role = ContactRole::Ignored;
        if (_menuMode) {
            BO1HUDControl *control = [self controlAtPoint:point];
            if (control && control.menuControl) {
                contact.role = ContactRole::Button;
                contact.control = control;
            } else if (_capturedMenu && point.x >= self.bounds.size.width * .4 && ![self hasContactRole:ContactRole::Look]) {
                contact.role = ContactRole::Look;
            } else if (!_capturedMenu && ![self hasContactRole:ContactRole::Pointer]) {
                contact.role = ContactRole::Pointer;
                [self updatePointer:point];
                _pointerDown = YES;
            }
        } else {
            BO1HUDControl *control = [self controlAtPoint:point];
            contact.control = control;
            if (_editingLayout && control) {
                contact.role = ContactRole::Edit;
                contact.dragOffset = CGPointMake(control.view.center.x - point.x, control.view.center.y - point.y);
            } else if (!_editingLayout) {
                if (control && !control.movement) contact.role = ContactRole::Button;
                else if ((control.movement || point.x < self.bounds.size.width * .45) &&
                         ![self hasContactRole:ContactRole::Move]) {
                    contact.role = ContactRole::Move;
                    _stickBase.center = _stickKnob.center = point;
                    _stickBase.hidden = _stickKnob.hidden = NO;
                } else if (point.x >= self.bounds.size.width * .45 && ![self hasContactRole:ContactRole::Look])
                    contact.role = ContactRole::Look;
            }
        }
        [_contacts setObject:contact forKey:touch];
    }
    [self updateButtonAppearance];
    [self notifyInputChanged];
}

- (void)updateContact:(BO1HUDContact *)contact point:(CGPoint)point {
    if (contact.role == ContactRole::Move) {
        CGFloat x = (point.x - contact.origin.x) / StickRadius;
        CGFloat y = (contact.origin.y - point.y) / StickRadius;
        const CGFloat length = std::hypot(x, y);
        if (length > 1) { x /= length; y /= length; }
        _moveX = (float)x; _moveY = (float)y;
        _stickKnob.center = CGPointMake(contact.origin.x + x * StickRadius, contact.origin.y - y * StickRadius);
    } else if (contact.role == ContactRole::Look ||
               (contact.role == ContactRole::Button && contact.control.allowsLook && !_menuMode)) {
        _deltaX += (float)((point.x - contact.previous.x) * 1280 / std::max<CGFloat>(1, self.bounds.size.width));
        _deltaY += (float)((point.y - contact.previous.y) * 720 / std::max<CGFloat>(1, self.bounds.size.height));
    } else if (contact.role == ContactRole::Pointer) [self updatePointer:point];
    else if (contact.role == ContactRole::Edit) {
        const CGRect rect = [self usableRect];
        const CGFloat radius = contact.control.diameter / 2;
        const CGFloat x = clamp(point.x + contact.dragOffset.x, CGRectGetMinX(rect) + radius, CGRectGetMaxX(rect) - radius);
        const CGFloat y = clamp(point.y + contact.dragOffset.y, CGRectGetMinY(rect) + radius, CGRectGetMaxY(rect) - radius);
        contact.control.position = CGPointMake(clamp((x - rect.origin.x) / std::max<CGFloat>(1, rect.size.width), 0, 1),
                                                clamp((y - rect.origin.y) / std::max<CGFloat>(1, rect.size.height), 0, 1));
        [self setNeedsLayout];
    }
    contact.previous = point;
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    for (UITouch *touch in touches) {
        BO1HUDContact *contact = [_contacts objectForKey:touch];
        if (contact) [self updateContact:contact point:[touch locationInView:self]];
    }
    [self notifyInputChanged];
}

- (void)finishTouches:(NSSet<UITouch *> *)touches cancelled:(BOOL)cancelled {
    for (UITouch *touch in touches) {
        BO1HUDContact *contact = [_contacts objectForKey:touch];
        if (!contact) continue;
        if (!cancelled) [self updateContact:contact point:[touch locationInView:self]];
        if (contact.role == ContactRole::Move) {
            _moveX = _moveY = 0;
            _stickBase.hidden = _stickKnob.hidden = YES;
        } else if (contact.role == ContactRole::Pointer) _pointerDown = NO;
        [_contacts removeObjectForKey:touch];
    }
    [self updateButtonAppearance];
    [self notifyInputChanged];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    [self finishTouches:touches cancelled:NO];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    [self finishTouches:touches cancelled:YES];
}

- (IOSInputFrame)takeInputFrame {
    NSAssert(NSThread.isMainThread, @"Touch input must be sampled on the main thread");
    IOSInputFrame frame{};
    frame.source = IOS_INPUT_TOUCH;
    frame.connected = YES;
    if (!_editingLayout) {
        frame.moveX = _moveX; frame.moveY = _moveY;
        frame.deltaX = _deltaX; frame.deltaY = _deltaY;
        frame.pointerValid = _menuMode && !_capturedMenu && _pointerValid;
        frame.pointerDown = _menuMode && !_capturedMenu && _pointerDown;
        frame.pointerX = (float)_pointer.x; frame.pointerY = (float)_pointer.y;
        for (BO1HUDContact *contact in _contacts.objectEnumerator) {
            if (contact.role != ContactRole::Button) continue;
            frame.buttons |= contact.control.button;
            if (contact.control.trigger == 1) frame.leftTrigger = 1;
            if (contact.control.trigger == 2) frame.rightTrigger = 1;
        }
    }
    _deltaX = _deltaY = 0;
    return frame;
}

- (void)resetInput {
    [_contacts removeAllObjects];
    _moveX = _moveY = _deltaX = _deltaY = 0;
    _pointerValid = _pointerDown = NO;
    _stickBase.hidden = _stickKnob.hidden = YES;
    [self updateButtonAppearance];
    [self notifyInputChanged];
}

- (void)notifyInputChanged { if (self.inputDidChange) self.inputDidChange(); }

@end
