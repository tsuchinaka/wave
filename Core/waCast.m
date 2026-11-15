#import "waCast.h"
#import "waCrypto.h"
#import "waLog.h"
#import "waSession.h"
#import <AudioToolbox/AudioToolbox.h>
#import <QuartzCore/CABase.h>
#import <fcntl.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <netinet/in.h>
#import <pthread.h>
#import <stdlib.h>
#import <string.h>
#import <sys/socket.h>
#import <mbedtls/ctr_drbg.h>
#import <mbedtls/entropy.h>
#import <mbedtls/error.h>
#import <mbedtls/net_sockets.h>
#import <mbedtls/ssl.h>

NSString * const waCastDevicesDidChangeNotification = @"waCastDevicesDidChangeNotification";
NSString * const waCastStatusDidChangeNotification = @"waCastStatusDidChangeNotification";

static NSString * const waNSConnection = @"urn:x-cast:com.google.cast.tp.connection";
static NSString * const waNSHeartbeat = @"urn:x-cast:com.google.cast.tp.heartbeat";
static NSString * const waNSReceiver = @"urn:x-cast:com.google.cast.receiver";
static NSString * const waNSMedia = @"urn:x-cast:com.google.cast.media";
static NSString * const waSender = @"sender-0";
static NSString * const waReceiver = @"receiver-0";
static NSString * const waAppID = @"CC1AD845";

@implementation waCastDevice
@end

@interface waCast () <NSNetServiceBrowserDelegate, NSNetServiceDelegate>
@property (nonatomic, strong) NSNetServiceBrowser *browser;
@property (nonatomic, strong) NSMutableArray *found;
@property (nonatomic, strong) NSMutableArray *resolving;
@property (nonatomic, strong) waCastDevice *target;
@property (nonatomic, assign) BOOL connected;
@property (nonatomic, assign) NSTimeInterval mediaTime;
@property (nonatomic, assign) NSTimeInterval mediaDuration;
@property (nonatomic, assign) CFTimeInterval mediaStamp;
@property (nonatomic, assign) BOOL mediaPlaying;
@property (nonatomic, assign) NSInteger mediaSession;
@property (nonatomic, assign) NSInteger requestID;
@property (nonatomic, copy) NSString *transportID;
@property (nonatomic, copy) NSString *playingID;
@property (nonatomic, copy) NSString *preparedID;
@property (nonatomic, assign) int socketFD;
@property (nonatomic, assign) BOOL sessionRunning;
@property (nonatomic, assign) NSUInteger loadGeneration;
@property (nonatomic, assign) NSUInteger prepareGeneration;
@property (nonatomic, assign) NSUInteger sessionGeneration;
@property (nonatomic, copy) NSString *servePath;
@property (nonatomic, copy) NSString *serveType;
@property (nonatomic, assign) float receiverVolume;
@property (nonatomic, assign) CFTimeInterval sessionBegan;
- (BOOL)fileForName:(NSString *)name path:(NSString **)path type:(NSString **)type;
- (void)persistTarget;
- (void)restoreTarget;
@end

@implementation waCast {
    mbedtls_ssl_context _ssl;
    mbedtls_ssl_config _conf;
    mbedtls_entropy_context _entropy;
    mbedtls_ctr_drbg_context _drbg;
    pthread_mutex_t _writeLock;
    pthread_mutex_t _serveLock;
    NSMutableArray *_outgoing;
    NSMutableDictionary *_files;
    BOOL _tlsReady;
    int _listenFD;
    pthread_t _httpThread;
}

typedef struct {
    int fd;
    void *cast;
} waCastServeJob;

static int waCastSend(void *ctx, const unsigned char *buf, size_t len);
static int waCastRecv(void *ctx, unsigned char *buf, size_t len);
static void *waCastHTTP(void *context);
static void *waCastHTTPClient(void *arg);
static void waCastServe(int fd, waCast *cast);
static BOOL waCastWriteAll(int fd, const void *bytes, size_t length);
static NSString *waCastJSON(NSData *frame);
static NSString *waCastSafeID(NSString *trackID);
static NSString *waCastIDFromURL(NSString *url);
static NSString *waCastExt(NSURL *url, NSString *cdn);
static NSString *waCastTrackID(NSURL *url);
static NSString *waCastCipherName(NSURL *url);
static NSString *waCastCDN(NSURL *url);
static void waCastRouteListener(void *inClientData, AudioSessionPropertyID inID, UInt32 inDataSize, const void *inData);

+ (waCast *)shared {
    static waCast *cast;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cast = [[waCast alloc] init]; });
    return cast;
}

- (id)init {
    if ((self = [super init])) {
        _found = [NSMutableArray array];
        _resolving = [NSMutableArray array];
        _socketFD = -1;
        _listenFD = -1;
        _outgoing = [NSMutableArray array];
        _files = [NSMutableDictionary dictionary];
        _receiverVolume = 1.0f;
        pthread_mutex_init(&_writeLock, NULL);
        pthread_mutex_init(&_serveLock, NULL);
        mbedtls_ssl_init(&_ssl);
        mbedtls_ssl_config_init(&_conf);
        mbedtls_entropy_init(&_entropy);
        mbedtls_ctr_drbg_init(&_drbg);
        AudioSessionInitialize(NULL, NULL, NULL, NULL);
        AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange, waCastRouteListener, NULL);
        [self restoreTarget];
    }
    return self;
}

static void waCastRouteListener(void *inClientData, AudioSessionPropertyID inID, UInt32 inDataSize, const void *inData) {
    (void)inClientData;
    (void)inID;
    (void)inDataSize;
    (void)inData;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:waCastStatusDidChangeNotification object:[waCast shared]];
    });
}

- (NSString *)currentOutputType {
    CFDictionaryRef desc = NULL;
    UInt32 size = sizeof(desc);
    if (AudioSessionGetProperty(kAudioSessionProperty_AudioRouteDescription, &size, &desc) != noErr || !desc) return nil;
    NSDictionary *dict = (__bridge_transfer NSDictionary *)desc;
    NSArray *outputs = dict[(__bridge id)kAudioSession_AudioRouteKey_Outputs];
    if (![outputs isKindOfClass:[NSArray class]] || !outputs.count) return nil;
    NSDictionary *first = [outputs objectAtIndex:0];
    if (![first isKindOfClass:[NSDictionary class]]) return nil;
    id type = first[(__bridge id)kAudioSession_AudioRouteKey_Type];
    return [type isKindOfClass:[NSString class]] ? type : nil;
}

