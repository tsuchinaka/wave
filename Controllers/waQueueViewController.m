#import "waQueueViewController.h"
#import "../Services/waAudioPlayer.h"
#import "../Services/waImageLoader.h"
#import "../Views/waPlaceholder.h"
#import "../Views/waArtworkCell.h"
#import "../Services/waTheme.h"
#import "../Views/waMediaActionSheet.h"
#import "../Services/waDownloadManager.h"
#import "../Views/waActions.h"

@interface waQueueViewController () <UIAlertViewDelegate, UIActionSheetDelegate>
@property (nonatomic, strong) UIButton *shuffleButton;
@property (nonatomic, strong) UIButton *repeatButton;
@property (nonatomic, strong) UIButton *autoplayButton;
@property (nonatomic, strong) UIButton *sleepButton;
@property (nonatomic, strong) UILabel *queueSummaryLabel;
@property (nonatomic, assign) BOOL tableMutationInProgress;
@property (nonatomic, assign) BOOL queueUpdateScheduled;
@property (nonatomic, assign) BOOL downloadReloadScheduled;
@property (nonatomic, assign) NSUInteger lastKnownQueueCount;
@property (nonatomic, assign) NSUInteger lastKnownQueueIndex;
// Cached button tint state: updateButtons re-tints 3-4 icons per call, so
// skip the graphics work unless shuffle/repeat/genius/context changed.
@property (nonatomic, assign) BOOL buttonsCacheValid;
@property (nonatomic, assign) BOOL lastButtonsShuffleOn;
@property (nonatomic, assign) NSInteger lastButtonsRepeatMode;
@property (nonatomic, assign) BOOL lastButtonsGeniusOn;
@property (nonatomic, copy) NSString *lastButtonsContext;
// Sleep countdown text changes every second while the expensive icon
// re-tinting only needs a 15s bucket (see updateButtons).
@property (nonatomic, copy) NSString *lastButtonsSleepBucket;
// Cached summary: total duration is O(n), recompute only on count change.
@property (nonatomic, assign) NSUInteger lastSummaryCount;
@end

@implementation waQueueViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Queue";
    self.buttonsCacheValid = NO;
    UIBarButtonItem *actions = [[UIBarButtonItem alloc] initWithTitle:@"Actions" style:UIBarButtonItemStyleBordered target:self action:@selector(showActions:)];
    self.navigationItem.rightBarButtonItems = @[self.editButtonItem, actions];
    self.tableView.backgroundColor = [waTheme backgroundColor];
    self.tableView.backgroundView = [[UIView alloc] initWithFrame:CGRectZero];
    self.tableView.backgroundView.backgroundColor = [waTheme backgroundColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    self.tableView.separatorColor = [waTheme separatorColor];
    self.tableView.tableHeaderView = [self controlsView];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(queueDidChange:) name:waAudioPlayerDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeDidChange:) name:waThemeDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(downloadDidChange:) name:waDownloadManagerDidChangeNotification object:nil];
    [self updateButtons];
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    longPress.minimumPressDuration = 0.55;
    [self.tableView addGestureRecognizer:longPress];
}

