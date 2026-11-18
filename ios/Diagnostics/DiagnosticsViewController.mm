#import "DiagnosticsViewController.h"
#import "DiagnosticsProbes.h"
#import "BO1InputFrontend.h"
#import "BO1SteamGameFiles.h"
#import <AVFoundation/AVFoundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include "ios_platform_bridge.h"
#include "native_audio.h"
#include <SDL2/SDL.h>
#include <TargetConditionals.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <memory>
#include <sys/utsname.h>
#include <vector>

#ifndef BO1_DIAGNOSTICS_SOURCE_REVISION
#define BO1_DIAGNOSTICS_SOURCE_REVISION "unknown"
#endif
#ifndef BO1_DIAGNOSTICS_BUILD_UTC
#define BO1_DIAGNOSTICS_BUILD_UTC "unknown"
#endif

@interface BO1DiagnosticMetalView : UIView
@end
@implementation BO1DiagnosticMetalView
+ (Class)layerClass { return CAMetalLayer.class; }
@end

@interface BO1DiagnosticsViewController (DisplayTick)
- (void)displayTick:(CADisplayLink *)link;
@end
@interface BO1DiagnosticsViewController ()
- (void)updateInputState;
- (void)updateButtons;
- (void)refreshReport;
- (void)stopAudio:(NSString *)message;
- (void)pollAudio;
@end
@interface BO1DiagnosticDisplayTarget : NSObject
@property(nonatomic, weak) BO1DiagnosticsViewController *owner;
- (void)tick:(CADisplayLink *)link;
@end
@implementation BO1DiagnosticDisplayTarget
- (void)tick:(CADisplayLink *)link { [self.owner displayTick:link]; }
@end

namespace {
constexpr int ToneVoice = 0;
constexpr unsigned ToneRate = 48000;
constexpr unsigned ToneFrames = ToneRate * 35 / 100;
NSString *sourceName(IOSInputSource source) {
    switch (source) {
        case IOS_INPUT_TOUCH: return @"touch";
        case IOS_INPUT_CONTROLLER: return @"controller";
        default: return @"none";
    }
}
void setTitle(UIButton *button, NSString *title) {
    UIButtonConfiguration *configuration = [button.configuration copy];
    configuration.title = title;
    button.configuration = configuration;
}
}

@implementation BO1DiagnosticsViewController {
    UISegmentedControl *_mode;
    UIButton *_runButton, *_audioButton, *_shareButton, *_filesButton;
    UIViewController *_gameFilesController;
    UIStackView *_actions;
    UITextView *_reportView;
    UILabel *_liveInput;
    BO1DiagnosticMetalView *_metalView;
    BO1InputFrontend *_input;
    CADisplayLink *_displayLink;
    BO1DiagnosticDisplayTarget *_displayTarget;
    NSTimer *_audioTimer;
    id _audioInterruptionObserver, _audioRouteObserver;
    dispatch_queue_t _probeQueue;
    std::shared_ptr<std::atomic_bool> _cancelled;
    BOOL _active, _visible, _probeRunning, _audioOpen, _tonePlaying;
    CFTimeInterval _toneStarted, _lastDisplayTime, _lastLabelUpdate, _lastButtonEvent;
    uint64_t _sampleCount, _controlSessions, _deactivations;
    uint32_t _recentPressed, _recentReleased, _seenButtons;
    float _maxMove, _maxLook, _maxTrigger, _maxTouchDelta, _pendingDeltaX, _pendingDeltaY;
    double _observedHz;
    IOSInputSample _lastSample;
    std::vector<int16_t> _toneSamples;
    NSString *_probeReport, *_audioReport, *_controllerName, *_lastRunDate;
}