- (BOOL)airPlayActive {
    NSString *type = [self currentOutputType];
    return [type isEqualToString:(__bridge NSString *)kAudioSessionOutputRoute_AirPlay];
}

- (NSString *)airPlayName {
    if (!self.airPlayActive) return nil;
    CFStringRef route = NULL;
    UInt32 size = sizeof(route);
    if (AudioSessionGetProperty(kAudioSessionProperty_AudioRoute, &size, &route) == noErr && route) {
        NSString *name = (__bridge_transfer NSString *)route;
        if (name.length && ![name isEqualToString:@"AirPlay"] && ![name isEqualToString:@"AirTunes"]) return name;
    }
    return @"AirPlay";
}

- (NSArray *)devices { return [self.found copy]; }

- (NSTimeInterval)position {
    if (!self.mediaPlaying) return self.mediaTime;
    return self.mediaTime + (CACurrentMediaTime() - self.mediaStamp);
}

- (BOOL)playing { return self.mediaPlaying; }

- (NSTimeInterval)duration { return self.mediaDuration; }

- (float)volume { return self.receiverVolume; }

- (NSString *)contentID { return self.playingID; }

#pragma mark - discovery

- (void)startDiscovery {
    if (!self.browser) {
        self.browser = [[NSNetServiceBrowser alloc] init];
        self.browser.delegate = self;
    }
    [self.browser stop];
    [self.browser searchForServicesOfType:@"_googlecast._tcp." inDomain:@"local."];
    [[waLog shared] log:@"cast scan"];
    [self scanSubnet];
}

- (void)scanSubnet {
    NSString *mine = [self lanAddress];
    if (!mine.length) return;
    NSArray *parts = [mine componentsSeparatedByString:@"."];
    if (parts.count != 4) return;
    NSString *prefix = [NSString stringWithFormat:@"%@.%@.%@.", parts[0], parts[1], parts[2]];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        for (NSInteger host = 1; host < 255; host++) {
            NSString *ip = [prefix stringByAppendingFormat:@"%ld", (long)host];
            if ([ip isEqualToString:mine]) continue;
            int fd = socket(AF_INET, SOCK_STREAM, 0);
            if (fd < 0) continue;
            struct sockaddr_in addr;
            memset(&addr, 0, sizeof(addr));
            addr.sin_family = AF_INET;
            addr.sin_port = htons(8008);
            inet_pton(AF_INET, ip.UTF8String, &addr.sin_addr);
            int flags = fcntl(fd, F_GETFL, 0);
            fcntl(fd, F_SETFL, flags | O_NONBLOCK);
            connect(fd, (struct sockaddr *)&addr, sizeof(addr));
            fd_set set;
            FD_ZERO(&set);
            FD_SET(fd, &set);
            struct timeval wait = {0, 120000};
            int ready = select(fd + 1, NULL, &set, NULL, &wait);
            close(fd);
            if (ready <= 0) continue;
            [self nameDeviceAt:ip];
        }
    });
}

- (void)nameDeviceAt:(NSString *)ip {
    for (waCastDevice *have in self.found) if ([have.host isEqualToString:ip]) return;
    NSString *url = [NSString stringWithFormat:@"http://%@:8008/setup/eureka_info", ip];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:2.0];
    NSURLResponse *response = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:req returningResponse:&response error:NULL];
    if (!data.length) return;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![json isKindOfClass:[NSDictionary class]]) return;
    NSString *name = [json[@"name"] isKindOfClass:[NSString class]] ? json[@"name"] : nil;
    if (!name.length) return;
    waCastDevice *device = [[waCastDevice alloc] init];
    device.name = name;
    device.host = ip;
    device.port = 8009;
    NSString *model = nil;
    if ([json[@"model_name"] isKindOfClass:[NSString class]]) model = json[@"model_name"];
    device.model = model;
    dispatch_async(dispatch_get_main_queue(), ^{
        for (waCastDevice *have in self.found) if ([have.host isEqualToString:ip]) return;
        [self.found addObject:device];
        [[waLog shared] log:@"cast found %@ %@", name, ip];
        [self publishDevices];
    });
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didFindService:(NSNetService *)service moreComing:(BOOL)more {
    (void)browser;
    service.delegate = self;
    [self.resolving addObject:service];
    [service resolveWithTimeout:5.0];
    if (!more) [self publishDevices];
}

- (void)netServiceDidResolveAddress:(NSNetService *)service {
    NSString *host = nil;
    for (NSData *addr in service.addresses) {
        if (addr.length < sizeof(struct sockaddr_in)) continue;
        const struct sockaddr_in *sin = (const struct sockaddr_in *)addr.bytes;
        if (sin->sin_family != AF_INET) continue;
        char buf[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf));
        host = [NSString stringWithUTF8String:buf];
        break;
    }
    NSDictionary *txt = [NSNetService dictionaryFromTXTRecordData:service.TXTRecordData];
    NSData *fn = txt[@"fn"];
    NSData *md = txt[@"md"];
    NSString *name = fn.length ? [[NSString alloc] initWithData:fn encoding:NSUTF8StringEncoding] : service.name;
    NSString *model = md.length ? [[NSString alloc] initWithData:md encoding:NSUTF8StringEncoding] : nil;
    if (!host.length || !name.length) return;
    for (waCastDevice *have in self.found) if ([have.host isEqualToString:host]) return;
    waCastDevice *device = [[waCastDevice alloc] init];
    device.name = name;
    device.model = model;
    device.host = host;
    device.port = service.port > 0 ? service.port : 8009;
    [self.found addObject:device];
    [[waLog shared] log:@"cast found %@ %@", name, host];
    [self publishDevices];
}

- (void)netService:(NSNetService *)service didNotResolve:(NSDictionary *)error {
    (void)service; (void)error;
}

- (void)publishDevices {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:waCastDevicesDidChangeNotification object:self];
    });
}

#pragma mark - session

- (void)leaveApp {
    if (!_tlsReady) return;
    [[waLog shared] log:@"cast leave %@", self.target.name];
    if (self.transportID.length) {
        if (self.mediaSession) {
            [self sendJSON:@{@"type": @"STOP", @"mediaSessionId": @(self.mediaSession)} to:self.transportID namespace:waNSMedia];
        }
        [self sendTo:self.transportID namespace:waNSConnection json:@"{\"type\":\"CLOSE\"}"];
    }
    [self sendJSON:@{@"type": @"STOP"} to:waReceiver namespace:waNSReceiver];
    [self sendTo:waReceiver namespace:waNSConnection json:@"{\"type\":\"CLOSE\"}"];
}