- (UIView *)controlsView {
    UIView *view = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, self.view.bounds.size.width, 98.0)];
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    view.backgroundColor = [waTheme backgroundColor];
    self.shuffleButton = [self buttonWithTitle:@"Shuffle" action:@selector(toggleShuffle:)];
    self.repeatButton = [self buttonWithTitle:@"Repeat" action:@selector(toggleRepeat:)];
    self.autoplayButton = [self buttonWithTitle:@"Genius" action:@selector(toggleGenius:)];
    self.sleepButton = [self buttonWithTitle:@"Sleep" action:@selector(sleepPressed:)];
    self.sleepButton.titleLabel.font = [waTheme boldFontOfSize:13.0];
    [view addSubview:self.shuffleButton]; [view addSubview:self.repeatButton]; [view addSubview:self.autoplayButton]; [view addSubview:self.sleepButton];
    [self.shuffleButton setImage:[UIImage imageNamed:@"WaveShuffleOff"] forState:UIControlStateNormal];
    [self.repeatButton setImage:[UIImage imageNamed:@"WaveRepeatOff"] forState:UIControlStateNormal];
    [self.autoplayButton setImage:[UIImage imageNamed:@"WaveGenius"] forState:UIControlStateNormal];
    UILabel *context = [[UILabel alloc] initWithFrame:CGRectMake(12.0, 48.0, view.bounds.size.width - 24.0, 24.0)];
    context.tag = 90; context.autoresizingMask = UIViewAutoresizingFlexibleWidth; context.font = [waTheme regularFontOfSize:12.0]; context.textAlignment = NSTextAlignmentCenter; context.textColor = [waTheme secondaryTextColor]; context.backgroundColor = [UIColor clearColor];
    [view addSubview:context];
    self.queueSummaryLabel = [[UILabel alloc] initWithFrame:CGRectMake(12.0, 72.0, view.bounds.size.width - 24.0, 20.0)];
    self.queueSummaryLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.queueSummaryLabel.font = [waTheme secondaryRegularFontOfSize:11.0];
    self.queueSummaryLabel.textAlignment = NSTextAlignmentCenter;
    self.queueSummaryLabel.textColor = [waTheme secondaryTextColor];
    self.queueSummaryLabel.backgroundColor = [UIColor clearColor];
    [view addSubview:self.queueSummaryLabel];
    return view;
}
- (UIButton *)buttonWithTitle:(NSString *)title action:(SEL)action { UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom]; button.backgroundColor = [UIColor clearColor]; [button setTitle:title forState:UIControlStateNormal]; [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside]; return button; }
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; CGFloat width = self.tableView.bounds.size.width; CGFloat gap = 8.0; CGFloat buttonWidth = (width - 5.0 * gap) / 4.0; self.shuffleButton.frame = CGRectMake(gap, 8.0, buttonWidth, 34.0); self.repeatButton.frame = CGRectMake(2.0 * gap + buttonWidth, 8.0, buttonWidth, 34.0); self.autoplayButton.frame = CGRectMake(3.0 * gap + buttonWidth * 2.0, 8.0, buttonWidth, 34.0); self.sleepButton.frame = CGRectMake(4.0 * gap + buttonWidth * 3.0, 8.0, buttonWidth, 34.0); }
- (void)updateButtons {
    waAudioPlayer *player = [waAudioPlayer sharedPlayer];
    BOOL shuffleOn = player.isShuffleEnabled;
    NSInteger repeatMode = player.repeatMode;
    BOOL geniusOn = player.isGeniusEnabled && player.isGeniusAutoplayAllowed;
    NSString *contextText = player.queueContextTitle.length ? [NSString stringWithFormat:@"From %@", player.queueContextTitle] : @"Your current queue";
    // Sleep countdown text is cheap (setTitle); the icon re-tinting below
    // is not, so it only depends on a 15s bucket of the remaining time.
    NSTimeInterval sleepRemaining = player.sleepTimeRemaining;
    BOOL sleepOn = sleepRemaining > 0.0;
    NSString *sleepText = sleepOn ? [NSString stringWithFormat:@"%d:%02d", (int)(sleepRemaining / 60.0), ((int)sleepRemaining) % 60] : @"Sleep";
    NSString *sleepBucket = sleepOn ? [NSString stringWithFormat:@"%ld", (long)(sleepRemaining / 15.0)] : @"off";
    [self.sleepButton setTitle:sleepText forState:UIControlStateNormal];
    [self.sleepButton setTitleColor:sleepOn ? [waTheme barColor] : [waTheme secondaryTextColor] forState:UIControlStateNormal];
    if (self.buttonsCacheValid
        && shuffleOn == self.lastButtonsShuffleOn
        && repeatMode == self.lastButtonsRepeatMode
        && geniusOn == self.lastButtonsGeniusOn
        && ((sleepBucket == self.lastButtonsSleepBucket) || [sleepBucket isEqualToString:self.lastButtonsSleepBucket])
        && ((contextText == self.lastButtonsContext) || [contextText isEqualToString:self.lastButtonsContext])) {
        [self updateQueueSummaryIfNeeded];
        return;
    }
    self.buttonsCacheValid = YES;
    self.lastButtonsShuffleOn = shuffleOn;
    self.lastButtonsRepeatMode = repeatMode;
    self.lastButtonsGeniusOn = geniusOn;
    self.lastButtonsSleepBucket = sleepBucket;
    self.lastButtonsContext = contextText;
    [self.shuffleButton setTitle:nil forState:UIControlStateNormal];
    [self.repeatButton setTitle:nil forState:UIControlStateNormal];
    [self.autoplayButton setTitle:nil forState:UIControlStateNormal];
    UIColor *themeColor = [waTheme barColor];
    UIColor *inactiveColor = [waTheme secondaryTextColor];
    [self.shuffleButton setImage:[waTheme tintedIcon:[UIImage imageNamed:player.isShuffleEnabled ? @"WaveShuffleOn" : @"WaveShuffleOff"] withColor:player.isShuffleEnabled ? themeColor : inactiveColor] forState:UIControlStateNormal];
    // Repeat currently means repeating the current item, so use Apple's
    // repeat-one glyph rather than the generic repeat-all glyph.
    UIImage *repeatImage = player.repeatMode == waRepeatModeOne ? [UIImage imageNamed:@"WaveRepeatOne"] : (player.repeatMode == waRepeatModeAll ? [UIImage imageNamed:@"WaveRepeatOn"] : [UIImage imageNamed:@"WaveRepeatOff"]);
    UIColor *repeatColor = player.repeatMode == waRepeatModeOff ? inactiveColor : themeColor;
    [self.repeatButton setImage:[waTheme tintedIcon:repeatImage withColor:repeatColor] forState:UIControlStateNormal];
    [self.autoplayButton setImage:[waTheme tintedIcon:[UIImage imageNamed:@"WaveGenius"] withColor:(player.isGeniusEnabled && player.isGeniusAutoplayAllowed) ? themeColor : inactiveColor] forState:UIControlStateNormal];
    UILabel *context = (UILabel *)[self.tableView.tableHeaderView viewWithTag:90];
    context.text = player.queueContextTitle.length ? [NSString stringWithFormat:@"From %@", player.queueContextTitle] : @"Your current queue";
    [self updateQueueSummary];
}
- (void)updateQueueSummary {
    self.lastSummaryCount = [waAudioPlayer sharedPlayer].queueItems.count;
    NSArray *items = [waAudioPlayer sharedPlayer].queueItems;
    NSTimeInterval total = 0.0;
    for (waMediaItem *item in items) if (isfinite(item.duration) && item.duration > 0.0) total += item.duration;
    NSInteger seconds = MAX(0, (NSInteger)total);
    self.queueSummaryLabel.text = [NSString stringWithFormat:@"%lu %@ • %ld:%02ld", (unsigned long)items.count, items.count == 1 ? @"song" : @"songs", (long)(seconds / 60), (long)(seconds % 60)];
}
- (void)updateQueueSummaryIfNeeded {
    // Total duration is O(n): only rescan when the item count changed.
    // Durations arriving late for the same count refresh on the next
    // count change or viewWillAppear.
    if ([waAudioPlayer sharedPlayer].queueItems.count == self.lastSummaryCount) return;
    [self updateQueueSummary];
}
- (void)themeDidChange:(NSNotification *)notification { self.tableView.separatorColor = [waTheme separatorColor]; self.buttonsCacheValid = NO; [self updateButtons]; [self.tableView reloadData]; }
- (void)reloadDownloadTable { self.downloadReloadScheduled = NO; if (self.view.window) [self updateVisibleDownloadStates]; }
- (void)updateVisibleDownloadStates {
    NSArray *paths = [self.tableView indexPathsForVisibleRows];
    if (!paths.count) return;
    NSArray *items = [waAudioPlayer sharedPlayer].queueItems;
    for (NSIndexPath *path in paths) {
        if (path.row >= items.count) continue;
        waArtworkCell *cell = (waArtworkCell *)[self.tableView cellForRowAtIndexPath:path];
        if (![cell isKindOfClass:[waArtworkCell class]]) continue;
        waMediaItem *item = items[path.row];
        NSString *downloadIdentifier = item.trackId.length ? item.trackId : item.identifier;
        waDownload *download = [[waDownloadManager sharedManager] downloadForIdentifier:downloadIdentifier];
        [cell setDownloadState:download ? download.state : waDownloadStateNotFound progress:download.progress];
    }
}
- (void)finishTableMutation {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(finishTableMutation) object:nil];
    self.tableMutationInProgress = NO;
    if (!self.view.window) return;
    // The model was changed before the row animation started. Do one final
    // reconciliation after it completes so player notifications cannot erase
    // the transition halfway through.
    [self updateButtons];
    [self updateQueueSummary];
    self.lastKnownQueueCount = [waAudioPlayer sharedPlayer].queueItems.count;
    self.lastKnownQueueIndex = [waAudioPlayer sharedPlayer].queueIndex;
    [self.tableView reloadData];
    [self scrollToCurrentItem];
}

