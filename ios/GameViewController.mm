#import "GameViewController.h"
#import "include/ios_platform_bridge.h"
#include "include/bo1_asset_gate.h"
#import <QuartzCore/QuartzCore.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <exception>
#include <pthread.h>

static constexpr size_t kBO1GameThreadStackSize = 64u * 1024u * 1024u;

@interface BO1MetalView : UIView
@end

@implementation BO1MetalView
+ (Class)layerClass { return CAMetalLayer.class; }
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.blackColor;
        self.multipleTouchEnabled = YES;
        self.contentScaleFactor = UIScreen.mainScreen.nativeScale;
        ((CAMetalLayer *)self.layer).framebufferOnly = YES;
    }
    return self;
}
@end

enum class BO1LaunchState { waitingForAssets, launching, running, finished, failed };

@interface BO1GameViewController ()
- (void)displayTick:(CADisplayLink *)link;
- (void)engineDidExit:(int)exitCode failure:(nullable NSString *)failure;
@end

// CADisplayLink retains its target. A weak proxy prevents a controller/link
// retain cycle without requiring the engine thread to manipulate UIKit.
@interface BO1DisplayLinkProxy : NSObject
@property(nonatomic, weak) BO1GameViewController *controller;
- (void)tick:(CADisplayLink *)link;
@end

@implementation BO1DisplayLinkProxy
- (void)tick:(CADisplayLink *)link { [self.controller displayTick:link]; }
@end

@interface BO1EngineLaunch : NSObject
@property(nonatomic, strong) id<BO1IOSHostServices> services;
@property(nonatomic, weak) BO1GameViewController *controller;
@end
@implementation BO1EngineLaunch
@end

static void *BO1RunGameThread(void *rawContext) {
    @autoreleasepool {
        BO1EngineLaunch *context = (__bridge_transfer BO1EngineLaunch *)rawContext;
        pthread_setname_np("BO1 game");
        int exitCode = -1;
        NSString *failure = nil;
        try {
            @try {
                char executable[] = "BlackOps1";
                char *argv[] = {executable, nullptr};
                exitCode = [context.services runEngineWithArgc:1 argv:argv];
            } @catch (NSException *exception) {
                failure = exception.reason ?: exception.name;
            }
        } catch (const std::exception &exception) {
            failure = [NSString stringWithUTF8String:exception.what()] ?: @"The engine raised a C++ exception.";
        } catch (...) {
            failure = @"The engine raised an unknown C++ exception.";
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [context.controller engineDidExit:exitCode failure:failure];
        });
    }
    return nullptr;
}

@implementation BO1GameViewController {
    id<BO1IOSHostServices> _services;
    NSURL *_gameDirectory;
    UIView *_touchHUD;
    UIScrollView *_setupPanel;
    UILabel *_status;
    UIButton *_checkFilesButton;
    UIButton *_downloadButton;
    CADisplayLink *_displayLink;
    UIViewController *_downloadController;
    BO1LaunchState _state;
    BOOL _applicationActive;
    BOOL _assetsReady;
    BOOL _launchAttempted;
    BOOL _downloadInProgress;
    BOOL _rendererNeedsDrain;
    BOOL _automaticLaunchAllowed;
    BOOL _ownsIdleTimer;
    BOOL _previousIdleTimerDisabled;
    NSUInteger _downloadGeneration;
}

- (instancetype)initWithHostServices:(id<BO1IOSHostServices>)services {
    NSParameterAssert(services);
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _services = services;
        _state = BO1LaunchState::waitingForAssets;
        _automaticLaunchAllowed = YES;
    }
    return self;
}

- (void)loadView {
    self.view = [[BO1MetalView alloc] initWithFrame:UIScreen.mainScreen.bounds];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self buildSetupPanel];

    NSError *error = nil;
    NSURL *documents = [NSFileManager.defaultManager URLForDirectory:NSDocumentDirectory
        inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:&error];
    if (documents) _gameDirectory = [documents URLByAppendingPathComponent:@"game" isDirectory:YES];
    if (!_gameDirectory || ![NSFileManager.defaultManager createDirectoryAtURL:_gameDirectory
        withIntermediateDirectories:YES attributes:nil error:&error]) {
        [self failWithMessage:error.localizedDescription ?: @"The game folder could not be created."];
    }
}