- (void)selectDevice:(waCastDevice *)device {
    if (!device.host.length) return;
    if ([device.host isEqualToString:self.target.host] && self.sessionRunning) {
        self.target = device;
        [self publishStatus];
        return;
    }
    [self leaveApp];
    [[waLog shared] log:@"cast target %@", device.name];
    NSUInteger gen = ++self.sessionGeneration;
    self.target = device;
    self.sessionRunning = YES;
    self.sessionBegan = CACurrentMediaTime();
    self.transportID = nil;
    self.mediaSession = 0;
    self.mediaPlaying = NO;
    self.playingID = nil;
    [self persistTarget];
    [self publishStatus];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSInteger spins = 0;
        while (self.connected && gen == self.sessionGeneration && spins++ < 80) {
            [NSThread sleepForTimeInterval:0.05];
        }
        if (gen != self.sessionGeneration) return;
        if (!self.target.host.length) return;
        self.requestID = 1;
        [self runSession:device];
    });
}

- (void)clearTarget {
    [self leaveApp];
    self.sessionGeneration++;
    self.target = nil;
    self.sessionRunning = NO;
    self.transportID = nil;
    self.mediaSession = 0;
    self.mediaPlaying = NO;
    self.playingID = nil;
    self.loadGeneration++;
    [self persistTarget];
    [self publishStatus];
}

- (void)persistTarget {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (!self.target.host.length) {
        [defaults removeObjectForKey:@"wave.cast.host"];
        [defaults removeObjectForKey:@"wave.cast.name"];
        [defaults removeObjectForKey:@"wave.cast.model"];
        [defaults removeObjectForKey:@"wave.cast.port"];
        [defaults setBool:NO forKey:@"wave.cast.active"];
        return;
    }
    [defaults setObject:self.target.host forKey:@"wave.cast.host"];
    [defaults setObject:self.target.name ?: @"" forKey:@"wave.cast.name"];
    [defaults setObject:self.target.model ?: @"" forKey:@"wave.cast.model"];
    [defaults setInteger:self.target.port forKey:@"wave.cast.port"];
    [defaults setBool:YES forKey:@"wave.cast.active"];
}

- (void)restoreTarget {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults boolForKey:@"wave.cast.active"]) return;
    NSString *host = [defaults stringForKey:@"wave.cast.host"];
    if (!host.length) return;
    waCastDevice *device = [[waCastDevice alloc] init];
    device.host = host;
    device.name = [defaults stringForKey:@"wave.cast.name"] ?: host;
    device.model = [defaults stringForKey:@"wave.cast.model"];
    NSInteger port = [defaults integerForKey:@"wave.cast.port"];
    device.port = port > 0 ? port : 8009;
    self.target = device;
    [[waLog shared] log:@"cast restore %@", device.name];
}

- (void)recover {
    if (!self.target.host.length) return;
    if (self.connected) return;
    if (self.sessionRunning) {
        if (self.sessionBegan > 0 && CACurrentMediaTime() - self.sessionBegan < 8.0) return;
        [[waLog shared] log:@"cast recover reset"];
        self.sessionGeneration++;
        self.sessionRunning = NO;
        self.transportID = nil;
        [self closeTLS];
        self.connected = NO;
    }
    [[waLog shared] log:@"cast recover %@", self.target.name];
    [self ensureSession];
}

- (void)ensureSession {
    if (self.sessionRunning || !self.target.host.length) return;
    waCastDevice *device = self.target;
    NSUInteger gen = self.sessionGeneration;
    self.sessionRunning = YES;
    self.sessionBegan = CACurrentMediaTime();
    self.requestID = 1;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (gen != self.sessionGeneration) return;
        [self runSession:device];
    });
}

- (void)runSession:(waCastDevice *)device {
    NSUInteger gen = self.sessionGeneration;
    if (![self openTLS:device]) {
        if (self.sessionGeneration == gen) {
            self.sessionRunning = NO;
            self.connected = NO;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (self.sessionGeneration != gen) return;
                if (self.target.host.length && !self.connected && !self.sessionRunning) [self recover];
            });
        }
        [[waLog shared] log:@"cast tls failed %@", device.host];
        return;
    }
    [self sendTo:waReceiver namespace:waNSConnection json:@"{\"type\":\"CONNECT\",\"origin\":{}}"];
    [self sendJSON:@{@"type": @"GET_STATUS"} to:waReceiver namespace:waNSReceiver];
    NSMutableData *pending = [NSMutableData data];
    CFTimeInterval lastPing = CACurrentMediaTime();
    while (self.sessionRunning && self.target == device) {
        [self flushOutgoing];
        uint8_t buf[4096];
        int n = mbedtls_ssl_read(&_ssl, buf, sizeof(buf));
        if (n == MBEDTLS_ERR_SSL_WANT_READ || n == MBEDTLS_ERR_SSL_WANT_WRITE || n == MBEDTLS_ERR_SSL_TIMEOUT) {
            if (CACurrentMediaTime() - lastPing > 5.0) {
                [self sendJSON:@{@"type": @"PING"} to:waReceiver namespace:waNSHeartbeat];
                if (self.mediaSession && self.transportID.length) {
                    [self sendJSON:@{@"type": @"GET_STATUS", @"mediaSessionId": @(self.mediaSession)} to:self.transportID namespace:waNSMedia];
                }
                lastPing = CACurrentMediaTime();
            }
            continue;
        }
        if (n <= 0) {
            [[waLog shared] log:@"cast read %d", n];
            break;
        }
        [pending appendBytes:buf length:(NSUInteger)n];
        while (pending.length >= 4) {
            const uint8_t *bytes = pending.bytes;
            uint32_t len = ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) | bytes[3];
            if (len > 1024 * 1024 || pending.length < 4 + len) break;
            NSData *frame = [pending subdataWithRange:NSMakeRange(4, len)];
            [pending replaceBytesInRange:NSMakeRange(0, 4 + len) withBytes:NULL length:0];
            [self handleFrame:frame];
        }
    }
    [self flushOutgoing];
    [self closeTLS];
    self.connected = NO;
    if (self.sessionGeneration == gen) {
        self.sessionRunning = NO;
        self.transportID = nil;
        [self publishStatus];
        if (self.target.host.length) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (self.sessionGeneration != gen) return;
                if (self.target.host.length && !self.connected && !self.sessionRunning) [self recover];
            });
        }
    }
}

