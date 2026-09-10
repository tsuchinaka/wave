#import "waAudioPlayer.h"
#import "waAudioPlayer+QueuePrivate.h"
#import "../Audio/waAudioEngine.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation waAudioPlayer (Queue)

// Bound shuffle bookkeeping to the queue size so long Genius sessions
// cannot grow these collections without limit.
static void waTrimShuffleState(waAudioPlayer *player) {
    if (player.shuffleHistory.count > player.queueItems.count) {
        NSUInteger excess = player.shuffleHistory.count - player.queueItems.count;
        [player.shuffleHistory removeObjectsInRange:NSMakeRange(0, excess)];
    }
    if (player.shufflePlayedItems.count > player.queueItems.count) {
        NSSet *snapshot = [player.shufflePlayedItems copy];
        for (id object in snapshot) {
            if (![player.queueItems containsObject:object]) [player.shufflePlayedItems removeObject:object];
        }
        while (player.shufflePlayedItems.count > player.queueItems.count && player.shuffleHistory.count) {
            id oldest = player.shuffleHistory[0];
            [player.shuffleHistory removeObjectAtIndex:0];
            if (![player.shuffleHistory containsObject:oldest]) [player.shufflePlayedItems removeObject:oldest];
            else break;
        }
    }
}

- (void)playNext {
    if (!self.queueItems.count) return;
    if (self.repeatMode == waRepeatModeOne) { [self beginCurrentItem]; return; }
    if (self.shuffleEnabled && self.queueItems.count > 1) {
        NSMutableArray *candidates = [NSMutableArray array];
        for (waMediaItem *item in self.queueItems) if (![self.shufflePlayedItems containsObject:item]) [candidates addObject:item];
        if (!candidates.count) {
            if (self.repeatMode == waRepeatModeAll) {
                [self.shufflePlayedItems removeAllObjects];
                [self.shuffleHistory removeAllObjects];
                [self.shufflePlayedItems addObject:self.currentItem];
                [self.shuffleHistory addObject:self.currentItem];
                for (waMediaItem *item in self.queueItems) if (item != self.currentItem) [candidates addObject:item];
            } else {
                self.waitingForGenius = self.geniusEnabled && self.geniusAutoplayAllowed;
                [self requestGeniusIfNeededForItem:self.currentItem];
                return;
            }
        }
        NSUInteger next = (NSUInteger)arc4random_uniform((u_int32_t)candidates.count);
        waMediaItem *item = candidates[next];
        self.queueIndex = [self.queueItems indexOfObjectIdenticalTo:item];
        [self.shufflePlayedItems addObject:item];
        [self.shuffleHistory addObject:item];
        waTrimShuffleState(self);
    } else if (self.queueIndex + 1 < self.queueItems.count) self.queueIndex += 1;
    else if (self.repeatMode == waRepeatModeAll) self.queueIndex = 0;
    else {
        self.waitingForGenius = self.geniusEnabled && self.geniusAutoplayAllowed;
        [self requestGeniusIfNeededForItem:self.currentItem];
        return;
    }
    [self beginCurrentItem];
}
- (void)playPrevious {
    if (!self.queueItems.count) return;
    if ([waAudioEngine sharedEngine].currentTime > 3.0) { [[waAudioEngine sharedEngine] seekToTime:0.0]; return; }
    if (self.shuffleEnabled && self.shuffleHistory.count > 1) {
        [self.shuffleHistory removeLastObject];
        waMediaItem *previous = [self.shuffleHistory lastObject];
        NSUInteger previousIndex = [self.queueItems indexOfObjectIdenticalTo:previous];
        if (previousIndex != NSNotFound) { self.queueIndex = previousIndex; [self beginCurrentItem]; return; }
    }
    if (self.queueIndex > 0) self.queueIndex -= 1;
    else if (self.repeatMode != waRepeatModeOff) self.queueIndex = self.queueItems.count - 1;
    else return;
    [self beginCurrentItem];
}
- (void)playQueueItemAtIndex:(NSUInteger)index { if (index >= self.queueItems.count) return; self.queueIndex = index; self.persistedPlaybackPosition = 0.0; self.resumePositionPending = NO; if (self.shuffleEnabled) { [self.shufflePlayedItems removeAllObjects]; [self.shuffleHistory removeAllObjects]; waMediaItem *item = self.queueItems[index]; [self.shufflePlayedItems addObject:item]; [self.shuffleHistory addObject:item]; } self.currentItem = self.queueItems[index]; self.persistingNewItem = YES; [self persistQueue]; self.persistingNewItem = NO; [self beginCurrentItem]; }
- (void)removeQueueItemAtIndex:(NSUInteger)index {
    if (index >= self.queueItems.count) return;
    [self invalidatePendingCrossfadeForQueueMutation];
    self.geniusRequestGeneration += 1;
    BOOL removingCurrent = index == self.queueIndex;
    waMediaItem *removed = self.queueItems[index];
    [self.shufflePlayedItems removeObject:removed];
    [self.shuffleHistory removeObject:removed];
    NSMutableArray *items = [self.queueItems mutableCopy];
    [items removeObjectAtIndex:index];
    self.queueItems = items;
    waTrimShuffleState(self);
    if (!items.count) {
        self.queueIndex = 0;
        [self clearQueue];
        return;
    }
    if (index < self.queueIndex) self.queueIndex -= 1;
    else if (self.queueIndex >= items.count) self.queueIndex = items.count - 1;
    if (removingCurrent) {
        self.currentItem = self.queueItems[self.queueIndex];
        self.persistedPlaybackPosition = 0.0;
        self.persistingNewItem = YES;
        [self persistQueue];
        self.persistingNewItem = NO;
        [self beginCurrentItem];
    } else {
        [self persistQueue];
        [self notifyChange];
    }
}
- (void)moveQueueItemAtIndex:(NSUInteger)fromIndex toIndex:(NSUInteger)toIndex {
    if (fromIndex >= self.queueItems.count || toIndex >= self.queueItems.count || fromIndex == toIndex) return;
     [self invalidatePendingCrossfadeForQueueMutation];
     self.geniusRequestGeneration += 1;
    NSMutableArray *items = [self.queueItems mutableCopy];
    waMediaItem *item = items[fromIndex];
    [items removeObjectAtIndex:fromIndex];
    [items insertObject:item atIndex:toIndex];

    NSUInteger current = self.queueIndex;
    if (current == fromIndex) current = toIndex;
    else if (fromIndex < current && toIndex >= current) current -= 1;
    else if (fromIndex > current && toIndex <= current) current += 1;
    self.queueItems = items;
    self.queueIndex = current;
     waTrimShuffleState(self);
     [self persistQueue];
     [self notifyChange];
 }
