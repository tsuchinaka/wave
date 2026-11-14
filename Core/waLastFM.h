#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class waTrack;

extern NSString * const waLastFMDidChangeNotification;

@interface waLastFM : NSObject
+ (waLastFM *)shared;
+ (UIImage *)logoActive:(BOOL)active;

@property (nonatomic, readonly) BOOL signedIn;
@property (nonatomic, readonly) BOOL scrobblingEnabled;
@property (nonatomic, readonly) BOOL active;
@property (nonatomic, readonly, copy) NSString *username;

- (void)loginWithUsername:(NSString *)username password:(NSString *)password completion:(void (^)(BOOL ok, NSError *error))completion;
- (void)logout;
- (void)setScrobblingEnabled:(BOOL)enabled;
@end
