#import "waCarouselView.h"
#import "waTileView.h"
#import "waModel.h"

@interface waCarouselView ()
@property (nonatomic, assign) CGFloat tileSide;
@end

@implementation waCarouselView

+ (CGFloat)heightForArtworkSide:(CGFloat)side paged:(BOOL)paged {
    return [self heightForArtworkSide:side paged:paged showsHeader:YES];
}

+ (CGFloat)heightForArtworkSide:(CGFloat)side paged:(BOOL)paged showsHeader:(BOOL)showsHeader {
    CGFloat h = (showsHeader ? 28.0 : 8.0) + [waTileView heightForArtworkSide:side] + 6.0;
    if (paged) h += 18.0;
    return h;
}

- (id)initWithFrame:(CGRect)frame title:(NSString *)title {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        _paging = NO;

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.backgroundColor = [UIColor clearColor];
        _titleLabel.font = [UIFont boldSystemFontOfSize:17.0];
        _titleLabel.textColor = [UIColor blackColor];
        _titleLabel.text = title.length ? title : @"";
        [self addSubview:_titleLabel];

        _seeAllButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
        _seeAllButton.titleLabel.font = [UIFont boldSystemFontOfSize:13.0];
        [_seeAllButton setTitle:@"See All" forState:UIControlStateNormal];
        _seeAllButton.hidden = YES;
        [self addSubview:_seeAllButton];

        _scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
        _scrollView.backgroundColor = [UIColor clearColor];
        _scrollView.pagingEnabled = NO;
        _scrollView.scrollEnabled = YES;
        _scrollView.directionalLockEnabled = YES;
        _scrollView.alwaysBounceHorizontal = YES;
        _scrollView.alwaysBounceVertical = NO;
        _scrollView.showsHorizontalScrollIndicator = NO;
        _scrollView.showsVerticalScrollIndicator = NO;
        _scrollView.clipsToBounds = YES;
        _scrollView.delegate = self;
        _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.clipsToBounds = YES;
        [self addSubview:_scrollView];

        _pageControl = [[UIPageControl alloc] initWithFrame:CGRectZero];
        _pageControl.hidesForSinglePage = YES;
        _pageControl.hidden = YES;
        [_pageControl addTarget:self action:@selector(pageChanged:) forControlEvents:UIControlEventValueChanged];
        [self addSubview:_pageControl];
    }
    return self;
}

- (void)setItems:(NSArray *)items
     artworkSide:(CGFloat)side
          target:(id)target
          action:(SEL)action
    seeAllTarget:(id)seeAllTarget
    seeAllAction:(SEL)seeAllAction {
    if (side < 60.0) side = 88.0;
    NSMutableArray *tiles = [NSMutableArray array];
    for (UIView *view in self.scrollView.subviews) {
        if ([view isKindOfClass:[waTileView class]]) [tiles addObject:view];
    }
    BOOL same = (fabs(self.tileSide - side) < 0.5 && self.items.count == items.count && tiles.count == items.count);
    if (same) {
        for (NSUInteger i = 0; i < items.count; i++) {
            if ([self.items objectAtIndex:i] != [items objectAtIndex:i]) { same = NO; break; }
        }
    }
    _items = [items copy];
    self.tileSide = side;
    if (same) {
        for (waTileView *tile in tiles) {
            [tile removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
            if (target && action) [tile addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
        }
    } else {
        CGFloat x = 12.0;
        CGFloat gap = 8.0;
        NSUInteger index = 0;
        CGFloat h = [waTileView heightForArtworkSide:side];
        for (id obj in self.items) {
            if (![obj isKindOfClass:[waItem class]]) continue;
            CGRect frame = CGRectMake(x, 0.0, side, h);
            waTileView *tile = index < tiles.count ? [tiles objectAtIndex:index] : nil;
            if (tile) {
                tile.frame = frame;
                tile.artworkSide = side;
                tile.tag = (NSInteger)index;
                [tile configureWithItem:obj];
            } else {
                tile = [[waTileView alloc] initWithFrame:frame item:obj artworkSide:side];
                tile.tag = (NSInteger)index;
                [self.scrollView addSubview:tile];
            }
            [tile removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
            if (target && action) [tile addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
            x += side + gap;
            index++;
        }
        for (NSUInteger extra = index; extra < tiles.count; extra++) {
            [[tiles objectAtIndex:extra] removeFromSuperview];
        }
        self.scrollView.contentSize = CGSizeMake(MAX(x + 4.0, CGRectGetWidth(self.scrollView.bounds)), h);
    }

    if (seeAllTarget && seeAllAction) {
        self.seeAllButton.hidden = NO;
        [self.seeAllButton removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
        [self.seeAllButton addTarget:seeAllTarget action:seeAllAction forControlEvents:UIControlEventTouchUpInside];
    } else {
        self.seeAllButton.hidden = YES;
    }

    if (self.paging) {
        self.scrollView.pagingEnabled = YES;
        CGFloat pageW = CGRectGetWidth(self.bounds);
        if (pageW < 1.0) pageW = 320.0;
        NSInteger pages = (NSInteger)ceil(self.scrollView.contentSize.width / pageW);
        self.pageControl.numberOfPages = MAX(1, pages);
        self.pageControl.currentPage = 0;
        self.pageControl.hidden = NO;
    } else {
        self.scrollView.pagingEnabled = NO;
        self.pageControl.hidden = YES;
    }
    [self setNeedsLayout];
}

- (void)pageChanged:(UIPageControl *)control {
    CGFloat pageW = CGRectGetWidth(self.scrollView.bounds);
    if (pageW < 1.0) return;
    CGPoint offset = CGPointMake(control.currentPage * pageW, 0.0);
    [self.scrollView setContentOffset:offset animated:YES];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (!self.paging || self.pageControl.hidden) return;
    CGFloat pageW = CGRectGetWidth(scrollView.bounds);
    if (pageW < 1.0) return;
    NSInteger page = (NSInteger)((scrollView.contentOffset.x + pageW / 2.0) / pageW);
    if (page < 0) page = 0;
    if (page >= self.pageControl.numberOfPages) page = self.pageControl.numberOfPages - 1;
    self.pageControl.currentPage = page;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = CGRectGetWidth(self.bounds);
    BOOL header = self.titleLabel.text.length > 0 || !self.seeAllButton.hidden;
    if (header) {
        self.titleLabel.frame = CGRectMake(10.0, 2.0, w - 110.0, 24.0);
        self.seeAllButton.frame = CGRectMake(w - 86.0, 2.0, 76.0, 24.0);
    } else {
        self.titleLabel.frame = CGRectZero;
        self.seeAllButton.frame = CGRectZero;
    }
    CGFloat y = header ? 28.0 : 4.0;
    CGFloat scrollH = CGRectGetHeight(self.bounds) - y - (self.paging && !self.pageControl.hidden ? 20.0 : 6.0);
    if (scrollH < 40.0) scrollH = 40.0;
    self.scrollView.frame = CGRectMake(0.0, y, w, scrollH);
    if (self.paging && !self.pageControl.hidden) {
        self.pageControl.frame = CGRectMake(0.0, y + scrollH + 2.0, w, 16.0);
    }
    if (self.scrollView.contentSize.width < w) {
        self.scrollView.contentSize = CGSizeMake(w, self.scrollView.contentSize.height);
    }
}

@end
