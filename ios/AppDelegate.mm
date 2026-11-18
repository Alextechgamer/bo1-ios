#import "AppDelegate.h"
#import "GameViewController.h"
#import "include/BO1IOSHostServices.h"
#import "include/ios_platform_bridge.h"
#import "include/BO1SteamGameFiles.h"

@interface BO1AppDelegate ()
@property(nonatomic, strong) BO1GameViewController *gameController;
@end

@implementation BO1AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application;
    (void)options;
    IOS_RequestScenePause(true);
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];

    NSError *error = nil;
    id<BO1IOSHostServices> services = BO1IOSCreateHostServices(&error);
    if (services) {
        self.gameController = [[BO1GameViewController alloc] initWithHostServices:services];
        self.window.rootViewController = self.gameController;
    } else {
        UIViewController *failure = [UIViewController new];
        failure.view.backgroundColor = UIColor.systemBackgroundColor;
        UILabel *message = [UILabel new];
        message.numberOfLines = 0;
        message.textAlignment = NSTextAlignmentCenter;
        message.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        message.adjustsFontForContentSizeCategory = YES;
        message.text = [NSString stringWithFormat:@"Black Ops could not initialize.\n\n%@",
            error.localizedDescription ?: @"The native engine integration did not provide its host services."];
        message.translatesAutoresizingMaskIntoConstraints = NO;
        [failure.view addSubview:message];
        [NSLayoutConstraint activateConstraints:@[
            [message.leadingAnchor constraintEqualToAnchor:failure.view.safeAreaLayoutGuide.leadingAnchor constant:24],
            [message.trailingAnchor constraintEqualToAnchor:failure.view.safeAreaLayoutGuide.trailingAnchor constant:-24],
            [message.centerYAnchor constraintEqualToAnchor:failure.view.safeAreaLayoutGuide.centerYAnchor]
        ]];
        self.window.rootViewController = failure;
    }
    [self.window makeKeyAndVisible];
    return YES;
}

- (void)applicationWillResignActive:(UIApplication *)application {
    (void)application;
    [self.gameController setApplicationActive:NO];
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    (void)application;
    // Idempotent: also covers a lifecycle transition not preceded by a normal
    // active UI session. The controller will not issue duplicate drain calls.
    [self.gameController setApplicationActive:NO];
    [BO1SteamGameFiles applicationDidEnterBackground];
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    (void)application;
    [self.gameController setApplicationActive:YES];
}

- (void)applicationWillTerminate:(UIApplication *)application {
    (void)application;
    [self.gameController setApplicationActive:NO];
}

@end