- (void)buildSetupPanel {
    _setupPanel = [UIScrollView new];
    _setupPanel.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1];
    _setupPanel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_setupPanel];

    UILabel *title = [UILabel new];
    title.text = @"BLACK OPS 1";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle1];
    title.adjustsFontForContentSizeCategory = YES;
    title.textColor = UIColor.whiteColor;
    title.textAlignment = NSTextAlignmentCenter;

    UILabel *instructions = [UILabel new];
    instructions.text = @"Copy your own Black Ops game files into Files → On My iPhone → Black Ops 1 → game. Keep the original folders, then tap Check Files.";
    instructions.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    instructions.adjustsFontForContentSizeCategory = YES;
    instructions.textColor = UIColor.whiteColor;
    instructions.numberOfLines = 0;

    _status = [UILabel new];
    _status.text = @"Waiting for game files.";
    _status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _status.adjustsFontForContentSizeCategory = YES;
    _status.textColor = [UIColor colorWithWhite:0.8 alpha:1];
    _status.numberOfLines = 0;
    _status.accessibilityIdentifier = @"bo1-launch-status";

    _checkFilesButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _checkFilesButton.configuration = [UIButtonConfiguration filledButtonConfiguration];
    [_checkFilesButton setTitle:@"Check Files" forState:UIControlStateNormal];
    [_checkFilesButton addTarget:self action:@selector(checkGameFilesFromUser) forControlEvents:UIControlEventTouchUpInside];
    _checkFilesButton.accessibilityIdentifier = @"bo1-check-files";

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[title, instructions, _status, _checkFilesButton]];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 16;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    if ([_services respondsToSelector:@selector(makeGameDownloadViewControllerForDirectory:completion:error:)]) {
        _downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _downloadButton.configuration = [UIButtonConfiguration borderedButtonConfiguration];
        [_downloadButton setTitle:@"Download Game Files" forState:UIControlStateNormal];
        [_downloadButton addTarget:self action:@selector(openGameDownloader) forControlEvents:UIControlEventTouchUpInside];
        _downloadButton.accessibilityIdentifier = @"bo1-download-files";
        [content addArrangedSubview:_downloadButton];
    }
    [_setupPanel addSubview:content];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_setupPanel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [_setupPanel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [_setupPanel.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [_setupPanel.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [content.leadingAnchor constraintEqualToAnchor:_setupPanel.contentLayoutGuide.leadingAnchor constant:24],
        [content.trailingAnchor constraintEqualToAnchor:_setupPanel.contentLayoutGuide.trailingAnchor constant:-24],
        [content.topAnchor constraintEqualToAnchor:_setupPanel.contentLayoutGuide.topAnchor constant:20],
        [content.bottomAnchor constraintEqualToAnchor:_setupPanel.contentLayoutGuide.bottomAnchor constant:-20],
        [content.widthAnchor constraintEqualToAnchor:_setupPanel.frameLayoutGuide.widthAnchor constant:-48],
        [_checkFilesButton.heightAnchor constraintGreaterThanOrEqualToConstant:44]
    ]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self checkGameFiles];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self updateDrawableMetrics];
    _touchHUD.frame = self.view.bounds;
    if (_assetsReady && !_launchAttempted) [self startEngineIfReady];
}