- (UIButton *)button:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *configuration = [UIButtonConfiguration tintedButtonConfiguration];
    configuration.title = title;
    configuration.buttonSize = UIButtonConfigurationSizeSmall;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    button.configuration = configuration;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = @"BO1 Port Diagnostics";
    _probeQueue = dispatch_queue_create("com.alextechgamer.bo1ios.diagnostics.checks", DISPATCH_QUEUE_SERIAL);
    _probeReport = @"Checks have not run. Tap Run checks to query the real Vulkan/Metal bridge and process address layout.";
    _audioReport = @"Not tested. Test audio plays one quiet 0.35-second PCM tone. No sound plays automatically.";
    _controllerName = @"No extended gamepad detected";
    _lastSample.movementSource = _lastSample.lookSource = IOS_INPUT_NO_SOURCE;

    UILabel *title = [UILabel new];
    title.text = self.title;
    title.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleTitle2]
        scaledFontForFont:[UIFont systemFontOfSize:20 weight:UIFontWeightSemibold] maximumPointSize:28];
    title.adjustsFontForContentSizeCategory = YES;
    title.accessibilityTraits |= UIAccessibilityTraitHeader;
    UILabel *scope = [UILabel new];
    scope.text = @"Download game files and test platform components. Game engine unavailable.";
    scope.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleFootnote]
        scaledFontForFont:[UIFont systemFontOfSize:13] maximumPointSize:18];
    scope.textColor = UIColor.secondaryLabelColor;
    scope.numberOfLines = 0;
    scope.adjustsFontForContentSizeCategory = YES;

    _mode = [[UISegmentedControl alloc] initWithItems:@[@"Report", @"Control test"]];
    _mode.selectedSegmentIndex = 0;
    _mode.accessibilityLabel = @"Diagnostics view";
    [_mode addTarget:self action:@selector(modeChanged) forControlEvents:UIControlEventValueChanged];
    [_mode.heightAnchor constraintGreaterThanOrEqualToConstant:36].active = YES;
    _runButton = [self button:@"Run checks" action:@selector(runChecks)];
    _audioButton = [self button:@"Test audio" action:@selector(testAudio)];
    _shareButton = [self button:@"Share report" action:@selector(shareReport)];
    _filesButton = [self button:@"Game files" action:@selector(openGameFiles)];
    _filesButton.accessibilityIdentifier = @"bo1-steam-game-files";
    _filesButton.accessibilityHint = @"Sign in to Steam and download your Black Ops game files.";
    _audioButton.accessibilityHint = @"Plays a brief, low-volume tone through the native audio mixer.";
    _shareButton.accessibilityHint = @"Opens the system share sheet. Nothing is shared automatically.";
    _actions = [[UIStackView alloc] initWithArrangedSubviews:@[_filesButton, _runButton, _audioButton, _shareButton]];
    _actions.spacing = 8;
    _actions.distribution = UIStackViewDistributionFillEqually;

    _liveInput = [UILabel new];
    _liveInput.numberOfLines = 4;
    _liveInput.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1]
        scaledFontForFont:[UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular]
        maximumPointSize:18];
    _liveInput.adjustsFontForContentSizeCategory = YES;
    _liveInput.accessibilityLabel = @"Live control input";
    _liveInput.hidden = YES;
    _liveInput.text = @"Move, look, tap a control, or connect an extended gamepad.\n"
        @"Release held controller buttons once after entering this mode.\n"
        @"Input is consumed by diagnostics; no game runs.";

    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[title, scope, _mode, _actions, _liveInput]];
    header.axis = UILayoutConstraintAxisVertical;
    header.spacing = 6;
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:header];

    _metalView = [BO1DiagnosticMetalView new];
    _metalView.translatesAutoresizingMaskIntoConstraints = NO;
    _metalView.backgroundColor = [UIColor colorWithRed:0.055 green:0.07 blue:0.10 alpha:1];
    _metalView.layer.cornerRadius = 12;
    _metalView.clipsToBounds = YES;
    CAMetalLayer *layer = (CAMetalLayer *)_metalView.layer;
    layer.device = MTLCreateSystemDefaultDevice();
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    [self.view addSubview:_metalView];
    IOS_RegisterMetalLayer((__bridge void *)layer);
    IOS_RequestScenePause(true);

    _reportView = [UITextView new];
    _reportView.editable = NO;
    _reportView.selectable = YES;
    _reportView.backgroundColor = UIColor.secondarySystemBackgroundColor;
    _reportView.textColor = UIColor.labelColor;
    _reportView.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleFootnote]
        scaledFontForFont:[UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular]
        maximumPointSize:24];
    _reportView.adjustsFontForContentSizeCategory = YES;
    _reportView.textContainerInset = UIEdgeInsetsMake(12, 10, 12, 10);
    _reportView.accessibilityLabel = @"Diagnostic report";
    _reportView.translatesAutoresizingMaskIntoConstraints = NO;
    [_metalView addSubview:_reportView];

    NSUserDefaults *preferences = [[NSUserDefaults alloc]
        initWithSuiteName:@"com.alextechgamer.bo1ios.diagnostics.controls"];
    _input = [[BO1InputFrontend alloc] initWithFrame:CGRectZero preferences:preferences];
    _input.touchHUD.translatesAutoresizingMaskIntoConstraints = NO;
    _input.touchHUD.hidden = YES;
    [_metalView addSubview:_input.touchHUD];
    for (UIView *content in @[_reportView, _input.touchHUD]) {
        [NSLayoutConstraint activateConstraints:@[
            [content.leadingAnchor constraintEqualToAnchor:_metalView.leadingAnchor],
            [content.trailingAnchor constraintEqualToAnchor:_metalView.trailingAnchor],
            [content.topAnchor constraintEqualToAnchor:_metalView.topAnchor],
            [content.bottomAnchor constraintEqualToAnchor:_metalView.bottomAnchor]
        ]];
    }
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [header.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [header.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [header.topAnchor constraintEqualToAnchor:safe.topAnchor constant:6],
        [_metalView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [_metalView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [_metalView.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:8],
        [_metalView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8]
    ]];

    __weak BO1DiagnosticsViewController *weakSelf = self;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    _audioInterruptionObserver = [center addObserverForName:AVAudioSessionInterruptionNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            if ([note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] == AVAudioSessionInterruptionTypeBegan)
                [weakSelf stopAudio:@"Stopped by an audio-session interruption. No automatic restart."];
        }];
    _audioRouteObserver = [center addObserverForName:AVAudioSessionRouteChangeNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            if ([note.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue] == AVAudioSessionRouteChangeReasonOldDeviceUnavailable)
                [weakSelf stopAudio:@"Stopped because the output route disconnected."];
        }];
    [self updateButtons];
    [self refreshReport];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIScreen *screen = self.view.window.screen ?: UIScreen.mainScreen;
    const CGFloat scale = screen.nativeScale;
    _metalView.contentScaleFactor = scale;
    CAMetalLayer *layer = (CAMetalLayer *)_metalView.layer;
    layer.contentsScale = scale;
    layer.drawableSize = CGSizeMake(std::ceil(_metalView.bounds.size.width * scale),
                                    std::ceil(_metalView.bounds.size.height * scale));
    IOS_UpdateDrawableMetrics(static_cast<uint32_t>(layer.drawableSize.width),
        static_cast<uint32_t>(layer.drawableSize.height), static_cast<uint32_t>(screen.maximumFramesPerSecond));
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    _visible = YES;
    [self updateInputState];
}
- (void)viewWillDisappear:(BOOL)animated {
    _visible = NO;
    [self updateInputState];
    [self stopAudio:@"Stopped when the diagnostics view was hidden."];
    [super viewWillDisappear:animated];
}
- (void)setApplicationActive:(BOOL)active {
    NSAssert(NSThread.isMainThread, @"Lifecycle is main-thread only");
    if (_active && !active) ++_deactivations;
    _active = active;
    if (!active) {
        if (_cancelled) _cancelled->store(true);
        [self stopAudio:@"Stopped when the application became inactive."];
    }
    if (self.isViewLoaded) {
        [self updateInputState];
        [self updateButtons];
        [self refreshReport];
    }
}

