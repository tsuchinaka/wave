#import "waRPCClient.h"
#import <UIKit/UIKit.h>

static NSString * const waRPCEnabledKey = @"wa.rpc.enabled";
static NSString * const waRPCHostKey = @"wa.rpc.host";
static NSString * const waRPCPortKey = @"wa.rpc.port";
static NSString * const waRPCTokenKey = @"wa.rpc.token";
static NSString * const waRPCDefaultHost = @"192.168.1.8";
static NSUInteger const waRPCDefaultPort = 31337;
static NSUInteger const waRPCMaximumQueuedBytes = 256 * 1024;

NSString * const waRPCClientDidChangeNotification = @"waRPCClientDidChangeNotification";

@interface waRPCClient ()
@property (nonatomic, assign, readwrite, getter=isConnected) BOOL connected;
@property (nonatomic, strong) NSInputStream *inputStream;
@property (nonatomic, strong) NSOutputStream *outputStream;
@property (nonatomic, strong) NSMutableData *readBuffer;
@property (nonatomic, strong) NSMutableData *writeBuffer;
@property (nonatomic, strong) NSTimer *heartbeatTimer;
@property (nonatomic, strong) NSTimer *reconnectTimer;
@property (nonatomic, copy) NSString *host;
@property (nonatomic, copy) NSString *token;
@property (nonatomic, assign) NSUInteger port;
@property (nonatomic, assign) NSUInteger sequence;
@property (nonatomic, assign) BOOL openedOutput;
@property (nonatomic, assign) BOOL intentionalDisconnect;
@property (nonatomic, strong) NSNetServiceBrowser *serviceBrowser;
@property (nonatomic, strong) NSNetService *resolvingService;
@property (nonatomic, copy) NSString *pairingPIN;
@property (nonatomic, copy) void (^pairingCompletion)(BOOL success, NSError *error);
@property (nonatomic, copy) NSString *lastTrackID;
@property (nonatomic, copy) NSString *lastTitle;
@property (nonatomic, copy) NSString *lastArtist;
@property (nonatomic, copy) NSString *lastAlbum;
@property (nonatomic, copy) NSString *lastState;
@property (nonatomic, copy) NSString *lastArtworkURL;
@property (nonatomic, assign) NSTimeInterval lastPosition;
@property (nonatomic, assign) NSTimeInterval lastDuration;
@end

@implementation waRPCClient

- (void)setConnected:(BOOL)connected {
    if (_connected == connected) return;
    _connected = connected;
    [[NSNotificationCenter defaultCenter] postNotificationName:waRPCClientDidChangeNotification object:self];
}

- (BOOL)isShowInDiscord {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *token = [defaults stringForKey:waRPCTokenKey];
    return [defaults objectForKey:waRPCEnabledKey] ? [defaults boolForKey:waRPCEnabledKey] : token.length > 0;
}

- (void)setShowInDiscord:(BOOL)showInDiscord {
    [[NSUserDefaults standardUserDefaults] setBool:showInDiscord forKey:waRPCEnabledKey];
    if (showInDiscord) {
        [self loadConfiguration];
        [self connectIfNeeded];
    } else {
        [self shutdown];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:waRPCClientDidChangeNotification object:self];
}

+ (waRPCClient *)sharedClient {
    static waRPCClient *client;
    if (!client) client = [[self alloc] init];
    return client;
}

- (id)init {
    if ((self = [super init])) {
        self.readBuffer = [NSMutableData data];
        self.writeBuffer = [NSMutableData data];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillTerminate:) name:UIApplicationWillTerminateNotification object:nil];
    }
    return self;
}

- (void)publishPlaybackWithTrackID:(NSString *)trackID
                              title:(NSString *)title
                             artist:(NSString *)artist
                              album:(NSString *)album
                              state:(NSString *)state
                          position:(NSTimeInterval)position
                          duration:(NSTimeInterval)duration
                       artworkURL:(NSString *)artworkURL {
    if (![self loadConfiguration]) return;
    self.lastTrackID = trackID ?: @"";
    self.lastTitle = title ?: @"";
    self.lastArtist = artist ?: @"";
    self.lastAlbum = album;
    self.lastState = state ?: @"stopped";
    self.lastPosition = MAX(0.0, position);
    self.lastDuration = MAX(0.0, duration);
    self.lastArtworkURL = artworkURL;
    [self connectIfNeeded];
    [self sendPlayback];
}

- (void)publishSeekToPosition:(NSTimeInterval)position duration:(NSTimeInterval)duration {
    if (![self loadConfiguration]) return;
    self.lastPosition = MAX(0.0, position);
    if (duration > 0.0) self.lastDuration = duration;
    [self connectIfNeeded];
    if (!self.connected) return;
    [self sendDictionary:@{ @"type": @"seek", @"seq": @([self nextSequence]), @"position_ms": @((NSUInteger)(self.lastPosition * 1000.0)) }];
}