- (BOOL)openTLS:(waCastDevice *)device {
    [self closeTLS];
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)(device.port > 0 ? device.port : 8009));
    inet_pton(AF_INET, device.host.UTF8String, &addr.sin_addr);
    struct timeval tv = {8, 0};
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) { close(fd); return NO; }
    const char *personal = "wavecast";
    if (mbedtls_ctr_drbg_seed(&_drbg, mbedtls_entropy_func, &_entropy, (const unsigned char *)personal, strlen(personal)) != 0) {
        close(fd); return NO;
    }
    if (mbedtls_ssl_config_defaults(&_conf, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT) != 0) {
        close(fd); return NO;
    }
    mbedtls_ssl_conf_authmode(&_conf, MBEDTLS_SSL_VERIFY_NONE);
    mbedtls_ssl_conf_rng(&_conf, mbedtls_ctr_drbg_random, &_drbg);
    mbedtls_ssl_conf_min_version(&_conf, MBEDTLS_SSL_MAJOR_VERSION_3, MBEDTLS_SSL_MINOR_VERSION_3);
    if (mbedtls_ssl_setup(&_ssl, &_conf) != 0) { close(fd); return NO; }
    self.socketFD = fd;
    mbedtls_ssl_set_bio(&_ssl, &self->_socketFD, waCastSend, waCastRecv, NULL);
    int status = 0;
    while ((status = mbedtls_ssl_handshake(&_ssl)) != 0) {
        if (status != MBEDTLS_ERR_SSL_WANT_READ && status != MBEDTLS_ERR_SSL_WANT_WRITE) break;
    }
    if (status != 0) { [self closeTLS]; return NO; }
    struct timeval idle = {0, 200000};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &idle, sizeof(idle));
    _tlsReady = YES;
    self.connected = YES;
    [[waLog shared] log:@"cast tls %@", device.name];
    return YES;
}

static int waCastSend(void *ctx, const unsigned char *buf, size_t len) {
    int fd = *(int *)ctx;
    ssize_t n = send(fd, buf, len, 0);
    if (n < 0) return (errno == EAGAIN || errno == EINTR) ? MBEDTLS_ERR_SSL_WANT_WRITE : MBEDTLS_ERR_SSL_INTERNAL_ERROR;
    return (int)n;
}

static int waCastRecv(void *ctx, unsigned char *buf, size_t len) {
    int fd = *(int *)ctx;
    ssize_t n = recv(fd, buf, len, 0);
    if (n < 0) return (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR || errno == ETIMEDOUT) ? MBEDTLS_ERR_SSL_WANT_READ : MBEDTLS_ERR_SSL_INTERNAL_ERROR;
    if (n == 0) return MBEDTLS_ERR_SSL_CONN_EOF;
    return (int)n;
}

- (void)closeTLS {
    if (_tlsReady) {
        mbedtls_ssl_close_notify(&_ssl);
        _tlsReady = NO;
    }
    mbedtls_ssl_free(&_ssl);
    mbedtls_ssl_init(&_ssl);
    mbedtls_ssl_config_free(&_conf);
    mbedtls_ssl_config_init(&_conf);
    if (self.socketFD >= 0) {
        close(self.socketFD);
        self.socketFD = -1;
    }
}

- (void)handleFrame:(NSData *)frame {
    NSString *json = waCastJSON(frame);
    if (!json.length) return;
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    id parsed = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if (![parsed isKindOfClass:[NSDictionary class]]) return;
    NSString *type = parsed[@"type"];
    if ([type isEqualToString:@"PING"]) {
        [self sendJSON:@{@"type": @"PONG"} to:waReceiver namespace:waNSHeartbeat];
        return;
    }
    if ([type isEqualToString:@"RECEIVER_STATUS"]) {
        NSDictionary *status = parsed[@"status"];
        NSDictionary *vol = [status isKindOfClass:[NSDictionary class]] ? status[@"volume"] : nil;
        if ([vol isKindOfClass:[NSDictionary class]] && vol[@"level"]) {
            self.receiverVolume = [vol[@"level"] floatValue];
        }
        NSArray *apps = status[@"applications"];
        NSDictionary *app = [apps isKindOfClass:[NSArray class]] && apps.count ? apps[0] : nil;
        NSString *appID = [app[@"appId"] isKindOfClass:[NSString class]] ? app[@"appId"] : nil;
        NSString *transport = [app[@"transportId"] isKindOfClass:[NSString class]] ? app[@"transportId"] : nil;
        if (![appID isEqualToString:waAppID]) {
            self.transportID = nil;
            [self publishStatus];
            return;
        }
        if (transport.length && ![transport isEqualToString:self.transportID]) {
            self.transportID = transport;
            [self sendTo:transport namespace:waNSConnection json:@"{\"type\":\"CONNECT\",\"origin\":{}}"];
            [[waLog shared] log:@"cast app %@", transport];
        }
        [self publishStatus];
        return;
    }
    if ([type isEqualToString:@"MEDIA_STATUS"]) {
        NSArray *status = parsed[@"status"];
        NSDictionary *item = [status isKindOfClass:[NSArray class]] && status.count ? status[0] : nil;
        if (![item isKindOfClass:[NSDictionary class]]) return;
        self.mediaSession = [item[@"mediaSessionId"] integerValue];
        if (item[@"currentTime"]) self.mediaTime = [item[@"currentTime"] doubleValue];
        self.mediaStamp = CACurrentMediaTime();
        NSDictionary *media = item[@"media"];
        if ([media isKindOfClass:[NSDictionary class]]) {
            if (media[@"duration"]) self.mediaDuration = [media[@"duration"] doubleValue];
            NSString *content = [media[@"contentId"] isKindOfClass:[NSString class]] ? media[@"contentId"] : nil;
            NSString *parsedID = waCastIDFromURL(content);
            if (parsedID.length) self.playingID = parsedID;
        }
        NSString *state = item[@"playerState"];
        self.mediaPlaying = [state isEqualToString:@"PLAYING"] || [state isEqualToString:@"BUFFERING"];
        [[waLog shared] log:@"cast media %@ t=%.1f", state, self.mediaTime];
        NSString *idle = item[@"idleReason"];
        [self publishStatus];
        if ([state isEqualToString:@"IDLE"] && [idle isEqualToString:@"FINISHED"]) {
            NSUInteger gen = self.loadGeneration;
            NSString *finishedID = [self.playingID copy];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (gen != self.loadGeneration) return;
                if (finishedID.length && self.playingID.length && ![finishedID isEqualToString:self.playingID]) return;
                [[NSNotificationCenter defaultCenter] postNotificationName:@"waCastTrackDidFinish" object:self];
            });
        }
    }
}