- (void)updateInputState {
    const BOOL testing = _active && _visible && _mode.selectedSegmentIndex == 1 && !_probeRunning;
    if (testing && !_displayLink) {
        IOS_SetInputContext(false, false);
        [_input setSuspended:NO];
        _displayTarget = [BO1DiagnosticDisplayTarget new];
        _displayTarget.owner = self;
        _displayLink = [CADisplayLink displayLinkWithTarget:_displayTarget selector:@selector(tick:)];
        UIScreen *screen = self.view.window.screen ?: UIScreen.mainScreen;
        const float maximum = std::clamp<float>(screen.maximumFramesPerSecond, 1, 120);
        _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(std::min(60.0f, maximum), maximum, maximum);
        _lastDisplayTime = _lastLabelUpdate = 0;
        _recentPressed = _recentReleased = 0;
        _pendingDeltaX = _pendingDeltaY = 0;
        ++_controlSessions;
        [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    } else if (!testing) {
        [_displayLink invalidate];
        _displayLink = nil;
        _displayTarget = nil;
        [_input setSuspended:YES];
        [_input resetInput];
    }
    IOS_RequestScenePause(!testing);
}

- (void)displayTick:(CADisplayLink *)link {
    if (!_active || _mode.selectedSegmentIndex != 1) return;
    [_input submitInputAtTimestamp:link.timestamp duration:link.targetTimestamp - link.timestamp];
    // Diagnostics is the ONLY consumer; no engine adapter is linked.
    IOS_ConsumeInput(&_lastSample);
    ++_sampleCount;
    _seenButtons |= _lastSample.pressedButtons | _lastSample.heldButtons;
    _maxMove = std::max(_maxMove, std::max(std::abs(_lastSample.moveX), std::abs(_lastSample.moveY)));
    _maxLook = std::max(_maxLook, std::max(std::abs(_lastSample.lookX), std::abs(_lastSample.lookY)));
    _maxTrigger = std::max(_maxTrigger, std::max(_lastSample.leftTrigger, _lastSample.rightTrigger));
    _maxTouchDelta = std::max(_maxTouchDelta, std::max(std::abs(_lastSample.deltaX), std::abs(_lastSample.deltaY)));
    _pendingDeltaX += _lastSample.deltaX;
    _pendingDeltaY += _lastSample.deltaY;
    if (_lastSample.pressedButtons || _lastSample.releasedButtons) {
        _recentPressed |= _lastSample.pressedButtons;
        _recentReleased |= _lastSample.releasedButtons;
        _lastButtonEvent = link.timestamp;
    } else if (link.timestamp - _lastButtonEvent > 0.65) {
        _recentPressed = _recentReleased = 0;
    }
    if (_lastDisplayTime > 0 && link.timestamp > _lastDisplayTime) {
        const double hz = 1.0 / (link.timestamp - _lastDisplayTime);
        _observedHz = _observedHz > 0 ? _observedHz * 0.9 + hz * 0.1 : hz;
    }
    _lastDisplayTime = link.timestamp;
    _controllerName = _input.controller.vendorName ?: @"No extended gamepad detected";
    // Consume at display cadence, but avoid relaying 120 text layout updates/s.
    if (link.timestamp - _lastLabelUpdate >= 0.1) {
        _lastLabelUpdate = link.timestamp;
        _liveInput.text = [NSString stringWithFormat:
            @"%@ | display %.0f Hz (not game FPS)\nMove %+.2f,%+.2f [%@]  Look %+.2f,%+.2f [%@]\n"
            @"ADS %.2f  Fire %.2f  Touch delta %+.1f,%+.1f\nHeld %04x  Pressed %04x  Released %04x",
            _controllerName, _observedHz, _lastSample.moveX, _lastSample.moveY, sourceName(_lastSample.movementSource),
            _lastSample.lookX, _lastSample.lookY, sourceName(_lastSample.lookSource),
            _lastSample.leftTrigger, _lastSample.rightTrigger, _pendingDeltaX, _pendingDeltaY,
            _lastSample.heldButtons, _recentPressed, _recentReleased];
        _pendingDeltaX = _pendingDeltaY = 0;
    }
}

- (void)modeChanged {
    [self stopAudio:@"Stopped when switching diagnostic modes."];
    const BOOL controls = _mode.selectedSegmentIndex == 1;
    _reportView.hidden = controls;
    _input.touchHUD.hidden = !controls;
    _actions.hidden = controls;
    _liveInput.hidden = !controls;
    [self updateInputState];
    if (!controls) [self refreshReport];
}

- (NSString *)currentReport {
    NSAssert(NSThread.isMainThread, @"Gather UIKit device information on the main thread");
    struct utsname system{};
    NSString *model = uname(&system) == 0 ? [NSString stringWithUTF8String:system.machine] : UIDevice.currentDevice.model;
#if TARGET_OS_SIMULATOR
    NSString *execution = @"iOS SIMULATOR process. This is host-backed evidence, not an iPhone device result.";
#elif TARGET_OS_IOS
    NSString *execution = @"Physical iOS device process. The checks below run in this installed diagnostics app.";
#else
    NSString *execution = @"HOST process. This does not establish iPhone behavior.";
#endif
    UIScreen *screen = self.view.window.screen ?: UIScreen.mainScreen;
    NSMutableString *report = [NSMutableString stringWithFormat:
        @"BO1 PORT DIAGNOSTICS\nGame engine: UNAVAILABLE. No gameplay or game assets are loaded.\n\n"
        @"EXECUTION CONTEXT\n%@\nHardware: %@\nOS: %@ %@\nPointer bytes: %lu\nPhysical memory: %.0f MiB\n"
        @"Screen maximum: %ld Hz; this is not a game performance measurement.\n"
        @"Source revision: %s\nBuild UTC: %s\nLast checks: %@\n\n%@\n\n"
        @"INPUT OBSERVATIONS\nControl sessions: %llu\nConsumed samples: %llu\n"
        @"Last controller observed in Control test: %@\nSeen button mask: 0x%04x\n"
        @"Largest move/held-look/trigger: %.3f / %.3f / %.3f\nLargest relative touch delta: %.3f pixels\n"
        @"Last movement/look source: %@ / %@\nDisplay-link cadence: %.1f Hz (not game FPS)\n"
        @"App deactivations: %llu; input is reset on each deactivation and mode exit.\n\n"
        @"AUDIO OUTPUT TEST\n%@\n\n"
        @"This report does not prove engine ABI compatibility, game rendering, or xWMA playback.\n"
        @"Share report opens the system share sheet only when you tap it.\n",
        execution, model, UIDevice.currentDevice.systemName, UIDevice.currentDevice.systemVersion,
        static_cast<unsigned long>(sizeof(void *)), NSProcessInfo.processInfo.physicalMemory / 1048576.0,
        static_cast<long>(screen.maximumFramesPerSecond), BO1_DIAGNOSTICS_SOURCE_REVISION, BO1_DIAGNOSTICS_BUILD_UTC,
        _lastRunDate ?: @"not run", _probeReport, static_cast<unsigned long long>(_controlSessions),
        static_cast<unsigned long long>(_sampleCount), _controllerName, _seenButtons, _maxMove, _maxLook, _maxTrigger, _maxTouchDelta,
        sourceName(_lastSample.movementSource), sourceName(_lastSample.lookSource), _observedHz,
        static_cast<unsigned long long>(_deactivations), _audioReport];
    return report;
}
- (void)refreshReport { if (_reportView) _reportView.text = [self currentReport]; }
- (void)updateButtons {
    _runButton.enabled = _audioButton.enabled = _shareButton.enabled = _filesButton.enabled = _active && !_probeRunning;
    _mode.enabled = !_probeRunning;
    setTitle(_runButton, _probeRunning ? @"Running…" : @"Run checks");
    setTitle(_audioButton, _tonePlaying ? @"Stop audio" : @"Test audio");
}

- (void)runChecks {
    if (!_active || _probeRunning || _mode.selectedSegmentIndex != 0) return;
    [self stopAudio:@"Stopped for device checks."];
    [self.view layoutIfNeeded];
    _probeRunning = YES;
    _probeReport = @"Running real Vulkan/Metal and address checks. No GPU commands or game code are submitted.";
    _lastRunDate = [[NSISO8601DateFormatter new] stringFromDate:NSDate.date];
    _cancelled = std::make_shared<std::atomic_bool>(false);
    const auto cancelled = _cancelled;
    [self updateInputState];
    [self updateButtons];
    [self refreshReport];
    // Keeping self until completion also keeps the registered layer alive.
    // The worker destroys every Vulkan object before the completion is queued.
    dispatch_async(_probeQueue, ^{
        @autoreleasepool {
            NSString *result = BO1RunDiagnosticProbes(cancelled.get());
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_probeReport = result;
                self->_probeRunning = NO;
                [self updateButtons];
                [self refreshReport];
                if (self->_active)
                    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,
                        @"Device checks finished. The game engine remains unavailable.");
            });
        }
    });
}

