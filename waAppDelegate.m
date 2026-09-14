#import "waAppDelegate.h"
#import "Controllers/waHomeViewController.h"
#import "Controllers/waListViewController.h"
#import "Controllers/waSettingsViewController.h"
#import "Controllers/waProfileViewController.h"
#import "Controllers/waPlayerViewController.h"
#import "Controllers/waLibraryViewController.h"
#import "Models/waPreferences.h"
#import "Audio/waAudioEngine.h"
#import "Services/waAudioPlayer.h"
#import "Services/waTheme.h"
#import "Services/waDebugLog.h"
#import "Services/waLastFMClient.h"
#import "Services/waDeezerClient.h"
#import "Controllers/waDeezerLoginViewController.h"

@interface waAppDelegate () <UITabBarControllerDelegate>
@property (nonatomic, strong) UINavigationController *playerTabController;
@property (nonatomic, strong) UINavigationController *authNavigationController;
@property (nonatomic, assign) BOOL authenticationValidationInFlight;
@property (nonatomic, assign) BOOL authenticationValidated;
- (void)enforceDeezerAuthentication;
- (void)deezerAuthenticationDidChange:(NSNotification *)notification;
- (void)requiredLoginDidFinishWithError:(NSError *)error;
@end

@interface waPlayerNavigationController : UINavigationController
@end

@implementation waPlayerNavigationController

- (BOOL)shouldAutorotate { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation { (void)orientation; return YES; }

@end

@implementation waAppDelegate

#pragma mark - Tab Bar Factory (SDK)

- (UIImage *)waTabImageNamed:(NSString *)name {
    UIImage *image = [UIImage imageNamed:name];
    if ([waTheme isModernSystem] && [image respondsToSelector:@selector(imageWithRenderingMode:)]) {
        // Black mask → template so tabBar.tintColor tints it (iOS 7 SDK)
        return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    return image;
}

- (UITabBarItem *)waTabItemWithTag:(NSInteger)tag imageName:(NSString *)imageName accessibilityLabel:(NSString *)label {
    // SDK: title "" + insets centers icon vertically when titles hidden
    UITabBarItem *item = [[UITabBarItem alloc] initWithTitle:@"" image:[self waTabImageNamed:imageName] tag:tag];
    // Zero-width space prevents iOS 6 from copying nav title into tab
    item.title = @"\u200B";
    item.accessibilityLabel = label;
    item.imageInsets = UIEdgeInsetsMake(6.0, 0.0, -6.0, 0.0);
    // iOS 7+: hide title offscreen via offset so VoiceOver keeps label
    if ([waTheme isModernSystem] && [item respondsToSelector:@selector(setTitlePositionAdjustment:)]) {
        item.titlePositionAdjustment = UIOffsetMake(0.0, 100.0);
    }
    return item;
}

- (UINavigationController *)waNavWithRoot:(UIViewController *)root {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    nav.view.backgroundColor = [waTheme backgroundColor];
    return nav;
}

- (void)applyThemeToTabBar:(UITabBar *)tabBar {
    if (!tabBar) return;
    if ([waTheme isModernSystem]) {
        [waTheme applyToView:tabBar];
        return;
    }
    tabBar.selectedImageTintColor = nil;
    tabBar.selectionIndicatorImage = nil;
}

- (void)hideTabBarTitles:(UITabBarController *)tabBarController {
    // Accessibility labels per SDK, titles hidden via factory + offset
    NSArray *labels = @[@"Wave", @"Search", @"Library", @"Settings", @"Player"];
    for (UITabBarItem *item in tabBarController.tabBar.items) {
        if (item.tag >= 0 && (NSUInteger)item.tag < labels.count) item.accessibilityLabel = labels[item.tag];
        // Ensure insets stay centered (SDK: imageInsets only)
        item.imageInsets = UIEdgeInsetsMake(6.0, 0.0, -6.0, 0.0);
    }
    [self applyThemeToTabBar:tabBarController.tabBar];
    [self hideTabBarLabelsInView:tabBarController.tabBar];
}

- (void)hideTabBarLabelsInView:(UIView *)view {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:[UILabel class]]) {
            subview.hidden = YES;
            subview.alpha = 0.0;
        } else {
            [self hideTabBarLabelsInView:subview];
        }
    }
}

- (void)remoteControlReceivedWithEvent:(UIEvent *)event {
    if (event.type != UIEventTypeRemoteControl) return;
    // Unify in waAudioEngine (MPRemoteCommandCenter + legacy). AppDelegate stays as fallback for iOS 6.
    [[waAudioEngine sharedEngine] remoteControlReceivedWithEvent:event];
}

