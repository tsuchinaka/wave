#import <Foundation/Foundation.h>

// Tags written straight into the audio file, so a download keeps its own
// metadata when it leaves the app: another phone, a computer, any player.
//
// Keys shared by the reader and the writer:
//   title, artist, album, track, disc, year, trackID, albumID, artistID
@interface waTags : NSObject

// Returns nil when the file carries no readable ID3v2 or Vorbis comment block.
+ (NSDictionary *)tagsAtPath:(NSString *)path format:(NSString *)format;

// ID3v2.3, the version iTunes 10 and old players agree on. Replaces any
// existing ID3v2 tag and copies the audio frames untouched. Never writes in
// place: the tagged copy is renamed over the original only after it is whole.
+ (BOOL)writeID3v23ToPath:(NSString *)path fields:(NSDictionary *)fields cover:(NSData *)cover error:(NSError **)error;

@end
