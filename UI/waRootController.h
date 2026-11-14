#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class waPlayerController, waTrack;

extern NSString * const waMiniPlayerLayoutDidChangeNotification;

@interface waRootController : UITabBarController
+ (waRootController *)shared;
- (void)showPlayer;
- (void)hidePlayer;
- (void)refreshMiniPlayer;
- (CGFloat)miniPlayerHeight;
+ (CGFloat)miniPlayerCoverHeight;
@end

@interface waMiniPlayerBar : UIToolbar
@property (nonatomic, strong) UIImageView *artworkView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, copy) NSString *artworkKey;
- (void)setPlaying:(BOOL)playing;
@end

@interface waAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) waRootController *root;
@end