static void waCrashHandler(NSException *exception) {
    NSString *msg = [NSString stringWithFormat:@"CRASH %@ reason:%@ callStack:%@", exception.name, exception.reason, exception.callStackSymbols];
    [[waDebugLog sharedLog] log:@"%@", msg];
    // Also write to file for post-crash read even if log ring overwrites
    NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).lastObject stringByAppendingPathComponent:@"wave-crash.log"];
    [msg writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	NSSetUncaughtExceptionHandler(&waCrashHandler);
	[[waDebugLog sharedLog] log:@"Wave launched"];
	[application beginReceivingRemoteControlEvents];
	_window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
	_window.backgroundColor = [waTheme backgroundColor];
	[waTheme configureGlobalAppearance];
 	// --- Tab factory: SDK order wave / search / library / settings / player ---
 	UIViewController *home = [self waNavWithRoot:[[waHomeViewController alloc] init]];
 	UIViewController *search = [self waNavWithRoot:[[waListViewController alloc] init]];
	UIViewController *library = [self waNavWithRoot:[[waLibraryViewController alloc] init]];
    // One-time scrobble migration (serverless — waAPIClient removed)
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults stringForKey:@"wa.lastfm.sessionKey"].length && [defaults objectForKey:@"wa.lastfm.scrobbling"] == nil) {
        [defaults setBool:YES forKey:@"wa.lastfm.scrobbling"];
        [[waDebugLog sharedLog] log:@"Last.fm scrobbling enabled (session present, no prior preference)"];
    }
 	UIViewController *settings = [self waNavWithRoot:[[waSettingsViewController alloc] initWithStyle:UITableViewStyleGrouped]];
 	self.playerTabController = [self waNavWithRoot:[[UIViewController alloc] init]];
 	UIViewController *player = self.playerTabController;

 	UITabBarController *tabs = [[UITabBarController alloc] init];
 	tabs.delegate = self;
 	tabs.viewControllers = @[home, search, library, settings, player];

 	// iOS 6 quirk: Home's viewDidLoad sets nav title; load before assigning tab items
 	[home view];

 	home.tabBarItem = [self waTabItemWithTag:0 imageName:@"tab-wave-home" accessibilityLabel:@"Wave"];
 	search.tabBarItem = [self waTabItemWithTag:1 imageName:@"tab-wave-search" accessibilityLabel:@"Search"];
	library.tabBarItem = [self waTabItemWithTag:2 imageName:@"tab-wave-library" accessibilityLabel:@"Library"];
 	settings.tabBarItem = [self waTabItemWithTag:3 imageName:@"tab-wave-settings" accessibilityLabel:@"Settings"];
 	player.tabBarItem = [self waTabItemWithTag:4 imageName:@"tab-wave-player" accessibilityLabel:@"Player"];

  	[self hideTabBarTitles:tabs];
 	_rootViewController = tabs;
 	_window.rootViewController = _rootViewController;
    [_window makeKeyAndVisible];
    // iOS 7+ only. Guarded to avoid wasted traversals on the legacy path
    // where both helpers early-return (waTheme:isModernSystem == NO).
    if ([waTheme isModernSystem]) {
        for (UIViewController *controller in tabs.viewControllers) {
            [waTheme applyLayoutCompatibilityToViewController:controller];
            if ([controller isKindOfClass:[UINavigationController class]]) {
                [waTheme applyLayoutCompatibilityToViewController:((UINavigationController *)controller).topViewController];
            }
        }
        [waTheme applyStatusBarAppearance];
        // Info.plist UIStatusBarHidden=true makes splash fullscreen (no status bar).
        // Unhide immediately after launch so the app itself shows the status bar.
        [[UIApplication sharedApplication] setStatusBarHidden:NO withAnimation:UIStatusBarAnimationNone];
    }
    // Fast path: only visible chrome now (home bar + tab bar). Full window
    // traversal runs after the first frame so black-screen time stays short.
    [waTheme applyToView:((UINavigationController *)home).navigationBar];
    [self applyThemeToTabBar:tabs.tabBar];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf hideTabBarLabelsInView:tabs.tabBar];
        [weakSelf applyThemeToNavigationControllers];
	});
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeDidChange:) name:waThemeDidChangeNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(deezerAuthenticationDidChange:) name:waDeezerAuthenticationDidChangeNotification object:nil];
	[self enforceDeezerAuthentication];
	return YES;
}

