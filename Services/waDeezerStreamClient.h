#import <Foundation/Foundation.h>

// Serverless Deezer streaming (Minuga-RC/deezer-tui port).
// getUserData -> pageTrack(TRACK_TOKEN) -> media.get_url(signed CDN) -> deezer:// URL.
// Quality: 0 = MP3_128, 1 = MP3_320, 2 = FLAC. Fallback steps down per track
// (FLAC->320->128) so a lossless denial never kills playback.
// The deezer:// URL carries the real container extension (.mp3/.flac) so the
// Origami plugin manager picks CoreAudioDecoder vs FlocDecoder correctly;
// HTTPSource decrypts BF_CBC_STRIPE in flight (see waDeezerBlowfish).
@interface waDeezerStreamClient : NSObject
+ (waDeezerStreamClient *)sharedClient;
- (NSString *)rawIdentifier:(NSString *)trackID;
// Playback URL for the audio engine (deezer:// scheme, decrypted in HTTPSource).
// resolvedQuality is the format actually granted (may step down from requested).
- (void)resolveStreamURLForTrackID:(NSString *)trackID quality:(NSUInteger)quality completion:(void (^)(NSURL *url, NSUInteger resolvedQuality, NSError *error))completion;
// Raw signed https CDN URL (for downloads, which decrypt before writing).
- (void)resolveCDNURLForTrackID:(NSString *)trackID quality:(NSUInteger)quality completion:(void (^)(NSURL *cdnURL, NSUInteger resolvedQuality, NSError *error))completion;
// Public metadata, no backend needed. Keys: title/artistName/albumName/duration/resolvedQuality.
- (void)fetchPublicTrackDetailsForTrackID:(NSString *)trackID completion:(void (^)(NSDictionary *details, NSError *error))completion;
// Serverless lyrics via hidden gw-light.php song.getLyrics (same ARL/checkForm as streaming).
// Returns normalized payload: plain (NSString), lineSynced (NSArray of @{time, text}), instrumental (BOOL), source.
- (void)fetchLyricsForTrackID:(NSString *)trackID completion:(void (^)(NSDictionary *payload, NSError *error))completion;
@end
