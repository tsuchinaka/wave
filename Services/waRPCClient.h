#import <Foundation/Foundation.h>

extern NSString * const waRPCClientDidChangeNotification;

// Optional local-network bridge for Discord Rich Presence. The player only
// depends on this small transport interface; pairing and socket details stay
// isolated from playback and UI modules.
@interface waRPCClient : NSObject <NSStreamDelegate, NSNetServiceBrowserDelegate, NSNetServiceDelegate>
+ (waRPCClient *)sharedClient;

@property (nonatomic, assign, readonly, getter=isConnected) BOOL connected;
@property (nonatomic, assign, getter=isShowInDiscord) BOOL showInDiscord;

- (void)publishPlaybackWithTrackID:(NSString *)trackID
                              title:(NSString *)title
                             artist:(NSString *)artist
                              album:(NSString *)album
                              state:(NSString *)state
                         position:(NSTimeInterval)position
                          duration:(NSTimeInterval)duration
                       artworkURL:(NSString *)artworkURL;
- (void)publishSeekToPosition:(NSTimeInterval)position duration:(NSTimeInterval)duration;
- (void)updatePlaybackPosition:(NSTimeInterval)position duration:(NSTimeInterval)duration;
- (void)publishCrossfadeToTrackID:(NSString *)trackID
                     fromTrackID:(NSString *)fromTrackID
                         duration:(NSTimeInterval)duration
                         position:(NSTimeInterval)position;
- (void)pairWithPIN:(NSString *)pin completion:(void (^)(BOOL success, NSError *error))completion;
- (void)pairWithQRPayload:(NSString *)payload completion:(void (^)(BOOL success, NSError *error))completion;
- (void)shutdown;
- (void)disconnect;
@end