- (void)enforceDeezerAuthentication {
    if (![NSThread isMainThread]) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf enforceDeezerAuthentication]; });
        return;
    }
    waDeezerClient *deezer = [waDeezerClient sharedClient];
    BOOL hasCredential = [deezer isAuthenticated];
    if (!hasCredential) self.authenticationValidated = NO;

    // Keep the mandatory controller stable while it is visible. The login
    // controller itself performs the first validation after saving a new ARL.
    if (self.authNavigationController.presentingViewController) return;

    if (hasCredential) {
        if (self.authenticationValidated || self.authenticationValidationInFlight) return;
        self.authenticationValidationInFlight = YES;
        __weak typeof(self) weakSelf = self;
        [deezer validateAuthenticationWithCompletion:^(BOOL valid, NSError *error) {
            waAppDelegate *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.authenticationValidationInFlight = NO;
            if (valid) {
                strongSelf.authenticationValidated = YES;
                return;
            }
            strongSelf.authenticationValidated = NO;
            // Preserve a valid ARL during a temporary offline/DNS failure;
            // only a Deezer rejection clears it in waDeezerClient.
            if (error && error.code != 401 && error.code != 403 && [deezer isAuthenticated]) {
                strongSelf.authenticationValidated = YES;
                [[waDebugLog sharedLog] log:@"Deezer validation deferred after transient error: %@", error.localizedDescription ?: @"unknown"];
            }
            [strongSelf enforceDeezerAuthentication];
        }];
        return;
    }

    // A successful login dismisses itself. Clear a completed gate before
    // creating a new one, but never stack two mandatory login controllers.
    if (self.authNavigationController) {
        if (self.authNavigationController.presentingViewController) return;
        self.authNavigationController = nil;
    }
    UIViewController *presenter = self.rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    if (!presenter) return;

    __weak typeof(self) weakSelf = self;
    waDeezerLoginViewController *login = [[waDeezerLoginViewController alloc] initWithCompletion:^(NSError *error) {
        [weakSelf requiredLoginDidFinishWithError:error];
    } required:YES];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:login];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    navigation.view.backgroundColor = [waTheme backgroundColor];
    [waTheme applyLayoutCompatibilityToViewController:navigation];
    [waTheme applyToView:navigation.navigationBar];
    self.authNavigationController = navigation;
    [presenter presentViewController:navigation animated:NO completion:nil];
}

- (void)requiredLoginDidFinishWithError:(NSError *)error {
    if (error) {
        self.authenticationValidated = NO;
        return;
    }
    self.authenticationValidated = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        waAppDelegate *strongSelf = weakSelf;
        if (strongSelf && !strongSelf.authNavigationController.presentingViewController) strongSelf.authNavigationController = nil;
    });
}

- (void)deezerAuthenticationDidChange:(NSNotification *)notification {
    (void)notification;
    self.authenticationValidated = NO;
    [self enforceDeezerAuthentication];
}

- (BOOL)application:(UIApplication *)application handleOpenURL:(NSURL *)url {
    return [[waLastFMClient sharedClient] handleCallbackURL:url];
}


- (void)tabBarController:(UITabBarController *)tabBarController didSelectViewController:(UIViewController *)viewController {
    [self hideTabBarLabelsInView:tabBarController.tabBar];
}

- (BOOL)tabBarController:(UITabBarController *)tabBarController shouldSelectViewController:(UIViewController *)viewController {
    [self hideTabBarTitles:tabBarController];
    if (viewController != self.playerTabController) return YES;
    waPlayerNavigationController *playerNavigationController = [[waPlayerNavigationController alloc] initWithRootViewController:[[waPlayerViewController alloc] init]];
    playerNavigationController.modalPresentationStyle = UIModalPresentationFullScreen;
    [waTheme applyLayoutCompatibilityToViewController:playerNavigationController];
    // Prepare the modal container before UIKit starts the cover transition so
    // its initial frames do not expose the default white background.
    playerNavigationController.view.backgroundColor = [waTheme backgroundColor];
    playerNavigationController.view.opaque = YES;
    [waTheme applyToView:playerNavigationController.navigationBar];
    [tabBarController presentViewController:playerNavigationController animated:YES completion:nil];
    return NO;
}

- (void)applyThemeToNavigationControllers {
    [waTheme applyToWindow:self.window];
    [self applyThemeToTabBar:((UITabBarController *)self.rootViewController).tabBar];
    // UINavigationController owns its bar; applying through the window view
    // hierarchy is not reliable for inactive tab controllers on iOS 6.
    for (UIViewController *controller in ((UITabBarController *)self.rootViewController).viewControllers) {
        if ([controller isKindOfClass:[UINavigationController class]]) {
            UINavigationController *navigationController = (UINavigationController *)controller;
            navigationController.view.backgroundColor = [waTheme backgroundColor];
            [waTheme applyToView:navigationController.navigationBar];
            // Do not touch inactive tab roots during launch. Accessing
            // topViewController.view forces every UITableViewController to
            // load synchronously, which leaves iOS 7 on a black screen and
            // can trigger UIKit crashes before the first frame is drawn.
            UIViewController *topViewController = navigationController.topViewController;
            if (topViewController.isViewLoaded) {
                topViewController.view.backgroundColor = [waTheme backgroundColor];
                [waTheme applyToView:topViewController.view];
            }
        }
    }
}

- (void)themeDidChange:(NSNotification *)notification {
    [self applyThemeToNavigationControllers];
    UIViewController *presented = self.rootViewController.presentedViewController;
    if ([presented isKindOfClass:[UINavigationController class]]) {
        UINavigationController *navigationController = (UINavigationController *)presented;
        navigationController.view.backgroundColor = [waTheme backgroundColor];
        [waTheme applyToView:navigationController.navigationBar];
    }
}

@end