- (void)updateDrawableMetrics {
    UIScreen *screen = self.view.window.screen ?: UIScreen.mainScreen;
    CGFloat scale = screen.nativeScale;
    if (!std::isfinite(scale) || scale <= 0) scale = screen.scale;
    self.view.contentScaleFactor = scale;
    CAMetalLayer *layer = (CAMetalLayer *)self.view.layer;
    layer.contentsScale = scale;
    const double width = std::round(CGRectGetWidth(self.view.bounds) * scale);
    const double height = std::round(CGRectGetHeight(self.view.bounds) * scale);
    const uint32_t pixelsWide = std::isfinite(width) && width > 0 && width <= UINT32_MAX ? (uint32_t)width : 0;
    const uint32_t pixelsHigh = std::isfinite(height) && height > 0 && height <= UINT32_MAX ? (uint32_t)height : 0;
    layer.drawableSize = CGSizeMake(pixelsWide, pixelsHigh);
    const uint32_t refresh = (uint32_t)std::max<NSInteger>(1, std::min<NSInteger>(120, screen.maximumFramesPerSecond));
    IOS_UpdateDrawableMetrics(pixelsWide, pixelsHigh, refresh);
    if (_displayLink) {
        const float maximum = (float)refresh;
        _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(std::min(60.0f, maximum), maximum, maximum);
    }
}

- (void)checkGameFiles {
    NSAssert(NSThread.isMainThread, @"Game startup must run on the main thread.");
    if (_state != BO1LaunchState::waitingForAssets || !_gameDirectory || _downloadInProgress || self.presentedViewController) return;
    try {
        const bo1ios::AssetGateResult result = bo1ios::InspectStartupAssets(
            std::filesystem::path(_gameDirectory.fileSystemRepresentation));
        _assetsReady = result.present;
        if (!_assetsReady) {
            _status.text = [NSString stringWithUTF8String:result.message.c_str()] ?: @"Required startup files are missing.";
            return;
        }
    } catch (const std::exception &exception) {
        _assetsReady = NO;
        _status.text = [NSString stringWithFormat:@"Could not inspect game files: %s", exception.what()];
        return;
    }
    _status.text = !_automaticLaunchAllowed ? @"Startup files found. Tap Check Files when the full copy is ready." :
        (_applicationActive ? @"Starting Black Ops…" : @"Startup files found. Return to the app to start.");
    [self startEngineIfReady];
}

- (void)checkGameFilesFromUser {
    _automaticLaunchAllowed = YES;
    [self checkGameFiles];
}

