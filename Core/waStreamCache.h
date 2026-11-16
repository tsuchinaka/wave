#import <Foundation/Foundation.h>

// Decrypted stream files, keyed by track instead of by signed URL.
//
// The signed URL carries a token that changes on every resolution, so hashing
// it into the file name threw the cache away on every launch: the track had to
// come down from the CDN again before a note played. One name per track keeps
// what was already decrypted and lets the source resume from disk.
@interface waStreamCache : NSObject

+ (NSString *)directory;
+ (NSString *)fileNameForTrackID:(NSString *)trackID extension:(NSString *)extension;
+ (NSString *)pathForTrackID:(NSString *)trackID extension:(NSString *)extension;

// The finished file for a track, mp3 first then flac, or nil when the copy is
// missing or was never completed.
+ (NSString *)completePathForTrackID:(NSString *)trackID;

+ (BOOL)isCompleteAtPath:(NSString *)path;
+ (void)markCompleteAtPath:(NSString *)path;
+ (void)clearCompletionAtPath:(NSString *)path;

@end
