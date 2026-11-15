#import <Foundation/Foundation.h>

extern NSString * const waCastDevicesDidChangeNotification;
extern NSString * const waCastStatusDidChangeNotification;

@interface waCastDevice : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *model;
@property (nonatomic, copy) NSString *host;
@property (nonatomic, assign) NSInteger port;
@end

// Cast v2 over TLS 1.2. The phone decrypts the Deezer stream and serves it,
// because a Chromecast cannot undo BF_CBC_STRIPE.
@interface waCast : NSObject
+ (waCast *)shared;
@property (nonatomic, readonly) NSArray *devices;
@property (nonatomic, readonly) waCastDevice *target;
@property (nonatomic, readonly) BOOL connected;
@property (nonatomic, readonly) NSTimeInterval position;
@property (nonatomic, readonly) NSTimeInterval duration;
@property (nonatomic, readonly) BOOL playing;
@property (nonatomic, readonly) float volume;
@property (nonatomic, readonly) NSString *contentID;
@property (nonatomic, readonly) BOOL airPlayActive;
@property (nonatomic, readonly) NSString *airPlayName;
- (void)startDiscovery;
- (void)selectDevice:(waCastDevice *)device;
- (void)clearTarget;
- (void)recover;
- (void)playStream:(NSURL *)url title:(NSString *)title artist:(NSString *)artist album:(NSString *)album artwork:(NSString *)artwork duration:(NSTimeInterval)duration startAt:(NSTimeInterval)startAt;
- (void)prepareStream:(NSURL *)url title:(NSString *)title artist:(NSString *)artist album:(NSString *)album artwork:(NSString *)artwork duration:(NSTimeInterval)duration;
- (void)pause;
- (void)play;
- (void)stopPlayback;
- (void)seekTo:(NSTimeInterval)time;
- (void)setVolume:(float)volume;
@end
