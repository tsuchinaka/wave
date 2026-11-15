#import "waRootController.h"
#import "../Core/waSession.h"
#import "../Core/waPlayer.h"
#import "../Core/waLastFM.h"
#import "../Core/waLog.h"
#import "../Core/waCrash.h"
#import "../Core/waCast.h"
#import "waDetailController.h"
#import "../Skin/waSkin.h"

@implementation waRootController (AppBoot)
@end

@implementation waAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)launchOptions;
    [waCrash install];
    [waSkin install];

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.backgroundColor = [UIColor blackColor];
    waRootController *root = [[waRootController alloc] init];
    self.root = root;
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];

    [application beginReceivingRemoteControlEvents];
    [waLastFM shared];
    [waCast shared];
    [[waSession shared] restoreWithCompletion:^(BOOL ok, NSError *error) {
        (void)ok;
        if (error) [[waLog shared] log:@"restore failed %@", error.localizedDescription];
        waCast *cast = [waCast shared];
        if (cast.target.host.length) {
            [cast recover];
            waPlayer *player = [waPlayer shared];
            if (player.currentTrack) [player refreshOutput];
        }
    }];
    return YES;
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    (void)application;
    [[waRootController shared] refreshMiniPlayer];
    waCast *cast = [waCast shared];
    if (cast.target.host.length) {
        [cast recover];
        if ([waPlayer shared].currentTrack && !cast.connected) [[waPlayer shared] refreshOutput];
    }
}

- (void)remoteControlReceivedWithEvent:(UIEvent *)event {
    [[waPlayer shared] handleRemoteControl:event];
}

- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url sourceApplication:(NSString *)sourceApplication annotation:(id)annotation {
    (void)application; (void)sourceApplication; (void)annotation;
    if ([[url.scheme lowercaseString] isEqualToString:@"wave"] && ([[url.host lowercaseString] isEqualToString:@"album"] || [[url.host lowercaseString] isEqualToString:@"artist"] || [[url.host lowercaseString] isEqualToString:@"playlist"])) {
        NSString *identifier = [url.path stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
        if (!identifier.length) return NO;
        waRootController *root = [waRootController shared];
        UINavigationController *nav = (UINavigationController *)root.selectedViewController;
        if (![nav isKindOfClass:[UINavigationController class]]) return NO;
        NSString *host = [url.host lowercaseString];
        if ([host isEqualToString:@"album"]) {
            [[waSession shared] album:identifier completion:^(waAlbum *album, NSError *error) {
                if (album) [nav pushViewController:[[waDetailController alloc] initWithAlbum:album] animated:YES];
            }];
        } else if ([host isEqualToString:@"artist"]) {
            [[waSession shared] artist:identifier completion:^(waArtist *artist, NSError *error) {
                if (artist) [nav pushViewController:[[waDetailController alloc] initWithArtist:artist] animated:YES];
            }];
        } else {
            [[waSession shared] playlist:identifier completion:^(waPlaylist *playlist, NSError *error) {
                if (playlist) [nav pushViewController:[[waDetailController alloc] initWithPlaylist:playlist] animated:YES];
            }];
        }
        return YES;
    }
    if ([[url.scheme lowercaseString] isEqualToString:@"wave"] && [[url.host lowercaseString] isEqualToString:@"tab"]) {
        NSString *raw = [url.path stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
        NSInteger index = [raw integerValue];
        waRootController *root = [waRootController shared];
        if (root.modalViewController) [root dismissModalViewControllerAnimated:NO];
        if (index >= 0 && index < (NSInteger)root.viewControllers.count) root.selectedIndex = (NSUInteger)index;
        return YES;
    }
    if ([[url.scheme lowercaseString] isEqualToString:@"wave"] && [[url.host lowercaseString] isEqualToString:@"play"]) {
        NSString *raw = [url.path stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
        NSArray *parts = [raw componentsSeparatedByString:@","];
        NSMutableArray *slots = [NSMutableArray array];
        for (NSUInteger i = 0; i < parts.count; i++) [slots addObject:[NSNull null]];
        __block NSUInteger remaining = parts.count;
        NSTimeInterval seekTarget = 0.0;
        for (NSString *pair in [url.query componentsSeparatedByString:@"&"]) {
            if ([pair hasPrefix:@"t="]) seekTarget = [[pair substringFromIndex:2] doubleValue];
        }
        for (NSUInteger index = 0; index < parts.count; index++) {
            NSString *trackID = [parts objectAtIndex:index];
            if (!trackID.length) { remaining--; continue; }
            [[waSession shared] track:trackID completion:^(waTrack *track, NSError *error) {
                if (track && !error) [slots replaceObjectAtIndex:index withObject:track];
                if (--remaining > 0) return;
                NSMutableArray *tracks = [NSMutableArray array];
                for (id slot in slots) if ([slot isKindOfClass:[waTrack class]]) [tracks addObject:slot];
                if (!tracks.count) return;
                [[waSession shared] playTracks:tracks startAt:0 context:@"Wave"];
                [[waRootController shared] showPlayer];
                if (seekTarget > 0.0) {
                    for (NSUInteger attempt = 0; attempt < 20; attempt++) {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((0.5 + attempt * 0.5) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            if ([waPlayer shared].duration > seekTarget) [[waPlayer shared] seekTo:seekTarget];
                        });
                    }
                }
            }];
        }
        return YES;
    }
    return NO;
}

@end
