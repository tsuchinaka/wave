#import <Foundation/Foundation.h>

// Reads container headers to recover the numbers Deezer's public API does not
// expose: real encoded bitrate, exact sample rate and frame count.
@interface waAudioProbe : NSObject
+ (double)bitrateKbpsFromMP3Data:(NSData *)data;
+ (BOOL)readFLACInfo:(NSData *)data bitrate:(double *)bitrate duration:(double *)duration;
+ (double)bitrateKbpsForFile:(NSString *)path;
@end
