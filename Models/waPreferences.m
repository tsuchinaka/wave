#import "waPreferences.h"
#import "../Services/waTheme.h"
#import <sys/sysctl.h>

static NSString * const waAPIURLKey = @"wa.apiURL";
static NSString * const waAPIPortKey = @"wa.apiPort";
static NSString * const waMaximumDownloadsKey = @"wa.maximumDownloads";
static NSString * const waCrossfadeKey = @"wa.crossfade";
static NSString * const waCrossfadeDurationKey = @"wa.crossfadeDuration";
static NSString * const waCacheSizeKey = @"wa.cacheSizeMB";
static NSString * const waThemeKey = @"wa.theme";
static NSString * const waCellularKey = @"wa.cellular";
static NSString * const waPrivateKey = @"wa.private";
static NSString * const waDeezerQualityKey = @"wa.deezerQuality";
static NSString * const waDownloadQualityKey = @"wa.downloadQuality";
static NSString * const waLastFMScrobblingKey = @"wa.lastfm.scrobbling";
static NSString * const waEQGainsKey = @"wa.eq.gains";
static NSString * const waEQPresetKey = @"wa.eq.preset";
static NSString * const waCompEnabledKey = @"wa.comp.enabled";
static NSString * const waCompStrengthKey = @"wa.comp.strength";