- (void)publishStatus {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:waCastStatusDidChangeNotification object:self];
    });
}

#pragma mark - protocol

static NSData *waProtoVarint(NSUInteger n) {
    uint8_t buf[10];
    NSUInteger i = 0;
    do {
        uint8_t b = n & 0x7f;
        n >>= 7;
        if (n) b |= 0x80;
        buf[i++] = b;
    } while (n && i < sizeof(buf));
    return [NSData dataWithBytes:buf length:i];
}

static NSData *waProtoString(int field, NSString *value) {
    NSData *bytes = [value dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    NSMutableData *out = [NSMutableData dataWithBytes:(uint8_t[]){(uint8_t)((field << 3) | 2)} length:1];
    [out appendData:waProtoVarint(bytes.length)];
    [out appendData:bytes];
    return out;
}

static NSData *waProtoVar(int field, NSUInteger value) {
    NSMutableData *out = [NSMutableData dataWithBytes:(uint8_t[]){(uint8_t)(field << 3)} length:1];
    [out appendData:waProtoVarint(value)];
    return out;
}

static NSString *waCastJSON(NSData *frame) {
    const uint8_t *p = frame.bytes;
    NSUInteger n = frame.length, i = 0;
    while (i < n) {
        uint8_t key = p[i++];
        int field = key >> 3;
        int wire = key & 7;
        if (wire == 0) {
            while (i < n && (p[i++] & 0x80)) {}
        } else if (wire == 2) {
            NSUInteger len = 0, shift = 0;
            while (i < n) {
                uint8_t b = p[i++];
                len |= (NSUInteger)(b & 0x7f) << shift;
                if (!(b & 0x80)) break;
                shift += 7;
            }
            if (field == 6 && i + len <= n) return [[NSString alloc] initWithBytes:p + i length:len encoding:NSUTF8StringEncoding];
            i += len;
        } else break;
    }
    return nil;
}

static NSString *waCastSafeID(NSString *trackID) {
    if (!trackID.length) return @"x";
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < trackID.length; i++) {
        unichar c = [trackID characterAtIndex:i];
        if ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '-' || c == '_') {
            [out appendFormat:@"%C", c];
        }
    }
    return out.length ? out : @"x";
}

static NSString *waCastIDFromURL(NSString *url) {
    if (!url.length) return nil;
    NSString *last = url.lastPathComponent;
    if ([last hasPrefix:@"cast-"]) last = [last substringFromIndex:5];
    last = [last stringByDeletingPathExtension];
    return last.length ? last : nil;
}

static NSString *waCastExt(NSURL *url, NSString *cdn) {
    NSString *ext = url.pathExtension;
    if (!ext.length && cdn.length) {
        NSURL *cdnURL = [NSURL URLWithString:cdn];
        ext = cdnURL.pathExtension;
    }
    if (!ext.length) ext = @"mp3";
    if ([ext isEqualToString:@"flac"]) return @"flac";
    return @"mp3";
}

static NSString *waCastTrackID(NSURL *url) {
    return waCastSafeID([[url lastPathComponent] stringByDeletingPathExtension]);
}

static NSString *waCastCipherName(NSURL *url) {
    for (NSString *pair in [url.query componentsSeparatedByString:@"&"]) {
        if ([pair hasPrefix:@"c="]) return [pair substringFromIndex:2];
    }
    return nil;
}

