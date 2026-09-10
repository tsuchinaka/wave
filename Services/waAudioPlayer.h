#import <Foundation/Foundation.h>
#import "waContracts.h"
#import "../Models/waMediaItem.h"

extern NSString * const waAudioPlayerDidChangeNotification;
typedef NS_ENUM(NSUInteger, waRepeatMode) { waRepeatModeOff = 0, waRepeatModeAll = 1, waRepeatModeOne = 2 };

@interface waAudioPlayer : NSObject <waPlayerContract>
+ (waAudioPlayer *)sharedPlayer;
- (void)playSong:(NSString *)songIdentifier;
- (void)playDownloadedSong:(NSString *)songIdentifier filePath:(NSString *)filePath;
- (void)playItem:(waMediaItem *)item;
- (void)playItem:(waMediaItem *)item fromContext:(NSArray *)context title:(NSString *)contextTitle;
- (void)pause;
- (void)resume;
- (void)togglePlayPause;
- (void)stop;
// Sleep timer: pauses playback after the interval. Pass 0 to cancel.
- (void)setSleepTimerWithInterval:(NSTimeInterval)interval;
- (void)cancelSleepTimer;
@property (nonatomic, assign, readonly) NSTimeInterval sleepTimeRemaining;
- (void)playNext;
- (void)playPrevious;
- (void)playQueueItemAtIndex:(NSUInteger)index;
- (void)removeQueueItemAtIndex:(NSUInteger)index;
- (void)moveQueueItemAtIndex:(NSUInteger)fromIndex toIndex:(NSUInteger)toIndex;
- (void)clearQueue;
- (void)clearUpcomingQueue;
- (void)addItemToQueue:(waMediaItem *)item;
- (void)playItemNext:(waMediaItem *)item;
- (void)addItemsToQueue:(NSArray *)items;
- (void)playItemsNext:(NSArray *)items;
@property (nonatomic, strong, readonly) waMediaItem *currentItem;
@property (nonatomic, copy, readonly) NSString *qualityLabel;
@property (nonatomic, assign, readonly) double bitrateKbps;
@property (nonatomic, assign, readonly, getter=isLoading) BOOL loading;
@property (nonatomic, strong, readonly) NSError *lastError;
@property (nonatomic, copy, readonly) NSArray *queueItems;
@property (nonatomic, assign, readonly) NSUInteger queueIndex;
@property (nonatomic, copy, readonly) NSString *queueContextTitle;
@property (nonatomic, assign, readonly) NSTimeInterval persistedPlaybackPosition;
@property (nonatomic, assign, getter=isShuffleEnabled) BOOL shuffleEnabled;
@property (nonatomic, assign, getter=isRepeatEnabled) BOOL repeatEnabled;
@property (nonatomic, assign) waRepeatMode repeatMode;
@property (nonatomic, assign, getter=isGeniusEnabled) BOOL geniusEnabled;
@property (nonatomic, assign, readonly, getter=isGeniusAutoplayAllowed) BOOL geniusAutoplayAllowed;
@end