@implementation waPreferences
- (id)init { if ((self = [super init])) { NSDictionary *defaults = [NSDictionary dictionaryWithObjectsAndKeys:@1, waMaximumDownloadsKey, @256, waCacheSizeKey, @"Dark purple", waThemeKey, @YES, waCellularKey, @2, waDeezerQualityKey, nil]; [[NSUserDefaults standardUserDefaults] registerDefaults:defaults]; } return self; }
+ (waPreferences *)sharedPreferences { static waPreferences *preferences; static dispatch_once_t onceToken; dispatch_once(&onceToken, ^{ preferences = [[self alloc] init]; }); return preferences; }
- (NSUserDefaults *)defaults { return [NSUserDefaults standardUserDefaults]; }
- (NSString *)apiURL { return nil; }
- (void)setApiURL:(NSString *)value { (void)value; }
- (NSUInteger)apiPort { return 5000; }
- (void)setApiPort:(NSUInteger)value { (void)value; }
- (NSUInteger)waMaximumParallelCap {
    // A4 (iPhone3,x / 512MB) → cap 2, others → 5 (respect user choice)
    static NSUInteger cap = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        size_t size = 0;
        sysctlbyname("hw.machine", NULL, &size, NULL, 0);
        char *machine = malloc(size+1);
        if (machine) {
            sysctlbyname("hw.machine", machine, &size, NULL, 0);
            machine[size] = '\0';
            NSString *m = [NSString stringWithUTF8String:machine];
            free(machine);
            BOOL isA4 = [m hasPrefix:@"iPhone3,"] || [m hasPrefix:@"iPod4,"] || [m isEqualToString:@"iPad1,1"];
            if (isA4) { cap = 2; return; }
        }
        // Fallback: physical memory <= 512MB → A4
        int64_t mem = 0; size = sizeof(mem);
        if (sysctlbyname("hw.memsize", &mem, &size, NULL, 0) == 0 && mem > 0 && mem <= 512LL*1024*1024) cap = 2;
        else cap = 5;
    });
    return cap ?: 5;
}
- (NSUInteger)maximumParallelDownloads {
    NSInteger stored = [[self defaults] integerForKey:waMaximumDownloadsKey];
    if (stored <= 0) stored = 1;
    return MIN((NSUInteger)stored, [self waMaximumParallelCap]);
}
- (void)setMaximumParallelDownloads:(NSUInteger)value {
    NSUInteger cap = [self waMaximumParallelCap];
    value = MIN(MAX(value, (NSUInteger)1), cap);
    [[self defaults] setInteger:(NSInteger)value forKey:waMaximumDownloadsKey];
}
- (BOOL)crossfadeEnabled { return self.crossfadeDuration > 0.0; }
- (void)setCrossfadeEnabled:(BOOL)value { if (!value) self.crossfadeDuration = 0.0; else if (self.crossfadeDuration <= 0.0) self.crossfadeDuration = 1.0; }
- (NSTimeInterval)crossfadeDuration { NSUserDefaults *defaults = [self defaults]; if (![defaults objectForKey:waCrossfadeDurationKey] && [defaults boolForKey:waCrossfadeKey]) return 1.0; return MIN(15.0, MAX(0.0, [defaults doubleForKey:waCrossfadeDurationKey])); }
- (void)setCrossfadeDuration:(NSTimeInterval)value { NSTimeInterval duration = MIN(15.0, MAX(0.0, value)); [[self defaults] setDouble:duration forKey:waCrossfadeDurationKey]; [[self defaults] setBool:duration > 0.0 forKey:waCrossfadeKey]; }
- (NSUInteger)cacheSizeMB { return [[self defaults] integerForKey:waCacheSizeKey] ?: 256; }
- (void)setCacheSizeMB:(NSUInteger)value { [[self defaults] setInteger:MIN((NSUInteger)1024, MAX((NSUInteger)64, value)) forKey:waCacheSizeKey]; }
- (NSString *)theme {
    NSString *theme = [[self defaults] stringForKey:waThemeKey];
    NSArray *themes = [waTheme availableThemes];
    return [themes containsObject:theme] ? theme : @"Dark purple";
}
- (void)setTheme:(NSString *)value { [[self defaults] setObject:value forKey:waThemeKey]; [[NSNotificationCenter defaultCenter] postNotificationName:waThemeDidChangeNotification object:nil]; }
- (BOOL)cellularDataAllowed { return [[self defaults] objectForKey:waCellularKey] ? [[self defaults] boolForKey:waCellularKey] : YES; }
- (void)setCellularDataAllowed:(BOOL)value { [[self defaults] setBool:value forKey:waCellularKey]; }
- (BOOL)privateSession { return [[self defaults] boolForKey:waPrivateKey]; }
- (void)setPrivateSession:(BOOL)value { [[self defaults] setBool:value forKey:waPrivateKey]; }
- (NSUInteger)downloadQuality { NSUserDefaults *defaults = [self defaults]; id value = [defaults objectForKey:waDownloadQualityKey]; return MIN(2, value ? [defaults integerForKey:waDownloadQualityKey] : [defaults integerForKey:waDeezerQualityKey]); }
- (void)setDownloadQuality:(NSUInteger)value { [[self defaults] setInteger:MIN(2, value) forKey:waDownloadQualityKey]; }
- (NSUInteger)deezerQuality { return MIN(2, [[self defaults] integerForKey:waDeezerQualityKey]); }
- (void)setDeezerQuality:(NSUInteger)value { [[self defaults] setInteger:MIN(2, value) forKey:waDeezerQualityKey]; }
- (BOOL)lastFMScrobblingEnabled { return [[self defaults] boolForKey:waLastFMScrobblingKey]; }
- (void)setLastFMScrobblingEnabled:(BOOL)value { [[self defaults] setBool:value forKey:waLastFMScrobblingKey]; }
- (NSArray *)equalizerGains {
    NSArray *gains = [[self defaults] objectForKey:waEQGainsKey];
    if ([gains count] != 5) return @[@0, @0, @0, @0, @0];
    return gains;
}
- (void)setEqualizerGains:(NSArray *)value {
    if ([value count] != 5) return;
    [[self defaults] setObject:value forKey:waEQGainsKey];
}
- (NSString *)equalizerPreset { return [[self defaults] stringForKey:waEQPresetKey] ?: @"Flat"; }
- (void)setEqualizerPreset:(NSString *)value { [[self defaults] setObject:(value.length ? value : @"Flat") forKey:waEQPresetKey]; }
- (BOOL)compressorEnabled { return [[self defaults] objectForKey:waCompEnabledKey] ? [[self defaults] boolForKey:waCompEnabledKey] : YES; } // default ON gentle: catches EQ/transient overs after auto-gain (cheap envelope on A4)
- (void)setCompressorEnabled:(BOOL)value { [[self defaults] setBool:value forKey:waCompEnabledKey]; }
- (float)compressorStrength {
    if (![[self defaults] objectForKey:waCompStrengthKey]) return 10.0f; // -4.5 dB threshold: transient catcher, not a squasher
    float value = [[self defaults] floatForKey:waCompStrengthKey];
    if (value < 0.0f) value = 0.0f;
    if (value > 100.0f) value = 100.0f;
    return value;
}
- (void)setCompressorStrength:(float)value {
    if (value < 0.0f) value = 0.0f;
    if (value > 100.0f) value = 100.0f;
    [[self defaults] setFloat:value forKey:waCompStrengthKey];
}
@end