- (void)startEngineIfReady {
    if (!_assetsReady || !_automaticLaunchAllowed || !_applicationActive || _launchAttempted || _downloadInProgress ||
        self.presentedViewController || !self.view.window || _state != BO1LaunchState::waitingForAssets) return;
    CAMetalLayer *layer = (CAMetalLayer *)self.view.layer;
    if (layer.drawableSize.width < 1 || layer.drawableSize.height < 1) return;
    _launchAttempted = YES;
    _state = BO1LaunchState::launching;
    _checkFilesButton.enabled = _downloadButton.enabled = NO;

    NSError *error = nil;
    if (![_services configureGraphicsForGameDirectory:_gameDirectory error:&error]) {
        [self failWithMessage:error.localizedDescription ?: @"The graphics environment could not be configured."];
        return;
    }
    IOS_RegisterMetalLayer((__bridge void *)layer);
    [self updateDrawableMetrics];
    _touchHUD = [_services makeTouchHUDWithFrame:self.view.bounds error:&error];
    if (!_touchHUD) {
        [self failWithMessage:error.localizedDescription ?: @"The native BO1 touch controls could not be created."];
        return;
    }
    _touchHUD.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _touchHUD.hidden = YES;
    [self.view addSubview:_touchHUD];
    [_services resetInput];
    _rendererNeedsDrain = YES; // Includes partial preparation if resume fails.
    if (![_services resumeEngineWithError:&error]) {
        [self failWithMessage:error.localizedDescription ?: @"The engine could not prepare for foreground operation."];
        return;
    }

    pthread_attr_t attributes;
    int result = pthread_attr_init(&attributes);
    if (result != 0) { [self failWithThreadError:result operation:@"create thread attributes"]; return; }
    result = pthread_attr_setstacksize(&attributes, kBO1GameThreadStackSize);
    if (result == 0) result = pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    if (result != 0) {
        pthread_attr_destroy(&attributes);
        [self failWithThreadError:result operation:@"configure the 64 MiB game thread"];
        return;
    }

    BO1EngineLaunch *context = [BO1EngineLaunch new];
    context.services = _services;
    context.controller = self;
    void *rawContext = (__bridge_retained void *)context;
    pthread_t thread;
    IOS_RequestScenePause(false);
    result = pthread_create(&thread, &attributes, BO1RunGameThread, rawContext);
    pthread_attr_destroy(&attributes);
    if (result != 0) {
        // Ownership transfers to the worker only after pthread_create succeeds.
        BO1EngineLaunch *unusedContext = (__bridge_transfer BO1EngineLaunch *)rawContext;
        (void)unusedContext;
        [self failWithThreadError:result operation:@"start the game thread"];
        return;
    }
    _state = BO1LaunchState::running;
    _setupPanel.hidden = YES;
    _touchHUD.hidden = NO;
    [self setGameIdleTimerDisabled:YES];

    BO1DisplayLinkProxy *proxy = [BO1DisplayLinkProxy new];
    proxy.controller = self;
    _displayLink = [CADisplayLink displayLinkWithTarget:proxy selector:@selector(tick:)];
    [self updateDrawableMetrics];
    [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)displayTick:(CADisplayLink *)link {
    if (!_applicationActive || _state != BO1LaunchState::running || IOS_IsScenePaused()) return;
    CFTimeInterval duration = link.targetTimestamp - link.timestamp;
    if (!std::isfinite(duration) || duration <= 0) duration = 1.0 / 60.0;
    duration = std::clamp(duration, 1.0 / 240.0, 0.1);
    [_services submitInputAtTimestamp:link.timestamp duration:duration];
}

- (void)setApplicationActive:(BOOL)active {
    NSAssert(NSThread.isMainThread, @"Application lifecycle must run on the main thread.");
    if (_applicationActive == active) return;
    _applicationActive = active;
    if (!active) {
        IOS_RequestScenePause(true);
        _displayLink.paused = YES;
        [_services resetInput];
        [self setGameIdleTimerDisabled:NO];
        if (_rendererNeedsDrain) {
            NSError *error = nil;
            if (![self drainEngineWithError:&error]) {
                [self failWithMessage:error.localizedDescription ?: @"The renderer could not finish pausing. Reopen the app to start again."];
            }
        }
        return;
    }
    if (_state == BO1LaunchState::running) {
        NSError *error = nil;
        [_services resetInput];
        _rendererNeedsDrain = YES; // Failed resume still requires cleanup.
        if (![_services resumeEngineWithError:&error]) {
            [self failWithMessage:error.localizedDescription ?: @"The renderer could not resume. Reopen the app to start again."];
            return;
        }
        IOS_RequestScenePause(false);
        _displayLink.paused = NO;
        [self setGameIdleTimerDisabled:YES];
    } else if (self.isViewLoaded) {
        [self checkGameFiles];
    }
}

- (void)setGameIdleTimerDisabled:(BOOL)disabled {
    if (disabled && !_ownsIdleTimer) {
        _previousIdleTimerDisabled = UIApplication.sharedApplication.idleTimerDisabled;
        UIApplication.sharedApplication.idleTimerDisabled = YES;
        _ownsIdleTimer = YES;
    } else if (!disabled && _ownsIdleTimer) {
        UIApplication.sharedApplication.idleTimerDisabled = _previousIdleTimerDisabled;
        _ownsIdleTimer = NO;
    }
}

- (void)failWithThreadError:(int)code operation:(NSString *)operation {
    [self failWithMessage:[NSString stringWithFormat:@"Could not %@: %s (%d). Reopen the app to retry.",
        operation, strerror(code), code]];
}

- (void)failWithMessage:(NSString *)message {
    IOS_RequestScenePause(true);
    NSError *drainError = nil;
    if (![self drainEngineWithError:&drainError]) {
        message = [message stringByAppendingFormat:@"\n%@", drainError.localizedDescription ?: @"Renderer suspension also reported an error."];
    }
    _state = BO1LaunchState::failed;
    _displayLink.paused = YES;
    [_services resetInput];
    [self setGameIdleTimerDisabled:NO];
    _touchHUD.hidden = YES;
    _setupPanel.hidden = NO;
    _status.text = message;
    _checkFilesButton.enabled = _downloadButton.enabled = NO;
}

- (BOOL)drainEngineWithError:(NSError **)error {
    if (!_rendererNeedsDrain) return YES;
    // A failed handshake still promises a closed submission gate. Avoid
    // repeating it recursively while reporting the original error to UIKit.
    _rendererNeedsDrain = NO;
    return [_services suspendAndDrainEngineWithError:error];
}

- (void)engineDidExit:(int)exitCode failure:(NSString *)failure {
    IOS_RequestScenePause(true);
    [_displayLink invalidate];
    _displayLink = nil;
    [_services resetInput];
    [self setGameIdleTimerDisabled:NO];
    NSError *drainError = nil;
    NSString *previousFailure = _state == BO1LaunchState::failed ? _status.text : nil;
    const BOOL drained = [self drainEngineWithError:&drainError];
    _state = failure || previousFailure || !drained ? BO1LaunchState::failed : BO1LaunchState::finished;
    _touchHUD.hidden = YES;
    _setupPanel.hidden = NO;
    _status.text = failure ?: previousFailure ?: (!drained ? (drainError.localizedDescription ?: @"The renderer reported an error while stopping.") : nil) ?:
        [NSString stringWithFormat:@"Black Ops exited with code %d. Close and reopen the app to start another session.", exitCode];
    _checkFilesButton.enabled = _downloadButton.enabled = NO;
}

- (void)openGameDownloader {
    if (_launchAttempted || _downloadInProgress || !_gameDirectory || self.presentedViewController ||
        ![_services respondsToSelector:@selector(makeGameDownloadViewControllerForDirectory:completion:error:)]) return;
    _downloadInProgress = YES;
    const NSUInteger generation = ++_downloadGeneration;
    _checkFilesButton.enabled = _downloadButton.enabled = NO;
    __weak BO1GameViewController *weakSelf = self;
    NSError *error = nil;
    UIViewController *controller = [_services makeGameDownloadViewControllerForDirectory:_gameDirectory
        completion:^(NSError *downloadError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                BO1GameViewController *strongSelf = weakSelf;
                if (!strongSelf || generation != strongSelf->_downloadGeneration) return;
                [strongSelf downloadFinishedWithError:downloadError];
            });
        } error:&error];
    if (!controller) {
        ++_downloadGeneration;
        _downloadInProgress = NO;
        _checkFilesButton.enabled = _downloadButton.enabled = YES;
        _status.text = error.localizedDescription ?: @"The game downloader could not open. You can copy files using the Files app.";
        return;
    }
    _downloadController = controller;
    controller.modalPresentationStyle = UIModalPresentationPageSheet;
    // The provider supplies Cancel and completes only after its writers stop.
    // A swipe must not bypass that handshake or overwrite the provider's delegate.
    controller.modalInPresentation = YES;
    [self presentViewController:controller animated:YES completion:nil];
}

- (void)downloadFinishedWithError:(NSError *)error {
    // The adapter's completion contract guarantees all file writes have stopped.
    _downloadInProgress = NO;
    ++_downloadGeneration;
    _checkFilesButton.enabled = _downloadButton.enabled = YES;
    void (^finished)(void) = ^{
        self->_downloadController = nil;
        self->_automaticLaunchAllowed = error == nil;
        if (error) {
            self->_assetsReady = NO;
            self->_status.text = error.localizedDescription;
        } else {
            // A completion message is not proof that an installation exists.
            [self checkGameFiles];
        }
    };
    if (_downloadController && self.presentedViewController == _downloadController) {
        [self dismissViewControllerAnimated:YES completion:finished];
    } else {
        finished();
    }
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return _state == BO1LaunchState::running; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

- (void)dealloc {
    [_displayLink invalidate];
    // The application delegate retains this controller throughout the session.
    // Never unregister the Metal layer while the adapter may still own VkSurfaces.
}

@end