- (void)clearQueue { [self invalidatePendingCrossfadeForQueueMutation]; self.geniusRequestGeneration += 1; self.queueItems = @[]; self.queueIndex = 0; self.currentItem = nil; self.persistedPlaybackPosition = 0.0; [self.shufflePlayedItems removeAllObjects]; [self.shuffleHistory removeAllObjects]; [self persistQueue]; [self stop]; [self notifyChange]; }
- (void)clearUpcomingQueue {
    if (!self.currentItem || self.queueIndex >= self.queueItems.count) { [self clearQueue]; return; }
    [self invalidatePendingCrossfadeForQueueMutation];
    self.geniusRequestGeneration += 1;
    waMediaItem *current = self.queueItems[self.queueIndex];
    self.queueItems = @[current];
    self.queueIndex = 0;
    [self.shufflePlayedItems removeAllObjects];
    [self.shuffleHistory removeAllObjects];
    if (self.shuffleEnabled) { [self.shufflePlayedItems addObject:current]; [self.shuffleHistory addObject:current]; }
    self.waitingForGenius = NO;
     self.geniusLoadingTrackID = nil;
    [self persistQueue];
    [self notifyChange];
}
- (void)addItemToQueue:(waMediaItem *)item {
    if (![item isKindOfClass:[waMediaItem class]]) return;
    if (!self.currentItem && !self.queueItems.count) { [self playItem:item]; return; }
    NSMutableArray *items = [self.queueItems mutableCopy];
    [items addObject:item];
     self.queueItems = items;
     waTrimShuffleState(self);
     [self persistQueue];
     [self notifyChange];
}
- (void)playItemNext:(waMediaItem *)item {
    if (![item isKindOfClass:[waMediaItem class]]) return;
    if (!self.currentItem && !self.queueItems.count) { [self playItem:item]; return; }
    [self invalidatePendingCrossfadeForQueueMutation];
    NSMutableArray *items = [self.queueItems mutableCopy];
    NSUInteger insertion = self.queueIndex < items.count ? self.queueIndex + 1 : items.count;
     [items insertObject:item atIndex:insertion];
     self.queueItems = items;
     waTrimShuffleState(self);
     [self persistQueue];
     [self notifyChange];
}
- (void)addItemsToQueue:(NSArray *)items {
    NSMutableArray *valid = [NSMutableArray array];
    for (id item in items) if ([item isKindOfClass:[waMediaItem class]]) [valid addObject:item];
    if (!valid.count) return;
    if (!self.currentItem && !self.queueItems.count) { [self playItem:valid[0] fromContext:valid title:nil]; return; }
    NSMutableArray *queue = [self.queueItems mutableCopy];
    [queue addObjectsFromArray:valid];
     self.queueItems = queue;
     waTrimShuffleState(self);
     [self persistQueue];
     [self notifyChange];
}
- (void)playItemsNext:(NSArray *)items {
    NSMutableArray *valid = [NSMutableArray array];
    for (id item in items) if ([item isKindOfClass:[waMediaItem class]]) [valid addObject:item];
    if (!valid.count) return;
    if (!self.currentItem && !self.queueItems.count) { [self playItem:valid[0] fromContext:valid title:nil]; return; }
    [self invalidatePendingCrossfadeForQueueMutation];
    NSMutableArray *queue = [self.queueItems mutableCopy];
    NSUInteger insertion = self.queueIndex < queue.count ? self.queueIndex + 1 : queue.count;
    [queue insertObjects:valid atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(insertion, valid.count)]];
    self.queueItems = queue;
     waTrimShuffleState(self);
     [self persistQueue];
     [self notifyChange];
}

@end
#pragma clang diagnostic pop
