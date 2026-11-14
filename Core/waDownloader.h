#import <Foundation/Foundation.h>
#import "waModel.h"
#import "waSession.h"
#import "waLyrics.h"

typedef enum {
    waDownloadQueued = 0,
    waDownloadResolving,
    waDownloadDownloading,
    waDownloadCompleted,
    waDownloadFailed,
    waDownloadCancelled
} waDownloadState;

typedef enum {
    waDownloadSortRecent = 0,
    waDownloadSortTitle,
    waDownloadSortArtist
} waDownloadSort;

extern NSString * const waDownloaderDidChangeNotification;

@interface waDownload : NSObject
@property (nonatomic, copy) NSString *trackID;
@property (nonatomic, strong) waTrack *track;
@property (nonatomic, copy) NSString *fileName;
@property (nonatomic, copy) NSString *filePath;
@property (nonatomic, assign) waDownloadState state;
@property (nonatomic, assign) float progress;
@property (nonatomic, assign) unsigned long long bytesReceived;
@property (nonatomic, assign) unsigned long long bytesExpected;
@property (nonatomic, assign) waQuality quality;
@property (nonatomic, copy) NSString *format;
@property (nonatomic, copy) NSString *errorMessage;
@property (nonatomic, assign) NSTimeInterval addedAt;
@property (nonatomic, assign) BOOL hasLyrics;
@end

@interface waDownloadCollection : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *kind;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *artistName;
@property (nonatomic, copy) NSString *artworkURL;
@property (nonatomic, strong) NSArray *trackIDs;
@end

@interface waDownloader : NSObject
+ (waDownloader *)shared;
@property (nonatomic, readonly) NSArray *downloads;
@property (nonatomic, assign) NSUInteger maximumParallel;
@property (nonatomic, assign) waDownloadSort sort;
- (void)enqueueTrack:(waTrack *)track quality:(waQuality)quality;
- (void)enqueueTracks:(NSArray *)tracks quality:(waQuality)quality collection:(waDownloadCollection *)collection;
- (void)cancelDownload:(waDownload *)download;
- (void)removeDownload:(waDownload *)download;
- (void)removeCollection:(waDownloadCollection *)collection;
- (void)retryDownload:(waDownload *)download;
- (BOOL)isDownloadedTrackID:(NSString *)trackID;
- (NSString *)localPathForTrackID:(NSString *)trackID;
- (NSString *)localArtworkPathForTrack:(waTrack *)track;
- (NSString *)localArtworkPathForAlbumID:(NSString *)albumID;
- (waLyrics *)localLyricsForTrackID:(NSString *)trackID;
- (void)storeLyrics:(waLyrics *)lyrics forTrackID:(NSString *)trackID;
- (unsigned long long)downloadedBytes;
- (NSArray *)activeDownloads;
- (NSArray *)completedDownloads;
- (NSArray *)completedTracks;
- (NSArray *)albumCollections;
- (NSArray *)playlistCollections;
- (NSArray *)tracksForCollection:(waDownloadCollection *)collection;
- (waAlbum *)albumForCollection:(waDownloadCollection *)collection;
- (waPlaylist *)playlistForCollection:(waDownloadCollection *)collection;
- (NSUInteger)activeCount;
- (NSUInteger)completedCount;
- (NSUInteger)pendingCount;
@end
