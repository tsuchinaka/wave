#import <Foundation/Foundation.h>

extern NSString * const waLastFMAuthenticationDidChangeNotification;

@interface waLastFMClient : NSObject
+ (waLastFMClient *)sharedClient;
- (BOOL)isAuthenticated;
- (BOOL)hasPendingLogin;
- (void)loginWithUsername:(NSString *)username password:(NSString *)password completion:(void (^)(NSError *error))completion;
- (void)updateNowPlayingArtist:(NSString *)artist title:(NSString *)title duration:(NSTimeInterval)duration completion:(void (^)(NSError *error))completion;
- (void)scrobbleArtist:(NSString *)artist title:(NSString *)title album:(NSString *)album duration:(NSTimeInterval)duration timestamp:(NSTimeInterval)timestamp completion:(void (^)(NSError *error))completion;
- (void)logout;
- (BOOL)handleCallbackURL:(NSURL *)url;
@end
