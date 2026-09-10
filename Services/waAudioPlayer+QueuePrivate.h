#import "waAudioPlayer.h"

@interface waAudioPlayer (QueuePrivate)
@property (nonatomic, strong, readwrite) waMediaItem *currentItem;
@property (nonatomic, copy, readwrite) NSArray *queueItems;
@property (nonatomic, assign, readwrite) NSUInteger queueIndex;
@property (nonatomic, assign, readwrite) NSTimeInterval persistedPlaybackPosition;
@property (nonatomic, assign) NSUInteger geniusRequestGeneration;
@property (nonatomic, strong) NSMutableSet *shufflePlayedItems;
@property (nonatomic, strong) NSMutableArray *shuffleHistory;
@property (nonatomic, assign, getter=isShuffleEnabled) BOOL shuffleEnabled;
@property (nonatomic, assign, getter=isRepeatEnabled) BOOL repeatEnabled;
@property (nonatomic, assign) waRepeatMode repeatMode;
@property (nonatomic, assign, getter=isGeniusEnabled) BOOL geniusEnabled;
@property (nonatomic, assign, getter=isGeniusAutoplayAllowed) BOOL geniusAutoplayAllowed;
@property (nonatomic, assign) BOOL waitingForGenius;
@property (nonatomic, copy) NSString *geniusLoadingTrackID;
@property (nonatomic, assign) BOOL resumePositionPending;
@property (nonatomic, assign) BOOL persistingNewItem;
- (void)beginCurrentItem;
- (void)requestGeniusIfNeededForItem:(waMediaItem *)item;
- (void)invalidatePendingCrossfadeForQueueMutation;
- (void)persistQueue;
- (void)notifyChange;
@end
