#import "waTrackListViewController.h"
#import "../Services/waTheme.h"
#import "../Views/waArtworkCell.h"
#import "../Views/waPlaceholder.h"
#import "../Views/waEmptyView.h"
#import "../Services/waImageLoader.h"
#import "../Services/waAudioPlayer.h"
#import "../Views/waMediaActionSheet.h"
#import "../Models/waMediaItem.h"
#import "../Models/waDownload.h"
#import "../Services/waDownloadManager.h"
#import "../Services/waAPIClient.h"

@interface waTrackListViewController ()
@property (nonatomic, copy) NSArray *items;
@property (nonatomic, copy) NSArray *(^itemSource)(void);
@property (nonatomic, assign) BOOL deletable;
@property (nonatomic, copy) void (^deleteBlock)(waMediaItem *, NSIndexPath *);
@property (nonatomic, strong) waEmptyView *emptyView;
@end

@implementation waTrackListViewController

- (id)initWithTitle:(NSString *)title items:(NSArray *)items itemSource:(NSArray *(^)(void))itemSource deletable:(BOOL)deletable deleteBlock:(void (^)(waMediaItem *, NSIndexPath *))deleteBlock {
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        self.title = title ?: @"Songs";
        _items = [items copy] ?: @[];
        _itemSource = [itemSource copy];
        _deletable = deletable;
        _deleteBlock = [deleteBlock copy];
        self.contextTitle = title;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = [waTheme backgroundColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    UIView *bg = [[UIView alloc] initWithFrame:self.tableView.bounds];
    bg.backgroundColor = [waTheme backgroundColor];
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    self.emptyView = [[waEmptyView alloc] initWithFrame:bg.bounds];
    self.emptyView.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    [bg addSubview:self.emptyView];
    self.tableView.backgroundView = bg;
    
    UIBarButtonItem *playAll = [[UIBarButtonItem alloc] initWithTitle:@"Play All" style:UIBarButtonItemStyleBordered target:self action:@selector(playAll)];
    UIBarButtonItem *shuffle = [[UIBarButtonItem alloc] initWithTitle:@"Shuffle" style:UIBarButtonItemStyleBordered target:self action:@selector(shuffleAll)];
    self.navigationItem.rightBarButtonItems = @[shuffle, playAll];
    
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    [self.tableView addGestureRecognizer:lp];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeDidChange:) name:waThemeDidChangeNotification object:nil];
    [waTheme applyToView:self.view];
    [self updateEmpty];
}

- (void)themeDidChange:(NSNotification *)n { (void)n; self.tableView.backgroundColor=[waTheme backgroundColor]; [self.emptyView applyTheme]; [self.tableView reloadData]; }
- (void)updateEmpty {
    BOOL empty = self.items.count==0;
    if (empty) {
        [self.emptyView configureWithIcon:[UIImage imageNamed:@"wave-downloaded"] title:self.title subtitle:@"No songs" actionTitle:nil target:nil action:NULL];
        [self.emptyView applyTheme];
    }
    self.emptyView.hidden = !empty;
}

- (void)reloadWithItems:(NSArray *)items { self.items = items; [self updateEmpty]; [self.tableView reloadData]; }

- (NSArray *)currentItems {
    if (self.itemSource) {
        NSArray *live = self.itemSource();
        if (live) self.items = live;
    }
    return self.items;
}

#pragma mark - Actions

- (void)playAll {
    NSArray *items = [self currentItems];
    if (!items.count) return;
    [[waAudioPlayer sharedPlayer] setShuffleEnabled:NO];
    [[waAudioPlayer sharedPlayer] playItem:items[0] fromContext:items title:self.contextTitle];
}
- (void)shuffleAll {
    NSArray *items = [self currentItems];
    if (!items.count) return;
    [[waAudioPlayer sharedPlayer] setShuffleEnabled:YES];
    [[waAudioPlayer sharedPlayer] playItem:items[0] fromContext:items title:self.contextTitle];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { (void)tv;(void)s; return self.items.count; }
- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip { (void)ip; return [waTheme standardRowHeight]; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    waArtworkCell *cell = [tv dequeueReusableCellWithIdentifier:@"track"];
    if (!cell) {
        cell = [[waArtworkCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"track"];
        cell.cardStyle = NO;
        cell.backgroundColor = [waTheme backgroundColor];
        UIView *sel = [[UIView alloc] initWithFrame:CGRectZero];
        sel.backgroundColor = [waTheme selectedSurfaceColor];
        cell.selectedBackgroundView = sel;
    }
    waMediaItem *item = self.items[ip.row];
    cell.textLabel.text = item.title;
    cell.detailTextLabel.text = item.subtitle.length ? item.subtitle : (item.artistName ?: @"");
    cell.textLabel.textColor = [waTheme primaryTextColor];
    cell.detailTextLabel.textColor = [waTheme secondaryTextColor];
    [cell setLikeItem:item];
    [cell setExplicit:item.isExplicit];
    cell.imageView.image = waPlaceholderImage();
    if (item.thumbnailURL.length) {
        NSString *url = item.thumbnailURL;
        cell.artworkIdentifier = item.identifier;
        [[waImageLoader sharedLoader] loadThumbnailAtURL:url targetSize:CGSizeMake(112,112) placeholder:waPlaceholderImage() completion:^(UIImage *img){ if (img && [cell.artworkIdentifier isEqualToString:item.identifier]) cell.imageView.image = img; }];
    }
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row >= (NSInteger)self.items.count) return;
    waMediaItem *item = self.items[ip.row];
    [[waAudioPlayer sharedPlayer] playItem:item fromContext:self.items title:self.contextTitle];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    NSIndexPath *ip = [self.tableView indexPathForRowAtPoint:[g locationInView:self.tableView]];
    if (!ip || ip.row >= (NSInteger)self.items.count) return;
    waMediaItem *item = self.items[ip.row];
    [waMediaActionSheet presentForItem:item inViewController:self albumItems:nil];
}

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { (void)tv;(void)ip; return self.deletable; }
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (style != UITableViewCellEditingStyleDelete) return;
    waMediaItem *item = self.items[ip.row];
    if (self.deleteBlock) self.deleteBlock(item, ip);
    NSMutableArray *m = [self.items mutableCopy];
    [m removeObjectAtIndex:ip.row];
    self.items = [m copy];
    [tv deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationLeft];
    [self updateEmpty];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

@end
