#import "waHomeSectionView.h"
#import "waHomeCardCell.h"
#import "../Services/waTheme.h"

@interface waHomeSectionView () <UICollectionViewDataSource, UICollectionViewDelegate>
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIButton *moreButton;
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) NSArray *items;
@property (nonatomic, copy) NSString *layout;
@property (nonatomic, copy) waHomeSectionSelectionBlock selection;
// When this view is embedded in a UITableViewCell, configureWithSection:
// calls reloadData while the collection view still has a zero frame (the cell
// has not been sized yet). The initial layout pass caches an empty visible
// rect, so the cards never appear until a forced re-layout. This flag drives
// exactly one reload once the view has a real width.
@property (nonatomic, assign) BOOL needsForcedCollectionReload;
@end

@implementation waHomeSectionView

- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.compact = NO;
        self.compactLandscape = NO;
        self.backgroundColor = [UIColor clearColor];
        self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.titleLabel.backgroundColor = [UIColor clearColor];
        self.titleLabel.textColor = [UIColor whiteColor];
        self.titleLabel.font = [waTheme boldFontOfSize:25.0];
        self.titleLabel.adjustsFontSizeToFitWidth = YES;
        self.titleLabel.minimumScaleFactor = 0.72;
        self.titleLabel.lineBreakMode = NSLineBreakByClipping;
        [self addSubview:self.titleLabel];
        self.subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.subtitleLabel.backgroundColor = [UIColor clearColor];
        self.subtitleLabel.textColor = [waTheme secondaryTextColor];
        self.subtitleLabel.font = [waTheme secondaryRegularFontOfSize:16.0];
        [self addSubview:self.subtitleLabel];
        self.moreButton = [UIButton buttonWithType:UIButtonTypeCustom];
        self.moreButton.backgroundColor = [UIColor clearColor];
        self.moreButton.titleLabel.font = [UIFont systemFontOfSize:38.0];
        [self.moreButton setTitle:@"›" forState:UIControlStateNormal];
        self.moreButton.accessibilityLabel = @"Show more";
        [self.moreButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [self.moreButton addTarget:self action:@selector(morePressed:) forControlEvents:UIControlEventTouchUpInside];
        self.moreButton.hidden = YES;
        [self addSubview:self.moreButton];
        UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
        layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
        layout.minimumInteritemSpacing = 10.0;
        layout.minimumLineSpacing = 10.0;
        layout.sectionInset = UIEdgeInsetsMake(0.0, 18.0, 0.0, 18.0);
        self.collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
        self.collectionView.backgroundColor = [UIColor clearColor];
        self.collectionView.contentInset = UIEdgeInsetsZero;
        self.collectionView.showsHorizontalScrollIndicator = NO;
        self.collectionView.showsVerticalScrollIndicator = NO;
        self.collectionView.dataSource = self;
        self.collectionView.delegate = self;
        self.collectionView.decelerationRate = UIScrollViewDecelerationRateFast;
        self.collectionView.layer.shouldRasterize = NO;
        [self.collectionView registerClass:[waHomeCardCell class] forCellWithReuseIdentifier:@"home-card"];
        [self addSubview:self.collectionView];
        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
        longPress.minimumPressDuration = 0.55;
        [self.collectionView addGestureRecognizer:longPress];
    }
    return self;
}

- (void)configureWithSection:(NSDictionary *)section selection:(waHomeSectionSelectionBlock)selection {
    self.titleLabel.text = section[@"title"];
    self.moreButton.accessibilityLabel = self.titleLabel.text.length ? [NSString stringWithFormat:@"Show more %@", self.titleLabel.text] : @"Show more";
    self.subtitleLabel.text = section[@"subtitle"];
    NSArray *rawItems = [section[@"items"] isKindOfClass:[NSArray class]] ? section[@"items"] : @[];
    NSMutableArray *normalizedItems = [NSMutableArray arrayWithCapacity:rawItems.count];
    for (id object in rawItems) {
        waMediaItem *item = [object isKindOfClass:[waMediaItem class]] ? object : ([object isKindOfClass:[NSDictionary class]] ? [waMediaItem itemWithDictionary:object] : nil);
        if (item) [normalizedItems addObject:item];
    }
    self.items = normalizedItems;
    self.layout = section[@"layout"] ?: @"square";
    self.selection = selection;
    self.moreButton.hidden = ![section[@"showsMore"] boolValue];
    [self.collectionView reloadData];
    // Mark for a forced re-layout: if this view is inside a UITableViewCell the
    // collection view just reloaded against a zero frame and cached an empty
    // visible rect. layoutSubviews will re-drive it once a real width exists.
    if (normalizedItems.count) self.needsForcedCollectionReload = YES;
    [self setNeedsLayout];
}

