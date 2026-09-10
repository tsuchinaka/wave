#import <Foundation/Foundation.h>

typedef enum {
    waDownloadCategorySong = 0,
    waDownloadCategoryAlbum,
    waDownloadCategoryPlaylist
} waDownloadCategory;

typedef enum {
    waDownloadStateNotFound = -1,
    waDownloadStateQueued = 0,
    waDownloadStateDownloading,
    waDownloadStateCompleted,
    waDownloadStateFailed,
    waDownloadStateCancelled
} waDownloadState;

@interface waDownload : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *filePath;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy) NSString *albumName;
@property (nonatomic, copy) NSString *thumbnailURL;
@property (nonatomic, copy) NSString *artworkFilePath;
@property (nonatomic, copy) NSDictionary *metadata;
@property (nonatomic, assign) NSTimeInterval duration;
@property (nonatomic, assign, getter=isExplicit) BOOL explicit;
@property (nonatomic, assign) float progress;
@property (nonatomic, assign) waDownloadState state;
@property (nonatomic, copy) NSString *ticketURL;
@property (nonatomic, assign) NSUInteger downloadQuality;
@property (nonatomic, assign) unsigned long long bytesReceived;
@property (nonatomic, assign) long long bytesExpected;
@property (nonatomic, copy) NSDictionary *categoryContexts;
@property (nonatomic, assign) waDownloadCategory currentCategory;
@property (nonatomic, copy) NSString *currentContextIdentifier;
@property (nonatomic, copy) NSString *currentGroupTitle;
- (id)initWithIdentifier:(NSString *)identifier filePath:(NSString *)filePath;
- (void)addCategory:(waDownloadCategory)category contextIdentifier:(NSString *)contextIdentifier;
- (BOOL)belongsToCategory:(waDownloadCategory)category;
- (NSArray *)contextIdentifiersForCategory:(waDownloadCategory)category;
@end