static NSString *waCastCDN(NSURL *url) {
    for (NSString *pair in [url.query componentsSeparatedByString:@"&"]) {
        if ([pair hasPrefix:@"u="]) return [[pair substringFromIndex:2] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    }
    return nil;
}

- (void)sendJSON:(NSDictionary *)object to:(NSString *)dest namespace:(NSString *)ns {
    NSMutableDictionary *body = [object mutableCopy];
    if (!body[@"requestId"] && ![body[@"type"] isEqualToString:@"CONNECT"] && ![body[@"type"] isEqualToString:@"PING"] && ![body[@"type"] isEqualToString:@"PONG"]) {
        body[@"requestId"] = @(self.requestID++);
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    NSString *text = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    [self sendTo:dest namespace:ns json:text];
}

- (void)sendTo:(NSString *)dest namespace:(NSString *)ns json:(NSString *)json {
    NSMutableData *body = [NSMutableData data];
    [body appendData:waProtoVar(1, 0)];
    [body appendData:waProtoString(2, waSender)];
    [body appendData:waProtoString(3, dest ?: waReceiver)];
    [body appendData:waProtoString(4, ns)];
    [body appendData:waProtoVar(5, 0)];
    [body appendData:waProtoString(6, json ?: @"{}")];
    uint32_t len = (uint32_t)body.length;
    uint8_t prefix[4] = {(uint8_t)(len >> 24), (uint8_t)(len >> 16), (uint8_t)(len >> 8), (uint8_t)len};
    NSMutableData *frame = [NSMutableData dataWithBytes:prefix length:4];
    [frame appendData:body];
    pthread_mutex_lock(&_writeLock);
    [_outgoing addObject:frame];
    pthread_mutex_unlock(&_writeLock);
}

- (void)flushOutgoing {
    if (!_tlsReady) return;
    pthread_mutex_lock(&_writeLock);
    NSArray *batch = [_outgoing copy];
    [_outgoing removeAllObjects];
    pthread_mutex_unlock(&_writeLock);
    for (NSData *frame in batch) {
        const uint8_t *bytes = frame.bytes;
        size_t left = frame.length;
        while (left) {
            int n = mbedtls_ssl_write(&_ssl, bytes, left);
            if (n == MBEDTLS_ERR_SSL_WANT_READ || n == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
            if (n <= 0) return;
            bytes += n;
            left -= (size_t)n;
        }
    }
}

- (void)pause {
    if (!self.mediaSession || !self.transportID.length) return;
    [self sendJSON:@{@"type": @"PAUSE", @"mediaSessionId": @(self.mediaSession)} to:self.transportID namespace:waNSMedia];
    self.mediaPlaying = NO;
    self.mediaTime = self.position;
    self.mediaStamp = CACurrentMediaTime();
    [self publishStatus];
}

- (void)play {
    if (!self.mediaSession || !self.transportID.length) return;
    [self sendJSON:@{@"type": @"PLAY", @"mediaSessionId": @(self.mediaSession)} to:self.transportID namespace:waNSMedia];
    self.mediaPlaying = YES;
    self.mediaStamp = CACurrentMediaTime();
    [self publishStatus];
}

- (void)seekTo:(NSTimeInterval)time {
    if (!self.mediaSession || !self.transportID.length) return;
    if (time < 0.0) time = 0.0;
    [self sendJSON:@{@"type": @"SEEK", @"mediaSessionId": @(self.mediaSession), @"currentTime": @(time)} to:self.transportID namespace:waNSMedia];
    self.mediaTime = time;
    self.mediaStamp = CACurrentMediaTime();
    [self publishStatus];
}

- (void)setVolume:(float)volume {
    volume = MAX(0.0f, MIN(1.0f, volume));
    self.receiverVolume = volume;
    [self sendJSON:@{@"type": @"SET_VOLUME", @"volume": @{@"level": @(volume)}} to:waReceiver namespace:waNSReceiver];
    [self publishStatus];
}

- (void)stopPlayback {
    if (self.mediaSession && self.transportID.length) {
        [self sendJSON:@{@"type": @"STOP", @"mediaSessionId": @(self.mediaSession)} to:self.transportID namespace:waNSMedia];
    }
    self.loadGeneration++;
    self.mediaPlaying = NO;
    self.mediaTime = 0;
    self.playingID = nil;
    [self publishStatus];
}

#pragma mark - serve and load

- (NSString *)lanAddress {
    struct ifaddrs *list = NULL;
    NSString *found = nil;
    if (getifaddrs(&list) == 0) {
        for (struct ifaddrs *ifa = list; ifa; ifa = ifa->ifa_next) {
            if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
            if (strncmp(ifa->ifa_name, "en", 2) != 0) continue;
            char buf[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &((struct sockaddr_in *)ifa->ifa_addr)->sin_addr, buf, sizeof(buf));
            NSString *ip = [NSString stringWithUTF8String:buf];
            if ([ip hasPrefix:@"127."]) continue;
            found = ip;
            break;
        }
        freeifaddrs(list);
    }
    return found;
}

- (void)registerFile:(NSString *)path name:(NSString *)name type:(NSString *)type {
    if (!path.length || !name.length) return;
    pthread_mutex_lock(&_serveLock);
    _files[name] = @{@"path": path, @"type": type.length ? type : @"audio/mpeg"};
    pthread_mutex_unlock(&_serveLock);
}

- (BOOL)fileForName:(NSString *)name path:(NSString **)path type:(NSString **)type {
    pthread_mutex_lock(&_serveLock);
    NSDictionary *info = name.length ? _files[name] : nil;
    if (!info && self.servePath.length && ![name hasPrefix:@"cast-art"]) {
        info = @{@"path": self.servePath, @"type": self.serveType.length ? self.serveType : @"audio/mpeg"};
    }
    pthread_mutex_unlock(&_serveLock);
    if (![info isKindOfClass:[NSDictionary class]]) return NO;
    if (path) *path = info[@"path"];
    if (type) *type = info[@"type"];
    return (*path).length > 0;
}

- (NSString *)largestArtworkURL:(NSString *)url {
    if (!url.length) return url;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"[0-9]+x[0-9]+-" options:0 error:NULL];
    if (!re) return url;
    return [re stringByReplacingMatchesInString:url options:0 range:NSMakeRange(0, url.length) withTemplate:@"1920x1920-"];
}

- (NSData *)fetchArtwork:(NSString *)url {
    if (!url.length) return nil;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15.0];
    [req setValue:@"Wave/1.0" forHTTPHeaderField:@"User-Agent"];
    return [NSURLConnection sendSynchronousRequest:req returningResponse:NULL error:NULL];
}

- (NSString *)prepareArtwork:(NSString *)artwork trackID:(NSString *)trackID {
    if (!artwork.length || !trackID.length) return nil;
    NSString *name = [NSString stringWithFormat:@"cast-art-%@.jpg", trackID];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    NSData *data = nil;
    if ([artwork hasPrefix:@"/"] && [[NSFileManager defaultManager] fileExistsAtPath:artwork]) {
        data = [NSData dataWithContentsOfFile:artwork];
    } else if ([artwork hasPrefix:@"http://"] || [artwork hasPrefix:@"https://"]) {
        NSString *large = [self largestArtworkURL:artwork];
        data = [self fetchArtwork:large];
        if (!data.length && ![large isEqualToString:artwork]) data = [self fetchArtwork:artwork];
        if (!data.length) [[waLog shared] log:@"cast art fail"];
    }
    if (!data.length) return nil;
    [data writeToFile:path atomically:YES];
    [self registerFile:path name:name type:@"image/jpeg"];
    NSString *ip = [self lanAddress];
    if (!ip.length) return nil;
    [[waLog shared] log:@"cast art %lu bytes", (unsigned long)data.length];
    return [NSString stringWithFormat:@"http://%@:8765/%@", ip, name];
}

- (NSDictionary *)mediaForName:(NSString *)name type:(NSString *)type title:(NSString *)title artist:(NSString *)artist album:(NSString *)album artwork:(NSString *)artwork duration:(NSTimeInterval)duration {
    NSString *ip = [self lanAddress];
    if (!ip.length) return nil;
    NSString *url = [NSString stringWithFormat:@"http://%@:8765/%@", ip, name];
    NSString *safeTitle = title.length ? title : @"Unknown";
    NSMutableDictionary *meta = [NSMutableDictionary dictionary];
    meta[@"metadataType"] = @3;
    meta[@"type"] = @3;
    meta[@"title"] = safeTitle;
    meta[@"songName"] = safeTitle;
    if (artist.length) {
        meta[@"artist"] = artist;
        meta[@"albumArtist"] = artist;
        meta[@"subtitle"] = artist;
    }
    if (album.length) meta[@"albumName"] = album;
    if (artwork.length) {
        meta[@"images"] = [NSArray arrayWithObject:@{@"url": artwork, @"width": @1920, @"height": @1920}];
    }
    NSMutableDictionary *media = [NSMutableDictionary dictionary];
    media[@"contentId"] = url;
    media[@"contentType"] = type.length ? type : @"audio/mpeg";
    media[@"streamType"] = @"BUFFERED";
    media[@"metadata"] = meta;
    if (duration > 0.0) media[@"duration"] = [NSNumber numberWithDouble:duration];
    return media;
}

- (void)loadName:(NSString *)name path:(NSString *)path type:(NSString *)type title:(NSString *)title artist:(NSString *)artist album:(NSString *)album artwork:(NSString *)artwork duration:(NSTimeInterval)duration startAt:(NSTimeInterval)startAt trackID:(NSString *)trackID {
    if (!path.length || !self.target) return;
    [self ensureSession];
    self.servePath = path;
    self.serveType = type;
    [self registerFile:path name:name type:type];
    [self startServer];
    self.playingID = trackID;
    self.mediaDuration = duration;
    self.mediaTime = MAX(0.0, startAt);
    self.mediaStamp = CACurrentMediaTime();
    self.mediaPlaying = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *artURL = [self prepareArtwork:artwork trackID:trackID];
        NSDictionary *media = [self mediaForName:name type:type title:title artist:artist album:album artwork:artURL duration:duration];
        if (!media) { [[waLog shared] log:@"cast no lan address"]; return; }
        NSMutableDictionary *load = [NSMutableDictionary dictionary];
        load[@"type"] = @"LOAD";
        load[@"autoplay"] = [NSNumber numberWithBool:YES];
        load[@"media"] = media;
        load[@"currentTime"] = @(startAt > 0.4 ? startAt : 0.0);
        for (NSInteger i = 0; i < 40 && !self.connected; i++) [NSThread sleepForTimeInterval:0.25];
        if (!self.transportID.length) {
            [self sendJSON:@{@"type": @"LAUNCH", @"appId": waAppID} to:waReceiver namespace:waNSReceiver];
            for (NSInteger i = 0; i < 40 && !self.transportID.length; i++) [NSThread sleepForTimeInterval:0.25];
        }
        if (!self.transportID.length) { [[waLog shared] log:@"cast no app"]; return; }
        [self sendJSON:load to:self.transportID namespace:waNSMedia];
        [[waLog shared] log:@"cast load %@ title=%@ art=%@ dur=%.0f", media[@"contentId"], title, artURL, duration];
        [self publishStatus];
    });
}