- (void)clearCallbacks {
    self.selection = nil;
    self.longPress = nil;
    self.moreAction = nil;
}

- (void)resetScrollPosition {
    CGPoint origin = CGPointMake(-self.collectionView.contentInset.left,
                                 -self.collectionView.contentInset.top);
    [self.collectionView setContentOffset:origin animated:NO];
}

- (CGFloat)preferredHeight {
    BOOL list = [self.layout isEqualToString:@"song-list"];
    BOOL grid = [self.layout isEqualToString:@"explore-grid"];
    if (list || grid) return self.compact ? 250.0 : 285.0;
    if ([self.layout isEqualToString:@"circle"]) return self.compact ? 230.0 : 270.0;
    // Leave room for two title lines and up to three description lines below
    // the 160pt artwork. Text must not be clipped by the collection cell.
    return self.compact ? (self.compactLandscape ? 253.0 : 295.0) : 345.0;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width;
    self.titleLabel.frame = CGRectMake(18.0, 4.0, MAX(0.0, width - (self.moreButton.hidden ? 36.0 : 78.0)), 34.0);
    self.subtitleLabel.frame = CGRectMake(18.0, 39.0, width - 36.0, 25.0);
    self.moreButton.frame = CGRectMake(width - 56.0, 0.0, 42.0, 42.0);
    CGFloat top = self.subtitleLabel.text.length ? 72.0 : 48.0;
    CGFloat collectionHeight = MAX(0.0, self.bounds.size.height - top);
    // Keep the scroll viewport full width. The visual side margins belong to
    // the flow layout; putting the left margin on the frame made the
    // horizontal content bounds asymmetric and left the final card slightly
    // misaligned on both Home and Search.
    self.collectionView.frame = CGRectMake(0.0, top, MAX(0.0, width), collectionHeight);
    self.collectionView.hidden = self.items.count == 0;
    UICollectionViewFlowLayout *flow = (UICollectionViewFlowLayout *)self.collectionView.collectionViewLayout;
    CGSize itemSize;
    if ([self.layout isEqualToString:@"circle"]) itemSize = self.compact ? CGSizeMake(width >= 600.0 ? 106.0 : 96.0, 176.0) : CGSizeMake(112.0, 215.0);
    else if ([self.layout isEqualToString:@"song-list"]) itemSize = CGSizeMake(MAX(290.0, width - 36.0), self.compact ? 68.0 : 76.0);
    else if ([self.layout isEqualToString:@"explore-grid"]) itemSize = self.compact ? CGSizeMake(132.0, 100.0) : CGSizeMake(150.0, 112.0);
    else if (self.compact) itemSize = CGSizeMake(width >= 600.0 ? 150.0 : 132.0, self.compactLandscape ? 205.0 : 235.0);
    else itemSize = CGSizeMake(160.0, 270.0);
    if (!CGSizeEqualToSize(flow.itemSize, itemSize)) {
        flow.itemSize = itemSize;
        [flow invalidateLayout];
    }
    // UICollectionView nested in a UITableViewCell: the first reloadData ran with
    // a zero frame and produced no visible cells. Once we have a real width and
    // pending content, force one more reload so the cards actually appear.
    if (self.needsForcedCollectionReload && CGRectGetWidth(self.collectionView.frame) > 0 && self.items.count > 0) {
        self.needsForcedCollectionReload = NO;
        [self.collectionView reloadData];
    }
}

- (void)morePressed:(id)sender {
    (void)sender;
    if (self.moreAction) self.moreAction();
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section { (void)collectionView; (void)section; return self.items.count; }

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    waHomeCardCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"home-card" forIndexPath:indexPath];
    [cell configureWithItem:self.items[indexPath.item] layout:self.layout];
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    (void)collectionView;
    if (self.selection && indexPath.item < self.items.count) self.selection(self.items[indexPath.item], self.items);
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan || !self.longPress) return;
    NSIndexPath *path = [self.collectionView indexPathForItemAtPoint:[gesture locationInView:self.collectionView]];
    if (path && path.item < self.items.count) self.longPress(self.items[path.item], self.items);
}

@end