- (void)testAudio {
    if (!_active || _probeRunning) return;
    if (_tonePlaying) {
        [self stopAudio:@"Stopped by the user."];
        return;
    }
    SDL_SetMainReady();
    SDL_SetHint(SDL_HINT_AUDIO_CATEGORY, "ambient");
    if (!bo1_audio_init()) {
        const char *message = SDL_GetError();
        _audioReport = [NSString stringWithFormat:@"Native mixer could not open output: %@",
            message ? [NSString stringWithUTF8String:message] : @"no SDL error text"];
        bo1_audio_shutdown();
        if (SDL_WasInit(SDL_INIT_AUDIO)) SDL_QuitSubSystem(SDL_INIT_AUDIO);
        [self refreshReport];
        return;
    }
    _audioOpen = YES;
    _toneSamples.resize(ToneFrames);
    for (unsigned i = 0; i < ToneFrames; ++i) {
        const double fade = std::min(1.0, std::min(i / 960.0, (ToneFrames - 1 - i) / 960.0));
        _toneSamples[i] = static_cast<int16_t>(std::sin(2.0 * 3.141592653589793 * 440.0 * i / ToneRate)
            * 32767.0 * 0.12 * fade);
    }
    bo1_audio_open(ToneVoice, BO1_AUDIO_PCM16, 1, ToneRate, 0);
    const float gains[4] = {0.35f, 0.35f, 0, 0};
    bo1_audio_params(ToneVoice, 1.0f, gains, 0);
    if (!bo1_audio_queue(ToneVoice, _toneSamples.data(), static_cast<unsigned>(_toneSamples.size() * sizeof(int16_t)), ToneFrames)) {
        [self stopAudio:@"Native mixer opened, but the PCM buffer could not be queued."];
        return;
    }
    bo1_audio_start(ToneVoice);
    _tonePlaying = YES;
    _toneStarted = CACurrentMediaTime();
    _audioReport = @"PCM tone queued through the actual native mixer. Audibility is not automatically verified.";
    __weak BO1DiagnosticsViewController *weakSelf = self;
    _audioTimer = [NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        [weakSelf pollAudio];
    }];
    [NSRunLoop.mainRunLoop addTimer:_audioTimer forMode:NSRunLoopCommonModes];
    [self updateButtons];
    [self refreshReport];
}
- (void)pollAudio {
    if (!_tonePlaying) return;
    int finished = 0;
    const long long frames = bo1_audio_progress(ToneVoice, &finished);
    if (finished > 0) {
        [self stopAudio:[NSString stringWithFormat:@"PCM buffer completed in the native mixer (%lld frames). "
            @"Listen to confirm audibility; xWMA decoding was not exercised.", frames]];
    } else if (CACurrentMediaTime() - _toneStarted > 2.0) {
        [self stopAudio:[NSString stringWithFormat:@"PCM test timed out after two seconds (%lld frames). "
            @"The output path was stopped; audibility is unconfirmed.", frames]];
    }
}
- (void)stopAudio:(NSString *)message {
    if (!_audioOpen && !_tonePlaying) return;
    [_audioTimer invalidate];
    _audioTimer = nil;
    // stop is synchronized with the actual mixer; only then release PCM data.
    bo1_audio_stop(ToneVoice);
    bo1_audio_shutdown();
    _toneSamples.clear();
    if (SDL_WasInit(SDL_INIT_AUDIO)) SDL_QuitSubSystem(SDL_INIT_AUDIO);
    _tonePlaying = _audioOpen = NO;
    _audioReport = message;
    [self updateButtons];
    [self refreshReport];
}