- (void)updatePlaybackPosition:(NSTimeInterval)position duration:(NSTimeInterval)duration {
    if (![self loadConfiguration]) return;
    self.lastPosition = MAX(0.0, position);
    if (duration > 0.0) self.lastDuration = duration;
    [self connectIfNeeded];
}

- (void)publishCrossfadeToTrackID:(NSString *)trackID
                     fromTrackID:(NSString *)fromTrackID
                         duration:(NSTimeInterval)duration
                         position:(NSTimeInterval)position {
    if (![self loadConfiguration]) return;
    [self connectIfNeeded];
    if (!self.connected) return;
    NSUInteger sequence = [self nextSequence];
    NSMutableDictionary *message = [@{ @"type": @"crossfade", @"seq": @(sequence), @"to_track_id": trackID ?: @"", @"duration_ms": @((NSUInteger)(MAX(0.0, duration) * 1000.0)), @"position_ms": @((NSUInteger)(MAX(0.0, position) * 1000.0)) } mutableCopy];
    if (fromTrackID.length) message[@"from_track_id"] = fromTrackID;
    [self sendDictionary:message];
}

- (void)pairWithPIN:(NSString *)pin completion:(void (^)(BOOL, NSError *))completion {
    NSString *normalized = [pin stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if (normalized.length != 6 || [normalized rangeOfCharacterFromSet:nonDigits].location != NSNotFound) {
        if (completion) completion(NO, [NSError errorWithDomain:@"com.bytebox.wave.rpc" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Enter the six-digit PIN shown by the bridge."}]);
        return;
    }
    [self disconnect];
    [self.serviceBrowser stop];
    self.serviceBrowser = nil;
    self.resolvingService = nil;
    self.pairingPIN = normalized;
    self.pairingCompletion = completion;
    self.serviceBrowser = [[NSNetServiceBrowser alloc] init];
    self.serviceBrowser.delegate = self;
    [self.serviceBrowser searchForServicesOfType:@"_wave-rpc._tcp." inDomain:@""];
}

- (void)pairWithQRPayload:(NSString *)payload completion:(void (^)(BOOL, NSError *))completion {
    NSURL *url = [NSURL URLWithString:[payload stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
    if (!url || ![url.scheme.lowercaseString isEqualToString:@"wave-rpc"] || ![url.host.lowercaseString isEqualToString:@"pair"]) {
        if (completion) completion(NO, [NSError errorWithDomain:@"com.bytebox.wave.rpc" code:5 userInfo:@{NSLocalizedDescriptionKey: @"This QR code is not a Wave RPC pairing code."}]);
        return;
    }
    NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
    for (NSString *part in [url.query componentsSeparatedByString:@"&"]) {
        NSArray *pair = [part componentsSeparatedByString:@"="];
        if (pair.count < 2) continue;
        NSString *key = [pair[0] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        NSString *value = [[pair subarrayWithRange:NSMakeRange(1, pair.count - 1)] componentsJoinedByString:@"="];
        parameters[key] = [value stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] ?: value;
    }
    NSString *host = parameters[@"host"];
    NSString *pin = parameters[@"pin"];
    NSInteger port = [parameters[@"port"] integerValue];
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if (!host.length || !pin.length || port < 1 || port > 65535 || pin.length != 6 || [pin rangeOfCharacterFromSet:nonDigits].location != NSNotFound) {
        if (completion) completion(NO, [NSError errorWithDomain:@"com.bytebox.wave.rpc" code:6 userInfo:@{NSLocalizedDescriptionKey: @"The QR pairing code is incomplete or invalid."}]);
        return;
    }
    [self disconnect];
    [self.serviceBrowser stop];
    self.serviceBrowser = nil;
    self.resolvingService = nil;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:host forKey:waRPCHostKey];
    [defaults setInteger:port forKey:waRPCPortKey];
    [defaults setObject:pin forKey:waRPCTokenKey];
    [defaults setBool:YES forKey:waRPCEnabledKey];
    self.host = host;
    self.port = (NSUInteger)port;
    self.token = pin;
    if (completion) completion(YES, nil);
    [[NSNotificationCenter defaultCenter] postNotificationName:waRPCClientDidChangeNotification object:self];
    [self connectIfNeeded];
}

- (void)shutdown {
    if (self.connected) [self sendDictionary:@{ @"type": @"shutdown", @"seq": @([self nextSequence]), @"reason": @"player_stopped" }];
    [self disconnect];
}

- (void)connectIfNeeded {
    if (self.connected || self.inputStream || self.reconnectTimer || !self.host.length || !self.token.length) return;
    self.intentionalDisconnect = NO;
    CFReadStreamRef readStream = NULL;
    CFWriteStreamRef writeStream = NULL;
    CFStreamCreatePairWithSocketToHost(NULL, (__bridge CFStringRef)self.host, (UInt32)self.port, &readStream, &writeStream);
    if (!readStream || !writeStream) {
        if (readStream) CFRelease(readStream);
        if (writeStream) CFRelease(writeStream);
        [self scheduleReconnect];
        return;
    }
    self.inputStream = (__bridge_transfer NSInputStream *)readStream;
    self.outputStream = (__bridge_transfer NSOutputStream *)writeStream;
    self.openedOutput = NO;
    self.inputStream.delegate = self;
    self.outputStream.delegate = self;
    [self.inputStream scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [self.outputStream scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [self.inputStream open];
    [self.outputStream open];
}

- (void)disconnect {
    self.intentionalDisconnect = YES;
    [self.heartbeatTimer invalidate];
    self.heartbeatTimer = nil;
    [self.reconnectTimer invalidate];
    self.reconnectTimer = nil;
    [self.inputStream close];
    [self.outputStream close];
    [self.inputStream removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [self.outputStream removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    self.inputStream = nil;
    self.outputStream = nil;
    self.writeBuffer = [NSMutableData data];
    self.openedOutput = NO;
    self.connected = NO;
}

- (BOOL)loadConfiguration {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *token = [defaults stringForKey:waRPCTokenKey];
    BOOL enabled = [defaults objectForKey:waRPCEnabledKey] ? [defaults boolForKey:waRPCEnabledKey] : token.length > 0;
    if (!enabled || !token.length) return NO;
    self.host = [defaults stringForKey:waRPCHostKey].length ? [defaults stringForKey:waRPCHostKey] : waRPCDefaultHost;
    self.port = [defaults integerForKey:waRPCPortKey] ? [defaults integerForKey:waRPCPortKey] : waRPCDefaultPort;
    self.token = token;
    return YES;
}

- (void)sendHello {
    NSString *deviceName = [UIDevice currentDevice].name;
    if (!deviceName.length) deviceName = @"iPhone";
    [self sendDictionary:@{ @"type": @"hello", @"device": deviceName, @"token": self.token }];
    self.connected = YES;
    [self.heartbeatTimer invalidate];
    self.heartbeatTimer = [NSTimer timerWithTimeInterval:2.0 target:self selector:@selector(sendHeartbeat:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.heartbeatTimer forMode:NSRunLoopCommonModes];
    [self sendPlayback];
}

- (void)sendPlayback {
    if (!self.connected || !self.lastTrackID.length) return;
    NSMutableDictionary *message = [@{ @"type": @"playback", @"seq": @([self nextSequence]), @"track_id": self.lastTrackID, @"title": self.lastTitle ?: @"", @"artist": self.lastArtist ?: @"", @"state": self.lastState ?: @"stopped", @"position_ms": @((NSUInteger)(self.lastPosition * 1000.0)), @"duration_ms": @((NSUInteger)(self.lastDuration * 1000.0)) } mutableCopy];
    if (self.lastAlbum.length) message[@"album"] = self.lastAlbum;
    if (self.lastArtworkURL.length) message[@"artwork_url"] = self.lastArtworkURL;
    [self sendDictionary:message];
}

- (void)sendHeartbeat:(NSTimer *)timer {
    if (!self.connected) return;
    [self sendDictionary:@{ @"type": @"heartbeat", @"seq": @([self nextSequence]), @"track_id": self.lastTrackID ?: @"", @"state": self.lastState ?: @"stopped", @"position_ms": @((NSUInteger)(self.lastPosition * 1000.0)), @"duration_ms": @((NSUInteger)(self.lastDuration * 1000.0)) }];
}

- (NSUInteger)nextSequence {
    self.sequence += 1;
    return self.sequence;
}

- (void)sendDictionary:(NSDictionary *)dictionary {
    if (!self.outputStream) return;
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dictionary options:0 error:&error];
    if (error || !data) return;
    NSMutableData *line = [data mutableCopy];
    [line appendBytes:"\n" length:1];
    if (self.writeBuffer.length + line.length > waRPCMaximumQueuedBytes) {
        self.writeBuffer = [NSMutableData data];
    }
    [self.writeBuffer appendData:line];
    [self drainWriteBuffer];
}

- (void)drainWriteBuffer {
    while (self.writeBuffer.length && self.outputStream.hasSpaceAvailable) {
        NSInteger written = [self.outputStream write:self.writeBuffer.bytes maxLength:self.writeBuffer.length];
        if (written <= 0) break;
        [self.writeBuffer replaceBytesInRange:NSMakeRange(0, (NSUInteger)written) withBytes:NULL length:0];
    }
}

- (void)readAvailableBytes {
    uint8_t bytes[4096];
    while (self.inputStream.hasBytesAvailable) {
        NSInteger length = [self.inputStream read:bytes maxLength:sizeof(bytes)];
        if (length <= 0) break;
        [self.readBuffer appendBytes:bytes length:(NSUInteger)length];
        while (YES) {
            const uint8_t newline = '\n';
            NSRange range = [self.readBuffer rangeOfData:[NSData dataWithBytes:&newline length:1] options:0 range:NSMakeRange(0, self.readBuffer.length)];
            if (range.location == NSNotFound) break;
            NSData *line = [self.readBuffer subdataWithRange:NSMakeRange(0, range.location)];
            [self.readBuffer replaceBytesInRange:NSMakeRange(0, range.location + 1) withBytes:NULL length:0];
            (void)[NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
        }
    }
}

- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)eventCode {
    if (eventCode == NSStreamEventOpenCompleted && stream == self.outputStream) {
        self.openedOutput = YES;
        [self sendHello];
    } else if (eventCode == NSStreamEventHasBytesAvailable && stream == self.inputStream) {
        [self readAvailableBytes];
    } else if (eventCode == NSStreamEventHasSpaceAvailable && stream == self.outputStream) {
        [self drainWriteBuffer];
    } else if (eventCode == NSStreamEventErrorOccurred || eventCode == NSStreamEventEndEncountered) {
        BOOL shouldReconnect = !self.intentionalDisconnect;
        [self disconnect];
        if (shouldReconnect) {
            self.intentionalDisconnect = NO;
            [self scheduleReconnect];
        }
    }
}

- (void)scheduleReconnect {
    if (self.intentionalDisconnect || self.reconnectTimer || !self.token.length) return;
    self.reconnectTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 target:self selector:@selector(reconnectTimerFired:) userInfo:nil repeats:NO];
}

- (void)reconnectTimerFired:(NSTimer *)timer {
    self.reconnectTimer = nil;
    [self connectIfNeeded];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self shutdown];
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didFindService:(NSNetService *)service moreComing:(BOOL)moreComing {
    (void)browser;
    (void)moreComing;
    if (self.resolvingService) return;
    self.resolvingService = service;
    self.resolvingService.delegate = self;
    [self.resolvingService resolveWithTimeout:5.0];
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didNotSearch:(NSDictionary *)errorDict {
    (void)browser;
    NSError *error = [NSError errorWithDomain:@"com.bytebox.wave.rpc" code:2 userInfo:@{NSLocalizedDescriptionKey: @"No Wave RPC bridge was found on this Wi-Fi network."}];
    [self finishPairingWithSuccess:NO error:error];
    (void)errorDict;
}

- (void)netServiceDidResolveAddress:(NSNetService *)sender {
    NSString *host = sender.hostName;
    if (!host.length || sender.port <= 0) {
        [self finishPairingWithSuccess:NO error:[NSError errorWithDomain:@"com.bytebox.wave.rpc" code:3 userInfo:@{NSLocalizedDescriptionKey: @"The bridge address could not be resolved."}]];
        return;
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:host forKey:waRPCHostKey];
    [defaults setInteger:sender.port forKey:waRPCPortKey];
    [defaults setObject:self.pairingPIN forKey:waRPCTokenKey];
    [defaults setBool:YES forKey:waRPCEnabledKey];
    self.host = host;
    self.port = (NSUInteger)sender.port;
    self.token = self.pairingPIN;
    [self finishPairingWithSuccess:YES error:nil];
    [self connectIfNeeded];
}

- (void)netService:(NSNetService *)sender didNotResolve:(NSDictionary *)errorDict {
    (void)sender;
    [self finishPairingWithSuccess:NO error:[NSError errorWithDomain:@"com.bytebox.wave.rpc" code:4 userInfo:@{NSLocalizedDescriptionKey: @"The Wave RPC bridge could not be reached."}]];
    (void)errorDict;
}

- (void)finishPairingWithSuccess:(BOOL)success error:(NSError *)error {
    [self.serviceBrowser stop];
    self.serviceBrowser = nil;
    self.resolvingService = nil;
    void (^completion)(BOOL, NSError *) = self.pairingCompletion;
    self.pairingCompletion = nil;
    if (completion) completion(success, error);
    [[NSNotificationCenter defaultCenter] postNotificationName:waRPCClientDidChangeNotification object:self];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self disconnect];
}

@end