- (void)beginTableMutation {
    self.tableMutationInProgress = YES;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(finishTableMutation) object:nil];
    [self performSelector:@selector(finishTableMutation) withObject:nil afterDelay:0.35];
}

- (void)downloadDidChange:(NSNotification *)notification {
    if (!self.view.window) return;
    if (self.tableMutationInProgress) return;
    if ([notification.userInfo[@"event"] isEqualToString:@"progress"]) {
        if (self.downloadReloadScheduled) return;
        self.downloadReloadScheduled = YES;
        [self performSelector:@selector(reloadDownloadTable) withObject:nil afterDelay:0.4];
    } else [self updateVisibleDownloadStates];
}
- (void)toggleShuffle:(id)sender { [waAudioPlayer sharedPlayer].shuffleEnabled = ![waAudioPlayer sharedPlayer].isShuffleEnabled; [self updateButtons]; }
- (void)toggleRepeat:(id)sender { waAudioPlayer *player = [waAudioPlayer sharedPlayer]; player.repeatMode = (waRepeatMode)((player.repeatMode + 1) % 3); player.repeatEnabled = player.repeatMode != waRepeatModeOff; [self updateButtons]; }

- (void)sleepPressed:(id)sender {
    (void)sender;
    NSTimeInterval remaining = [waAudioPlayer sharedPlayer].sleepTimeRemaining;
    NSString *title = @"Sleep Timer";
    if (remaining > 0.0) title = [title stringByAppendingFormat:@" (on: %d:%02d)", (int)(remaining / 60.0), ((int)remaining) % 60];
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:title delegate:self cancelButtonTitle:@"Cancel" destructiveButtonTitle:nil otherButtonTitles:@"Off", @"15 minutes", @"30 minutes", @"45 minutes", @"60 minutes", nil];
    sheet.tag = 702;
    [sheet showInView:self.tabBarController ? self.tabBarController.view : self.view];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)index {
    if (sheet.tag != 702 || index == sheet.cancelButtonIndex) return;
    NSString *choice = [sheet buttonTitleAtIndex:index];
    waAudioPlayer *player = [waAudioPlayer sharedPlayer];
    if ([choice isEqualToString:@"Off"]) [player cancelSleepTimer];
    else if ([choice hasPrefix:@"15"]) [player setSleepTimerWithInterval:15.0 * 60.0];
    else if ([choice hasPrefix:@"30"]) [player setSleepTimerWithInterval:30.0 * 60.0];
    else if ([choice hasPrefix:@"45"]) [player setSleepTimerWithInterval:45.0 * 60.0];
    else if ([choice hasPrefix:@"60"]) [player setSleepTimerWithInterval:60.0 * 60.0];
}
- (void)toggleGenius:(id)sender { waAudioPlayer *player = [waAudioPlayer sharedPlayer]; BOOL enabled = player.isGeniusEnabled && player.isGeniusAutoplayAllowed; player.geniusEnabled = !enabled; [self updateButtons]; }
- (void)queueDidChange:(NSNotification *)notification {
    if (self.tableMutationInProgress) return;
    if (self.queueUpdateScheduled) return;
    self.queueUpdateScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.queueUpdateScheduled = NO;
        [self updateButtons];
        [self updateQueueSummaryIfNeeded];
        if (self.tableMutationInProgress) return;
        // Avoid a full reload + scroll jump on every player notification.
        // Only reload when the queue contents or position actually changed,
        // and only scroll when the current row is off-screen.
        waAudioPlayer *player = [waAudioPlayer sharedPlayer];
        BOOL countChanged = player.queueItems.count != self.lastKnownQueueCount;
        BOOL indexChanged = player.queueIndex != self.lastKnownQueueIndex;
        self.lastKnownQueueCount = player.queueItems.count;
        self.lastKnownQueueIndex = player.queueIndex;
        if (countChanged) [self.tableView reloadData];
        else [self updateVisibleDownloadStates];
        if (indexChanged) {
            [self refreshVisibleActiveStates];
            [self scrollToCurrentItem];
        }
    });
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    waAudioPlayer *player = [waAudioPlayer sharedPlayer];
    BOOL countChanged = player.queueItems.count != self.lastKnownQueueCount;
    self.lastKnownQueueCount = player.queueItems.count;
    self.lastKnownQueueIndex = player.queueIndex;
    // Only rebuild rows when the queue itself changed; returning to the tab
    // after a track advanced needs just the visible state refresh.
    if (countChanged) [self.tableView reloadData];
    else [self updateVisibleDownloadStates];
    [self updateButtons];
    [self updateQueueSummary];
    [self refreshVisibleActiveStates];
    [self scrollToCurrentItem];
}
- (void)refreshVisibleActiveStates {
    waAudioPlayer *player = [waAudioPlayer sharedPlayer];
    NSArray *items = player.queueItems;
    for (NSIndexPath *path in [self.tableView indexPathsForVisibleRows]) {
        if (path.row >= items.count) continue;
        waArtworkCell *cell = (waArtworkCell *)[self.tableView cellForRowAtIndexPath:path];
        if (![cell isKindOfClass:[waArtworkCell class]]) continue;
        BOOL active = player.currentItem && path.row == player.queueIndex;
        cell.textLabel.textColor = active ? [waTheme barColor] : [waTheme primaryTextColor];
        cell.detailTextLabel.textColor = active ? [waTheme barColor] : [waTheme secondaryTextColor];
    }
}
- (void)scrollToCurrentItem { NSUInteger index = [waAudioPlayer sharedPlayer].queueIndex; if (index >= [waAudioPlayer sharedPlayer].queueItems.count) return; NSIndexPath *path = [NSIndexPath indexPathForRow:index inSection:0]; if ([[self.tableView indexPathsForVisibleRows] containsObject:path]) return; [self.tableView scrollToRowAtIndexPath:path atScrollPosition:UITableViewScrollPositionMiddle animated:NO]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return [waAudioPlayer sharedPlayer].queueItems.count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    waArtworkCell *cell = (waArtworkCell *)[tableView dequeueReusableCellWithIdentifier:@"queue-item"];
    if (!cell) {
        cell = [[waArtworkCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"queue-item"];
        // Plain full-width rows: flat background set once here instead of
        // running [waTheme applyToView:] on every dequeue during scrolling.
        cell.cardStyle = NO;
        cell.backgroundColor = [waTheme backgroundColor];
        UIView *selected = [[UIView alloc] initWithFrame:CGRectZero];
        selected.backgroundColor = [waTheme selectedSurfaceColor];
        cell.selectedBackgroundView = selected;
    }
    waAudioPlayer *player = [waAudioPlayer sharedPlayer];
    NSArray *items = player.queueItems;
    waMediaItem *item = items[path.row];
    [cell setLikeItem:item];
    cell.textLabel.text = item.title;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ • %@", item.subtitle.length ? item.subtitle : @"Unknown", [self durationString:item.duration]];
    cell.imageView.image = waPlaceholderImage();
     NSString *downloadIdentifier = item.trackId.length ? item.trackId : item.identifier;
    waDownload *download = [[waDownloadManager sharedManager] downloadForIdentifier:downloadIdentifier];
    [cell setDownloadState:download ? download.state : waDownloadStateNotFound progress:download.progress];
    BOOL active = player.currentItem && path.row == player.queueIndex;
    [cell setExplicit:item.isExplicit];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.reserveAccessorySpace = NO;
    [cell setGeniusRecommended:item.isGeniusRecommended];
    cell.textLabel.textColor = active ? [waTheme barColor] : [waTheme primaryTextColor];
    cell.detailTextLabel.textColor = active ? [waTheme barColor] : [waTheme secondaryTextColor];
    if (item.thumbnailURL.length) {
        // Tag the cell with the requested URL: the completion ignores stale
        // callbacks from reused cells without walking the table
        // (indexPathForCell) on the main thread during fast scrolls.
        NSString *url = [item.thumbnailURL copy];
        cell.artworkIdentifier = url;
        [[waImageLoader sharedLoader] loadThumbnailAtURL:url placeholder:waPlaceholderImage() completion:^(UIImage *image) {
            if (![cell.artworkIdentifier isEqualToString:url]) return;
            NSArray *latestItems = [waAudioPlayer sharedPlayer].queueItems;
            waMediaItem *current = path.row < latestItems.count ? latestItems[path.row] : nil;
            if (current == item && [current.thumbnailURL isEqualToString:url]) cell.imageView.image = image;
        }];
    } else {
        cell.artworkIdentifier = nil;
    }
    return cell;
}
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)path { return [waTheme standardRowHeight]; }
- (NSString *)durationString:(NSTimeInterval)duration {
    if (!isfinite(duration) || duration < 0.0) duration = 0.0;
    NSInteger seconds = (NSInteger)duration;
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(seconds / 60), (long)(seconds % 60)];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path { [tableView deselectRowAtIndexPath:path animated:YES]; [[waAudioPlayer sharedPlayer] playQueueItemAtIndex:path.row]; }
- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    NSIndexPath *path = [self.tableView indexPathForRowAtPoint:[gesture locationInView:self.tableView]];
    if (!path || path.row >= [waAudioPlayer sharedPlayer].queueItems.count) return;
    waMediaItem *item = [waAudioPlayer sharedPlayer].queueItems[path.row];
    [waMediaActionSheet presentForItem:item inViewController:self albumItems:nil];
}
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)path { return YES; }
- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)path { return YES; }
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)path {
    if (style != UITableViewCellEditingStyleDelete) return;
    waAudioPlayer *player = [waAudioPlayer sharedPlayer];
    if (path.row >= player.queueItems.count) return;
    [self beginTableMutation];
    [player removeQueueItemAtIndex:path.row];
    [tableView beginUpdates];
    [tableView deleteRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationLeft];
    [tableView endUpdates];
}
- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath {
    [self beginTableMutation];
    [[waAudioPlayer sharedPlayer] moveQueueItemAtIndex:sourceIndexPath.row toIndex:destinationIndexPath.row];
}
- (void)showActions:(id)sender {
    (void)sender;
    waAudioPlayer *player = [waAudioPlayer sharedPlayer];
    if (!player.currentItem || player.queueItems.count < 2) return;
    NSArray *actions = @[[waAction actionWithIdentifier:@"queue.clearUpcoming" title:@"Clear Queue" destructive:YES availability:nil handler:^(id object) {
        waQueueViewController *controller = object;
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Clear Queue" message:@"Remove all queued songs except the current song?" delegate:controller cancelButtonTitle:@"Cancel" otherButtonTitles:@"Clear", nil];
        alert.tag = 701;
        [alert show];
    }]];
    [[waActions sharedActions] presentTitle:@"Queue Actions" actions:actions object:self fromViewController:self];
}
- (void)alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)index {
    if (alert.tag == 701 && index == 1) [self clearUpcomingWithAnimation];
}
- (void)clearUpcomingWithAnimation {
    waAudioPlayer *player = [waAudioPlayer sharedPlayer];
    if (!player.currentItem || player.queueIndex >= player.queueItems.count || player.queueItems.count < 2) return;
    NSUInteger firstRemovedRow = player.queueIndex + 1;
    NSUInteger oldCount = player.queueItems.count;
    NSMutableArray *paths = [NSMutableArray arrayWithCapacity:oldCount - firstRemovedRow];
    for (NSUInteger row = firstRemovedRow; row < oldCount; row++) [paths addObject:[NSIndexPath indexPathForRow:row inSection:0]];
    [self beginTableMutation];
    [player clearUpcomingQueue];
    [self.tableView beginUpdates];
    [self.tableView deleteRowsAtIndexPaths:paths withRowAnimation:UITableViewRowAnimationLeft];
    [self.tableView endUpdates];
}
- (void)dealloc {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(finishTableMutation) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(reloadDownloadTable) object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
@end