- (void)openGameFiles {
    if (!_active || _probeRunning || self.presentedViewController) return;
    [self stopAudio:@"Stopped before opening game files."];
    NSError *error = nil;
    NSURL *documents = [NSFileManager.defaultManager URLForDirectory:NSDocumentDirectory
        inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:&error];
    if (!documents) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Game files"
            message:error.localizedDescription ?: @"The Documents folder could not be opened."
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    __weak BO1DiagnosticsViewController *weakSelf = self;
    _gameFilesController = [BO1SteamGameFiles makeViewControllerForDirectory:
        [documents URLByAppendingPathComponent:@"game" isDirectory:YES]
        completion:^(NSError *downloadError) {
            (void)downloadError; // The Game Files screen presents actionable errors.
            dispatch_async(dispatch_get_main_queue(), ^{
                BO1DiagnosticsViewController *owner = weakSelf;
                if (!owner) return;
                if (owner.presentedViewController == owner->_gameFilesController) {
                    [owner dismissViewControllerAnimated:YES completion:^{
                        owner->_gameFilesController = nil;
                    }];
                } else {
                    owner->_gameFilesController = nil;
                }
            });
        }];
    _gameFilesController.modalPresentationStyle = UIModalPresentationPageSheet;
    _gameFilesController.modalInPresentation = YES;
    [self presentViewController:_gameFilesController animated:YES completion:nil];
}

