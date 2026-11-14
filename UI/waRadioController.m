#import "waRadioController.h"
#import "waSession.h"
#import "waPlayer.h"
#import "waRootController.h"
#import "../Skin/waCoverView.h"

@interface waRadioController () <UIScrollViewDelegate>
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) waPageDots *dots;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSArray *radios;
@property (nonatomic, assign) CGFloat gridWidth;
@property (nonatomic, assign) BOOL building;
@end

@implementation waRadioController

- (id)init {
    return [self initWithGroupedStyle:YES];
}

- (id)initWithGroupedStyle:(BOOL)grouped {
    if ((self = [super initWithGroupedStyle:grouped])) {
        self.title = @"Radio";
        _radios = [NSArray array];
    }
    return self;
}

- (void)loadView {
    CGRect frame = [[UIScreen mainScreen] bounds];
    UIView *root = [[UIView alloc] initWithFrame:frame];
    root.backgroundColor = [UIColor groupTableViewBackgroundColor];
    root.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.view = root;

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:frame];
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scroll.alwaysBounceHorizontal = YES;
    scroll.alwaysBounceVertical = NO;
    scroll.directionalLockEnabled = YES;
    scroll.showsHorizontalScrollIndicator = NO;
    scroll.showsVerticalScrollIndicator = NO;
    scroll.pagingEnabled = YES;
    scroll.delegate = self;
    scroll.backgroundColor = [UIColor clearColor];
    self.scrollView = scroll;
    self.tableView = nil;
    [root addSubview:scroll];

    self.dots = [[waPageDots alloc] initWithFrame:CGRectZero];
    self.dots.backgroundColor = [UIColor clearColor];
    __weak waRadioController *weakSelf = self;
    self.dots.pageChanged = ^(NSInteger page) {
        waRadioController *strongSelf = weakSelf;
        if (!strongSelf) return;
        CGFloat pageW = CGRectGetWidth(strongSelf.scrollView.bounds);
        if (pageW < 1.0) return;
        [strongSelf.scrollView setContentOffset:CGPointMake(page * pageW, 0.0) animated:YES];
    };
    [root addSubview:self.dots];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    self.spinner.hidesWhenStopped = YES;
    self.spinner.center = CGPointMake(frame.size.width / 2.0, 120.0);
    [root addSubview:self.spinner];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationController.navigationBar.barStyle = UIBarStyleDefault;
    UIBarButtonItem *refresh = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                             target:self
                                                                             action:@selector(reload)];
    self.navigationItem.rightBarButtonItem = refresh;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(layoutChrome) name:waMiniPlayerLayoutDidChangeNotification object:nil];
    [self reload];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return orientation != UIInterfaceOrientationPortraitUpsideDown;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = CGRectGetWidth(self.view.bounds);
    [self layoutChrome];
    if (self.building || !self.radios.count || w < 1.0) return;
    if (fabs(w - self.gridWidth) > 1.0) [self buildGrid];
}

- (CGFloat)fittedSide {
    CGFloat w = CGRectGetWidth(self.view.bounds);
    CGFloat h = CGRectGetHeight(self.view.bounds);
    if (w < 1.0) w = 320.0;
    if (h < 1.0) h = 416.0;
    CGFloat mini = [waRootController miniPlayerCoverHeight];
    CGFloat avail = h - mini - 22.0 - 36.0;
    if (avail < 200.0) avail = 200.0;
    CGFloat row = (avail - 10.0) / 2.0;
    CGFloat side = floor(row - 50.0);
    if (side > 112.0) side = 112.0;
    if (side < 76.0) side = 76.0;
    return side;
}

- (void)reload {
    [self.spinner startAnimating];
    __weak waRadioController *weakSelf = self;
    [[waSession shared] radioTopWithCompletion:^(NSArray *radios, NSError *error) {
        void (^use)(NSArray *) = ^(NSArray *list) {
            waRadioController *strongSelf = weakSelf;
            if (!strongSelf) return;
            NSMutableArray *clean = [NSMutableArray array];
            for (id obj in list) if ([obj isKindOfClass:[waItem class]]) [clean addObject:obj];
            strongSelf.radios = clean;
            [strongSelf.spinner stopAnimating];
            [strongSelf buildGrid];
        };
        if (!error && radios.count) {
            use(radios);
            return;
        }
        [[waSession shared] radioListWithCompletion:^(NSArray *all, NSError *listError) {
            (void)listError;
            use(all);
        }];
    }];
}

