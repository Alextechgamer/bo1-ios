#import <UIKit/UIKit.h>
#import "DiagnosticsViewController.h"
#import "BO1SteamGameFiles.h"

@interface BO1DiagnosticsAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) BO1DiagnosticsViewController *diagnostics;
@end

@implementation BO1DiagnosticsAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application; (void)options;
    self.diagnostics = [BO1DiagnosticsViewController new];
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = self.diagnostics;
    [self.window makeKeyAndVisible];
    return YES;
}
- (void)applicationDidBecomeActive:(UIApplication *)application {
    (void)application;
    [self.diagnostics setApplicationActive:YES];
}
- (void)applicationWillResignActive:(UIApplication *)application {
    (void)application;
    [self.diagnostics setApplicationActive:NO];
}
- (void)applicationDidEnterBackground:(UIApplication *)application {
    (void)application;
    [self.diagnostics setApplicationActive:NO];
    [BO1SteamGameFiles applicationDidEnterBackground];
}
- (void)applicationWillTerminate:(UIApplication *)application {
    (void)application;
    [self.diagnostics setApplicationActive:NO];
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(BO1DiagnosticsAppDelegate.class));
    }
}