- (void)shareReport {
    if (!_active || _probeRunning || self.presentedViewController) return;
    [self stopAudio:@"Stopped before opening the report share sheet."];
    UIActivityViewController *share = [[UIActivityViewController alloc]
        initWithActivityItems:@[[self currentReport]] applicationActivities:nil];
    share.popoverPresentationController.sourceView = _shareButton;
    share.popoverPresentationController.sourceRect = _shareButton.bounds;
    [self presentViewController:share animated:YES completion:nil];
}

- (void)dealloc {
    if (_cancelled) _cancelled->store(true);
    [_displayLink invalidate];
    [_audioTimer invalidate];
    if (_audioInterruptionObserver) [NSNotificationCenter.defaultCenter removeObserver:_audioInterruptionObserver];
    if (_audioRouteObserver) [NSNotificationCenter.defaultCenter removeObserver:_audioRouteObserver];
    [_input setSuspended:YES];
    if (_audioOpen) {
        bo1_audio_stop(ToneVoice);
        bo1_audio_shutdown();
        if (SDL_WasInit(SDL_INIT_AUDIO)) SDL_QuitSubSystem(SDL_INIT_AUDIO);
    }
    IOS_RequestScenePause(true);
    // In-flight workers retain this controller until their surface/instance
    // cleanup has completed. The layer is never unregistered underneath them.
    IOS_RegisterMetalLayer(nullptr);
}
@end