- (void)buildGrid {
    if (self.building) return;
    self.building = YES;
    for (UIView *view in [self.scrollView.subviews copy]) [view removeFromSuperview];
    CGFloat w = CGRectGetWidth(self.view.bounds);
    if (w < 1.0) w = 320.0;
    self.gridWidth = w;
    CGFloat side = [self fittedSide];
    CGFloat tileH = [waCoverView heightForSide:side];
    NSUInteger count = self.radios.count;
    NSUInteger rows = 2;
    NSUInteger perPage = (NSUInteger)floor((w - 16.0) / (side + 8.0));
    if (perPage < 1) perPage = 1;
    CGFloat slot = floor((w - 16.0) / perPage);
    NSUInteger cols = count ? (count + rows - 1) / rows : 1;
    NSUInteger pages = (cols + perPage - 1) / perPage;
    if (pages < 1) pages = 1;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20.0, 6.0, w - 40.0, 22.0)];
    title.backgroundColor = [UIColor clearColor];
    title.font = [UIFont boldSystemFontOfSize:17.0];
    title.textColor = [waChrome headerInk];
    title.shadowColor = [UIColor whiteColor];
    title.shadowOffset = CGSizeMake(0.0, 1.0);
    title.text = @"Stations";
    [self.scrollView addSubview:title];

    for (NSUInteger i = 0; i < count; i++) {
        waItem *item = [self.radios objectAtIndex:i];
        NSUInteger col = i / rows;
        NSUInteger row = i % rows;
        NSUInteger page = col / perPage;
        NSUInteger slotIndex = col % perPage;
        CGFloat x = page * w + 8.0 + slotIndex * slot + (slot - side) / 2.0;
        CGFloat y = 32.0 + row * (tileH + 10.0);
        waCoverView *cover = [[waCoverView alloc] initWithFrame:CGRectMake(x, y, side, tileH)];
        [cover configureWithItem:item side:side];
        [cover addTarget:self action:@selector(stationTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.scrollView addSubview:cover];
    }
    CGFloat contentH = 32.0 + rows * (tileH + 10.0) + 8.0;
    self.scrollView.contentSize = CGSizeMake(pages * w, contentH);
    self.dots.numberOfPages = (NSInteger)pages;
    self.dots.currentPage = 0;
    self.dots.hidden = pages < 2;
    self.building = NO;
    [self layoutChrome];
}

- (void)layoutChrome {
    CGFloat w = CGRectGetWidth(self.view.bounds);
    CGFloat h = CGRectGetHeight(self.view.bounds);
    if (w < 1.0 || h < 1.0) return;
    CGFloat mini = [waRootController miniPlayerCoverHeight];
    CGFloat dotsH = self.dots.hidden ? 0.0 : 20.0;
    self.scrollView.frame = CGRectMake(0.0, 0.0, w, h - dotsH - mini);
    self.dots.frame = CGRectMake(0.0, h - dotsH - mini, w, dotsH);
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    CGFloat pageW = CGRectGetWidth(scrollView.bounds);
    if (pageW < 1.0) return;
    NSInteger page = (NSInteger)((scrollView.contentOffset.x + pageW / 2.0) / pageW);
    if (page < 0) page = 0;
    if (page >= self.dots.numberOfPages) page = self.dots.numberOfPages - 1;
    if (self.dots.currentPage != page) self.dots.currentPage = page;
}

- (void)stationTapped:(waCoverView *)cover {
    waItem *item = cover.item;
    if (!item) return;
    waRadio *radio = [[waRadio alloc] init];
    radio.identifier = item.identifier;
    radio.title = item.title;
    [self.spinner startAnimating];
    __weak waRadioController *weakSelf = self;
    [[waSession shared] playRadio:radio completion:^(NSError *error) {
        waRadioController *strongSelf = weakSelf;
        [strongSelf.spinner stopAnimating];
        if (error) {
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Radio"
                                                            message:error.localizedDescription
                                                           delegate:nil
                                                  cancelButtonTitle:@"OK"
                                                  otherButtonTitles:nil];
            [alert show];
            return;
        }
        [[waRootController shared] showPlayer];
    }];
}

@end
