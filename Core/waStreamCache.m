#import "waStreamCache.h"

static NSString *waStreamCacheMarker(NSString *path) {
    return [path stringByAppendingString:@".done"];
}

@implementation waStreamCache

+ (NSString *)directory {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    if (!paths.count) return nil;
    return [[paths objectAtIndex:0] stringByAppendingPathComponent:@"StreamCache"];
}

+ (NSString *)fileNameForTrackID:(NSString *)trackID extension:(NSString *)extension {
    NSString *ident = trackID.length ? trackID : @"stream";
    NSString *ext = extension.length ? extension : @"mp3";
    return [NSString stringWithFormat:@"%@.%@", ident, ext];
}

+ (NSString *)pathForTrackID:(NSString *)trackID extension:(NSString *)extension {
    NSString *dir = [self directory];
    if (!dir.length) return nil;
    return [dir stringByAppendingPathComponent:[self fileNameForTrackID:trackID extension:extension]];
}

+ (BOOL)isCompleteAtPath:(NSString *)path {
    if (!path.length) return NO;
    NSFileManager *manager = [NSFileManager defaultManager];
    if (![manager fileExistsAtPath:waStreamCacheMarker(path)]) return NO;
    NSDictionary *attributes = [manager attributesOfItemAtPath:path error:NULL];
    return [attributes fileSize] > 0;
}

+ (void)markCompleteAtPath:(NSString *)path {
    if (!path.length) return;
    NSData *empty = [NSData data];
    [[NSFileManager defaultManager] createFileAtPath:waStreamCacheMarker(path) contents:empty attributes:nil];
}

+ (void)clearCompletionAtPath:(NSString *)path {
    if (!path.length) return;
    [[NSFileManager defaultManager] removeItemAtPath:waStreamCacheMarker(path) error:NULL];
}

+ (NSString *)completePathForTrackID:(NSString *)trackID {
    if (!trackID.length) return nil;
    NSArray *extensions = [NSArray arrayWithObjects:@"mp3", @"flac", nil];
    for (NSString *extension in extensions) {
        NSString *path = [self pathForTrackID:trackID extension:extension];
        if ([self isCompleteAtPath:path]) return path;
    }
    return nil;
}

@end