- (void)startServer {
    if (_listenFD >= 0) return;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(8765);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 8) != 0) {
        [[waLog shared] log:@"cast listen failed"];
        close(fd);
        return;
    }
    _listenFD = fd;
    pthread_create(&_httpThread, NULL, waCastHTTP, (__bridge void *)self);
    [[waLog shared] log:@"cast serve 8765"];
}

static void *waCastHTTP(void *context) {
    waCast *cast = (__bridge waCast *)context;
    while (cast->_listenFD >= 0) {
        struct sockaddr_in client;
        socklen_t len = sizeof(client);
        int fd = accept(cast->_listenFD, (struct sockaddr *)&client, &len);
        if (fd < 0) continue;
        waCastServeJob *job = calloc(1, sizeof(*job));
        if (!job) { close(fd); continue; }
        job->fd = fd;
        job->cast = context;
        pthread_t thread;
        if (pthread_create(&thread, NULL, waCastHTTPClient, job) != 0) {
            waCastServe(fd, cast);
            close(fd);
            free(job);
        } else {
            pthread_detach(thread);
        }
    }
    return NULL;
}

static void *waCastHTTPClient(void *arg) {
    waCastServeJob *job = arg;
    waCast *cast = (__bridge waCast *)job->cast;
    int fd = job->fd;
    free(job);
    waCastServe(fd, cast);
    close(fd);
    return NULL;
}

static void waCastServe(int fd, waCast *cast) {
    char header[2048];
    ssize_t got = recv(fd, header, sizeof(header) - 1, 0);
    if (got <= 0) return;
    header[got] = 0;
    NSString *req = [NSString stringWithUTF8String:header] ?: @"";
    BOOL headOnly = [req hasPrefix:@"HEAD "];
    NSString *name = nil;
    if ([req hasPrefix:@"GET "] || headOnly) {
        NSString *rest = [req substringFromIndex:headOnly ? 5 : 4];
        NSRange sp = [rest rangeOfString:@" "];
        NSString *uri = sp.location != NSNotFound ? [rest substringToIndex:sp.location] : rest;
        if ([uri hasPrefix:@"/"]) uri = [uri substringFromIndex:1];
        NSRange q = [uri rangeOfString:@"?"];
        if (q.location != NSNotFound) uri = [uri substringToIndex:q.location];
        name = uri;
    }
    NSString *path = nil;
    NSString *type = nil;
    [cast fileForName:name path:&path type:&type];
    if (!path.length) {
        NSString *nf = @"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        NSData *body = [nf dataUsingEncoding:NSUTF8StringEncoding];
        waCastWriteAll(fd, body.bytes, body.length);
        return;
    }
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:path];
    unsigned long long size = 0;
    if (file) {
        @try { size = [file seekToEndOfFile]; } @catch (NSException *e) { (void)e; }
    }
    unsigned long long start = 0, end = size ? size - 1 : 0;
    NSRange range = [req rangeOfString:@"Range: bytes="];
    if (range.location != NSNotFound && size) {
        NSString *spec = [req substringFromIndex:range.location + range.length];
        NSArray *parts = [[spec componentsSeparatedByString:@"\r"][0] componentsSeparatedByString:@"-"];
        if (parts.count) start = (unsigned long long)[[parts objectAtIndex:0] longLongValue];
        if (parts.count > 1 && [[parts objectAtIndex:1] length]) end = (unsigned long long)[[parts objectAtIndex:1] longLongValue];
        if (end >= size) end = size - 1;
        if (start > end) start = 0;
    }
    BOOL partial = range.location != NSNotFound && size;
    unsigned long long count = size && end >= start ? end - start + 1 : 0;
    NSString *mime = type.length ? type : @"audio/mpeg";
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"HTTP/1.1 %d %@\r\n", partial ? 206 : 200, partial ? @"Partial Content" : @"OK"];
    [out appendFormat:@"Content-Type: %@\r\n", mime];
    [out appendFormat:@"Content-Length: %llu\r\n", count];
    [out appendString:@"Accept-Ranges: bytes\r\n"];
    [out appendString:@"Cache-Control: no-store\r\n"];
    [out appendString:@"Connection: close\r\n"];
    if (partial) [out appendFormat:@"Content-Range: bytes %llu-%llu/%llu\r\n", start, end, size];
    [out appendString:@"\r\n"];
    NSData *head = [out dataUsingEncoding:NSUTF8StringEncoding];
    if (!waCastWriteAll(fd, head.bytes, head.length)) return;
    if (headOnly || !file || !count) return;
    @try { [file seekToFileOffset:start]; } @catch (NSException *e) { return; }
    unsigned long long left = count;
    while (left) {
        @autoreleasepool {
            NSUInteger chunk = (NSUInteger)MIN(left, (unsigned long long)16 * 1024);
            NSData *piece = nil;
            @try { piece = [file readDataOfLength:chunk]; } @catch (NSException *e) { break; }
            if (!piece.length) break;
            if (!waCastWriteAll(fd, piece.bytes, piece.length)) break;
            left -= piece.length;
        }
    }
}

static BOOL waCastWriteAll(int fd, const void *bytes, size_t length) {
    const uint8_t *p = bytes;
    while (length) {
        ssize_t n = send(fd, p, length, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        p += n;
        length -= (size_t)n;
    }
    return YES;
}

- (void)playStream:(NSURL *)url title:(NSString *)title artist:(NSString *)artist album:(NSString *)album artwork:(NSString *)artwork duration:(NSTimeInterval)duration startAt:(NSTimeInterval)startAt {
    if (!self.target || !url) return;
    NSUInteger generation = ++self.loadGeneration;
    if (url.isFileURL) {
        NSString *ext = url.pathExtension.length ? url.pathExtension : @"mp3";
        NSString *trackID = waCastSafeID([[url lastPathComponent] stringByDeletingPathExtension]);
        NSString *name = [NSString stringWithFormat:@"cast-%@.%@", trackID, ext];
        NSString *type = [ext isEqualToString:@"flac"] ? @"audio/flac" : @"audio/mpeg";
        [self loadName:name path:url.path type:type title:title artist:artist album:album artwork:artwork duration:duration startAt:startAt trackID:trackID];
        return;
    }
    NSString *cdn = waCastCDN(url);
    NSString *trackID = waCastTrackID(url);
    NSString *ext = waCastExt(url, cdn);
    NSString *name = [NSString stringWithFormat:@"cast-%@.%@", trackID, ext];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    NSString *type = [ext isEqualToString:@"flac"] ? @"audio/flac" : @"audio/mpeg";
    if ([self.preparedID isEqualToString:trackID] && [[NSFileManager defaultManager] fileExistsAtPath:path]) {
        self.preparedID = nil;
        [self loadName:name path:path type:type title:title artist:artist album:album artwork:artwork duration:duration startAt:startAt trackID:trackID];
        return;
    }
    self.prepareGeneration++;
    if (!cdn.length) { [[waLog shared] log:@"cast no cdn"]; return; }
    waCipher cipher = waCipherFromName(waCastCipherName(url).UTF8String);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL ok = [self download:cdn to:path cipher:cipher trackID:trackID generation:generation];
        if (!ok || generation != self.loadGeneration) return;
        [self registerFile:path name:name type:type];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.loadGeneration) return;
            [self loadName:name path:path type:type title:title artist:artist album:album artwork:artwork duration:duration startAt:startAt trackID:trackID];
        });
    });
}

- (void)prepareStream:(NSURL *)url title:(NSString *)title artist:(NSString *)artist album:(NSString *)album artwork:(NSString *)artwork duration:(NSTimeInterval)duration {
    (void)title; (void)artist; (void)album; (void)artwork; (void)duration;
    if (!self.target || !url || url.isFileURL) return;
    NSString *cdn = waCastCDN(url);
    NSString *trackID = waCastTrackID(url);
    if (!cdn.length || !trackID.length) return;
    if ([trackID isEqualToString:self.preparedID] || [trackID isEqualToString:self.playingID]) return;
    NSUInteger generation = ++self.prepareGeneration;
    NSString *ext = waCastExt(url, cdn);
    NSString *name = [NSString stringWithFormat:@"cast-%@.%@", trackID, ext];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    NSString *type = [ext isEqualToString:@"flac"] ? @"audio/flac" : @"audio/mpeg";
    waCipher cipher = waCipherFromName(waCastCipherName(url).UTF8String);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL ok = [self download:cdn to:path cipher:cipher trackID:trackID generation:0];
        if (!ok || generation != self.prepareGeneration) return;
        [self registerFile:path name:name type:type];
        self.preparedID = trackID;
        [[waLog shared] log:@"cast primed %@", trackID];
    });
}

- (BOOL)download:(NSString *)cdn to:(NSString *)path cipher:(waCipher)cipher trackID:(NSString *)trackID generation:(NSUInteger)generation {
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *out = [NSFileHandle fileHandleForWritingAtPath:path];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:cdn] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:60.0];
    [req setValue:@"Wave/1.0" forHTTPHeaderField:@"User-Agent"];
    NSURLResponse *response = nil;
    NSError *error = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:req returningResponse:&response error:&error];
    if (generation && generation != self.loadGeneration) return NO;
    if (!data.length) { [[waLog shared] log:@"cast download %@", error.localizedDescription]; return NO; }
    waCryptor *cryptor = waCryptorCreateCipher(trackID.UTF8String, cipher);
    NSMutableData *buf = [data mutableCopy];
    unsigned long index = 0;
    int audioOK = 1;
    long consumed = waCryptorConsume(cryptor, &index, buf.mutableBytes, buf.length, &audioOK);
    if (consumed > 0) {
        @try { [out writeData:[NSData dataWithBytes:buf.bytes length:(NSUInteger)consumed]]; } @catch (NSException *e) { (void)e; }
    }
    if (buf.length > (NSUInteger)MAX(consumed, 0)) {
        NSData *tail = [buf subdataWithRange:NSMakeRange((NSUInteger)MAX(consumed, 0), buf.length - (NSUInteger)MAX(consumed, 0))];
        NSMutableData *rest = [tail mutableCopy];
        waCryptorStripe(cryptor, index, rest.mutableBytes, rest.length);
        @try { [out writeData:rest]; } @catch (NSException *e) { (void)e; }
    }
    waCryptorFree(cryptor);
    @try { [out closeFile]; } @catch (NSException *e) { (void)e; }
    [[waLog shared] log:@"cast file %llu", (unsigned long long)data.length];
    return consumed > 0 && audioOK;
}

@end
