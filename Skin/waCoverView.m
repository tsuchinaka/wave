#import "waCoverView.h"
#import "waSession.h"
#import <QuartzCore/QuartzCore.h>

static UIImage *waPaperFill(void) {
    static UIImage *image;
    if (image) return image;
    CGSize size = CGSizeMake(8.0, 8.0);
    UIGraphicsBeginImageContextWithOptions(size, YES, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGFloat comps[] = {0.94, 0.94, 0.95, 1.0, 0.80, 0.81, 0.83, 1.0};
    CGFloat stops[] = {0.0, 1.0};
    CGGradientRef fill = CGGradientCreateWithColorComponents(space, comps, stops, 2);
    CGContextDrawLinearGradient(ctx, fill, CGPointZero, CGPointMake(0.0, size.height), 0);
    CGGradientRelease(fill);
    CGColorSpaceRelease(space);
    image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

static UIImage *waReflection(UIImage *image, CGFloat height) {
    if (!image || height < 1.0) return nil;
    CGSize size = image.size;
    if (size.width < 1.0 || size.height < 1.0) return nil;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size.width, height), NO, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextTranslateCTM(ctx, 0.0, height);
    CGContextScaleCTM(ctx, 1.0, -1.0);
    [image drawInRect:CGRectMake(0.0, height - size.height, size.width, size.height)];
    CGContextSetBlendMode(ctx, kCGBlendModeDestinationIn);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceGray();
    CGFloat comps[] = {1.0, 0.42, 1.0, 0.08, 1.0, 0.0};
    CGFloat stops[] = {0.0, 0.32, 1.0};
    CGGradientRef fade = CGGradientCreateWithColorComponents(space, comps, stops, 3);
    CGContextDrawLinearGradient(ctx, fade, CGPointMake(0.0, height), CGPointMake(0.0, 0.0), 0);
    CGGradientRelease(fade);
    CGColorSpaceRelease(space);
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return out;
}

static void waGridMetrics(CGFloat width, NSUInteger count, NSUInteger *colsOut, CGFloat *sideOut, CGFloat *rowHOut, CGFloat *totalOut) {
    if (width < 1.0) width = 300.0;
    NSUInteger cols = width > 420.0 ? 3 : 2;
    CGFloat inset = 10.0;
    CGFloat gap = 10.0;
    CGFloat side = floor((width - inset * 2.0 - gap * (cols - 1)) / cols);
    if (side > 150.0) side = 150.0;
    if (side < 88.0) side = 88.0;
    CGFloat rowH = [waCoverView heightForSide:side];
    NSUInteger rows = count ? (count + cols - 1) / cols : 0;
    CGFloat total = rows ? (8.0 + rows * (rowH + 8.0)) : 0.0;
    if (colsOut) *colsOut = cols;
    if (sideOut) *sideOut = side;
    if (rowHOut) *rowHOut = rowH;
    if (totalOut) *totalOut = total;
}

@implementation waChrome

+ (UIColor *)headerInk {
    return [UIColor colorWithRed:0.298 green:0.337 blue:0.423 alpha:1.0];
}

+ (UIColor *)linkBlue {
    return [UIColor colorWithRed:0.16 green:0.33 blue:0.58 alpha:1.0];
}

+ (UIImage *)buttonImagePressed:(BOOL)pressed {
    static UIImage *normalImage;
    static UIImage *pressedImage;
    if (!pressed && normalImage) return normalImage;
    if (pressed && pressedImage) return pressedImage;

    CGSize size = CGSizeMake(28.0, 30.0);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect box = CGRectInset(CGRectMake(0.0, 0.0, size.width, size.height), 0.5, 0.5);
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:box cornerRadius:5.0];
    CGContextSaveGState(ctx);
    [path addClip];

    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGFloat normal[] = {
        1.00, 1.00, 1.00, 1.0,
        0.94, 0.95, 0.96, 1.0,
        0.78, 0.80, 0.84, 1.0,
        0.64, 0.67, 0.72, 1.0
    };
    CGFloat down[] = {
        0.58, 0.74, 0.91, 1.0,
        0.30, 0.52, 0.79, 1.0,
        0.15, 0.37, 0.68, 1.0,
        0.08, 0.25, 0.52, 1.0
    };
    CGFloat stops[] = {0.0, 0.46, 0.54, 1.0};
    CGGradientRef fill = CGGradientCreateWithColorComponents(space, pressed ? down : normal, stops, 4);
    CGContextDrawLinearGradient(ctx, fill, CGPointZero, CGPointMake(0.0, size.height), 0);
    CGGradientRelease(fill);

    CGFloat sheen = pressed ? 0.26 : 0.62;
    CGFloat gloss[] = {1.0, 1.0, 1.0, sheen, 1.0, 1.0, 1.0, 0.0};
    CGFloat glossStops[] = {0.0, 1.0};
    CGGradientRef band = CGGradientCreateWithColorComponents(space, gloss, glossStops, 2);
    CGContextDrawLinearGradient(ctx, band, CGPointMake(0.0, 1.0), CGPointMake(0.0, size.height * 0.48), 0);
    CGGradientRelease(band);
    CGColorSpaceRelease(space);
    CGContextRestoreGState(ctx);

    [[UIColor colorWithWhite:pressed ? 0.12 : 0.40 alpha:1.0] setStroke];
    path.lineWidth = 1.0;
    [path stroke];

    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    image = [image resizableImageWithCapInsets:UIEdgeInsetsMake(14.0, 12.0, 14.0, 12.0)];
    if (pressed) pressedImage = image;
    else normalImage = image;
    return image;
}

+ (void)styleButton:(UIButton *)button title:(NSString *)title {
    if (!button) return;
    UIImage *up = [self buttonImagePressed:NO];
    UIImage *down = [self buttonImagePressed:YES];
    [button setBackgroundImage:up forState:UIControlStateNormal];
    [button setBackgroundImage:down forState:UIControlStateHighlighted];
    [button setBackgroundImage:down forState:UIControlStateSelected];
    [button setBackgroundImage:down forState:(UIControlStateSelected | UIControlStateHighlighted)];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:12.0];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumFontSize = 9.0;
    button.titleLabel.shadowOffset = CGSizeMake(0.0, 1.0);
    [button setTitleColor:[self linkBlue] forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateHighlighted];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateSelected];
    [button setTitleColor:[UIColor whiteColor] forState:(UIControlStateSelected | UIControlStateHighlighted)];
    [button setTitleShadowColor:[UIColor colorWithWhite:1.0 alpha:0.8] forState:UIControlStateNormal];
    [button setTitleShadowColor:[UIColor colorWithWhite:0.0 alpha:0.35] forState:UIControlStateHighlighted];
    [button setTitleShadowColor:[UIColor colorWithWhite:0.0 alpha:0.35] forState:UIControlStateSelected];
    [button setTitleShadowColor:[UIColor colorWithWhite:0.0 alpha:0.35] forState:(UIControlStateSelected | UIControlStateHighlighted)];
}

+ (UIView *)embossedHeaderWithTitle:(NSString *)title width:(CGFloat)width {
    if (width < 1.0) width = 320.0;
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, width, 34.0)];
    header.backgroundColor = [UIColor clearColor];
    header.opaque = NO;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(20.0, 10.0, width - 32.0, 20.0)];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    label.backgroundColor = [UIColor clearColor];
    label.font = [UIFont boldSystemFontOfSize:17.0];
    label.textColor = [self headerInk];
    label.shadowColor = [UIColor whiteColor];
    label.shadowOffset = CGSizeMake(0.0, 1.0);
    label.text = title.length ? title : @"";
    [header addSubview:label];
    return header;
}

@end

@implementation waChromeBar

- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.opaque = YES;
        self.backgroundColor = [UIColor colorWithWhite:0.86 alpha:1.0];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    (void)rect;
    CGRect bounds = self.bounds;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGFloat comps[] = {
        0.99, 0.99, 1.00, 1.0,
        0.88, 0.89, 0.91, 1.0,
        0.73, 0.75, 0.78, 1.0
    };
    CGFloat stops[] = {0.0, 0.52, 1.0};
    CGGradientRef fill = CGGradientCreateWithColorComponents(space, comps, stops, 3);
    CGContextDrawLinearGradient(ctx, fill, CGPointZero, CGPointMake(0.0, bounds.size.height), 0);
    CGGradientRelease(fill);
    CGColorSpaceRelease(space);
    [[UIColor colorWithWhite:1.0 alpha:0.9] setFill];
    CGContextFillRect(ctx, CGRectMake(0.0, 0.0, bounds.size.width, 1.0));
    [[UIColor colorWithWhite:0.42 alpha:1.0] setFill];
    CGContextFillRect(ctx, CGRectMake(0.0, bounds.size.height - 1.0, bounds.size.width, 1.0));
}

- (void)layoutSubviews {
    [super layoutSubviews];
    NSUInteger count = self.buttons.count;
    CGFloat width = CGRectGetWidth(self.bounds);
    if (!count || width < 1.0) return;
    CGFloat inset = 8.0;
    CGFloat gap = 6.0;
    CGFloat buttonW = (width - inset * 2.0 - gap * (count - 1)) / count;
    CGFloat buttonH = 30.0;
    CGFloat y = floor((CGRectGetHeight(self.bounds) - buttonH) / 2.0);
    for (NSUInteger i = 0; i < count; i++) {
        UIButton *button = [self.buttons objectAtIndex:i];
        button.frame = CGRectMake(inset + i * (buttonW + gap), y, buttonW, buttonH);
    }
}

@end

@interface waCoverGlossView : UIView
@end

@implementation waCoverGlossView

- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.userInteractionEnabled = NO;
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    (void)rect;
    CGRect bounds = self.bounds;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGFloat gloss[] = {1.0, 1.0, 1.0, 0.42, 1.0, 1.0, 1.0, 0.05, 1.0, 1.0, 1.0, 0.0};
    CGFloat glossStops[] = {0.0, 0.42, 1.0};
    CGGradientRef band = CGGradientCreateWithColorComponents(space, gloss, glossStops, 3);
    CGContextDrawLinearGradient(ctx, band, CGPointZero, CGPointMake(0.0, bounds.size.height * 0.50), 0);
    CGGradientRelease(band);

    CGFloat bevel[] = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.20};
    CGFloat bevelStops[] = {0.0, 1.0};
    CGGradientRef shade = CGGradientCreateWithColorComponents(space, bevel, bevelStops, 2);
    CGContextDrawLinearGradient(ctx, shade, CGPointMake(0.0, bounds.size.height - 12.0), CGPointMake(0.0, bounds.size.height), 0);
    CGGradientRelease(shade);
    CGColorSpaceRelease(space);

    [[UIColor colorWithWhite:1.0 alpha:0.80] setStroke];
    UIBezierPath *inner = [UIBezierPath bezierPathWithRect:CGRectInset(bounds, 1.5, 1.5)];
    inner.lineWidth = 1.0;
    [inner stroke];
    [[UIColor colorWithWhite:0.0 alpha:0.28] setStroke];
    UIBezierPath *outer = [UIBezierPath bezierPathWithRect:CGRectInset(bounds, 0.5, 0.5)];
    outer.lineWidth = 1.0;
    [outer stroke];
}

@end

@interface waCoverView ()
@property (nonatomic, strong) UIView *plate;
@property (nonatomic, strong) UIImageView *artView;
@property (nonatomic, strong) waCoverGlossView *gloss;
@property (nonatomic, strong) UIImageView *reflectionView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@end

@implementation waCoverView

+ (CGFloat)heightForSide:(CGFloat)side {
    return 2.0 + side + 16.0 + 2.0 + 16.0 + 14.0;
}

- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        _artworkSide = 100.0;

        _plate = [[UIView alloc] initWithFrame:CGRectZero];
        _plate.backgroundColor = [UIColor clearColor];
        _plate.userInteractionEnabled = NO;
        _plate.layer.shadowColor = [UIColor blackColor].CGColor;
        _plate.layer.shadowOffset = CGSizeMake(0.0, 1.0);
        _plate.layer.shadowRadius = 2.0;
        _plate.layer.shadowOpacity = 0.32;
        [self addSubview:_plate];

        _artView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _artView.contentMode = UIViewContentModeScaleAspectFill;
        _artView.clipsToBounds = YES;
        _artView.opaque = YES;
        _artView.backgroundColor = [UIColor colorWithWhite:0.86 alpha:1.0];
        [_plate addSubview:_artView];

        _gloss = [[waCoverGlossView alloc] initWithFrame:CGRectZero];
        [_plate addSubview:_gloss];

        _reflectionView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _reflectionView.contentMode = UIViewContentModeScaleToFill;
        _reflectionView.userInteractionEnabled = NO;
        _reflectionView.backgroundColor = [UIColor clearColor];
        [self addSubview:_reflectionView];

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.backgroundColor = [UIColor clearColor];
        _titleLabel.font = [UIFont boldSystemFontOfSize:12.0];
        _titleLabel.textColor = [UIColor blackColor];
        _titleLabel.shadowColor = [UIColor colorWithWhite:1.0 alpha:0.85];
        _titleLabel.shadowOffset = CGSizeMake(0.0, 1.0);
        _titleLabel.lineBreakMode = UILineBreakModeTailTruncation;
        [self addSubview:_titleLabel];

        _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _subtitleLabel.backgroundColor = [UIColor clearColor];
        _subtitleLabel.font = [UIFont systemFontOfSize:11.0];
        _subtitleLabel.textColor = [UIColor colorWithWhite:0.35 alpha:1.0];
        _subtitleLabel.shadowColor = [UIColor colorWithWhite:1.0 alpha:0.8];
        _subtitleLabel.shadowOffset = CGSizeMake(0.0, 1.0);
        _subtitleLabel.lineBreakMode = UILineBreakModeTailTruncation;
        [self addSubview:_subtitleLabel];
    }
    return self;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.layer.shouldRasterize = !highlighted;
    self.plate.alpha = highlighted ? 0.55 : 1.0;
    self.reflectionView.alpha = highlighted ? 0.35 : 1.0;
}

- (NSString *)subtitleForItem:(waItem *)item {
    if ([item isKindOfClass:[waTrack class]]) {
        waTrack *track = (waTrack *)item;
        return track.artistName.length ? track.artistName : @"";
    }
    if ([item isKindOfClass:[waAlbum class]]) {
        waAlbum *album = (waAlbum *)item;
        return album.artistName.length ? album.artistName : @"";
    }
    if ([item isKindOfClass:[waArtist class]]) {
        waArtist *artist = (waArtist *)item;
        if (artist.fanCount > 0) return [NSString stringWithFormat:@"%ld fans", (long)artist.fanCount];
    }
    if ([item isKindOfClass:[waPlaylist class]]) {
        waPlaylist *playlist = (waPlaylist *)item;
        if (playlist.trackCount > 0) return [NSString stringWithFormat:@"%ld songs", (long)playlist.trackCount];
        if (playlist.creatorName.length) return playlist.creatorName;
    }
    return item.subtitle.length ? item.subtitle : @"";
}

- (NSString *)artworkURL {
    return [self.item artworkURLForSide:self.artworkSide];
}

- (void)applyImage:(UIImage *)image {
    if (image) {
        self.artView.image = image;
        self.reflectionView.image = waReflection(image, 16.0);
    } else {
        self.artView.image = waPaperFill();
        self.reflectionView.image = nil;
    }
}

- (void)configureWithItem:(waItem *)item side:(CGFloat)side {
    BOOL same = (_item == item && self.artView.image != nil && self.artView.image != waPaperFill());
    if (!same) [[waSession shared] cancelArtworkForOwner:self];
    _item = item;
    if (side > 40.0) _artworkSide = side;
    self.titleLabel.text = item.title.length ? item.title : @"";
    self.subtitleLabel.text = [self subtitleForItem:item];
    if (!same) {
        NSString *url = [self artworkURL];
        CGSize size = CGSizeMake(self.artworkSide, self.artworkSide);
        UIImage *cached = url.length ? [[waSession shared] cachedArtwork:url size:size] : nil;
        if (cached) {
            [self applyImage:cached];
        } else {
            [self applyImage:nil];
            if (url.length) {
                __weak waCoverView *weakSelf = self;
                NSString *copy = [url copy];
                [[waSession shared] loadArtwork:copy size:size owner:self completion:^(UIImage *loaded) {
                    waCoverView *strongSelf = weakSelf;
                    if (!strongSelf) return;
                    if (![[strongSelf artworkURL] isEqualToString:copy]) return;
                    [strongSelf applyImage:loaded];
                }];
            }
        }
    }
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = CGRectGetWidth(self.bounds);
    CGFloat side = self.artworkSide;
    if (side > w) side = w;
    self.plate.frame = CGRectMake(0.0, 2.0, side, side);
    self.artView.frame = self.plate.bounds;
    self.gloss.frame = self.plate.bounds;
    self.reflectionView.frame = CGRectMake(2.0, 2.0 + side, side - 4.0, 16.0);
    self.titleLabel.frame = CGRectMake(0.0, 2.0 + side + 18.0, w, 16.0);
    self.subtitleLabel.frame = CGRectMake(0.0, 2.0 + side + 34.0, w, 14.0);
    self.plate.layer.shadowPath = [UIBezierPath bezierPathWithRect:self.plate.bounds].CGPath;
    // One bitmap per cover. Live shadows on a scrolling strip stall an iPhone 4.
    self.layer.shouldRasterize = !self.highlighted;
    self.layer.rasterizationScale = [UIScreen mainScreen].scale;
}

@end

@interface waCoverStrip ()
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) NSArray *items;
@property (nonatomic, assign) CGFloat tileSide;
@end

@implementation waCoverStrip

+ (CGFloat)heightForSide:(CGFloat)side {
    return 8.0 + [waCoverView heightForSide:side] + 4.0;
}

- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        _scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
        _scrollView.backgroundColor = [UIColor clearColor];
        _scrollView.showsHorizontalScrollIndicator = NO;
        _scrollView.showsVerticalScrollIndicator = NO;
        _scrollView.alwaysBounceHorizontal = YES;
        _scrollView.alwaysBounceVertical = NO;
        _scrollView.directionalLockEnabled = YES;
        _scrollView.clipsToBounds = YES;
        _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_scrollView];
    }
    return self;
}

- (void)setItems:(NSArray *)items side:(CGFloat)side target:(id)target action:(SEL)action {
    if (side < 60.0) side = 100.0;
    NSMutableArray *covers = [NSMutableArray array];
    for (UIView *view in self.scrollView.subviews) {
        if ([view isKindOfClass:[waCoverView class]]) [covers addObject:view];
    }
    BOOL same = (fabs(self.tileSide - side) < 0.5 && self.items.count == items.count && covers.count == items.count);
    if (same) {
        for (NSUInteger i = 0; i < items.count; i++) {
            if ([self.items objectAtIndex:i] != [items objectAtIndex:i]) { same = NO; break; }
        }
    }
    _items = [items copy];
    self.tileSide = side;
    CGFloat gap = 10.0;
    CGFloat x = 10.0;
    CGFloat h = [waCoverView heightForSide:side];
    if (same) {
        for (waCoverView *cover in covers) {
            [cover removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
            if (target && action) [cover addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
        }
    } else {
        NSUInteger index = 0;
        for (id obj in self.items) {
            if (![obj isKindOfClass:[waItem class]]) continue;
            CGRect frame = CGRectMake(x, 6.0, side, h);
            waCoverView *cover = index < covers.count ? [covers objectAtIndex:index] : nil;
            if (!cover) {
                cover = [[waCoverView alloc] initWithFrame:frame];
                [self.scrollView addSubview:cover];
            } else {
                cover.frame = frame;
            }
            cover.tag = (NSInteger)index;
            [cover configureWithItem:obj side:side];
            [cover removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
            if (target && action) [cover addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
            x += side + gap;
            index++;
        }
        for (NSUInteger extra = index; extra < covers.count; extra++) {
            [[covers objectAtIndex:extra] removeFromSuperview];
        }
        self.scrollView.contentSize = CGSizeMake(MAX(x + 4.0, CGRectGetWidth(self.bounds)), h + 8.0);
    }
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.scrollView.frame = self.bounds;
    if (self.scrollView.contentSize.width < CGRectGetWidth(self.bounds)) {
        self.scrollView.contentSize = CGSizeMake(CGRectGetWidth(self.bounds), self.scrollView.contentSize.height);
    }
}

@end

@interface waCoverGrid ()
@property (nonatomic, strong) NSArray *items;
@property (nonatomic, assign) id tapTarget;
@property (nonatomic, assign) SEL tapAction;
@end

@implementation waCoverGrid

+ (CGFloat)heightForCount:(NSUInteger)count width:(CGFloat)width {
    CGFloat total = 0.0;
    waGridMetrics(width, count, NULL, NULL, NULL, &total);
    return total;
}

- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
    }
    return self;
}

- (void)setItems:(NSArray *)items target:(id)target action:(SEL)action {
    self.items = items ? items : [NSArray array];
    self.tapTarget = target;
    self.tapAction = action;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    NSMutableArray *covers = [NSMutableArray array];
    for (UIView *view in self.subviews) {
        if ([view isKindOfClass:[waCoverView class]]) [covers addObject:view];
    }
    NSUInteger cols = 2;
    CGFloat side = 100.0;
    CGFloat rowH = 0.0;
    waGridMetrics(CGRectGetWidth(self.bounds), self.items.count, &cols, &side, &rowH, NULL);
    CGFloat gap = 10.0;
    CGFloat x0 = 10.0;
    NSUInteger index = 0;
    for (id obj in self.items) {
        if (![obj isKindOfClass:[waItem class]]) continue;
        NSUInteger col = index % cols;
        NSUInteger row = index / cols;
        CGRect frame = CGRectMake(x0 + col * (side + gap), 8.0 + row * (rowH + 8.0), side, rowH);
        waCoverView *cover = index < covers.count ? [covers objectAtIndex:index] : nil;
        if (!cover) {
            cover = [[waCoverView alloc] initWithFrame:frame];
            [self addSubview:cover];
        } else {
            cover.frame = frame;
        }
        [cover configureWithItem:obj side:side];
        [cover removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
        if (self.tapTarget && self.tapAction) {
            [cover addTarget:self.tapTarget action:self.tapAction forControlEvents:UIControlEventTouchUpInside];
        }
        index++;
    }
    for (NSUInteger extra = index; extra < covers.count; extra++) {
        [[covers objectAtIndex:extra] removeFromSuperview];
    }
}

@end

@implementation waPageDots

- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        _numberOfPages = 1;
    }
    return self;
}

- (void)setNumberOfPages:(NSInteger)numberOfPages {
    if (numberOfPages < 1) numberOfPages = 1;
    _numberOfPages = numberOfPages;
    if (_currentPage >= numberOfPages) _currentPage = numberOfPages - 1;
    [self setNeedsDisplay];
}

- (void)setCurrentPage:(NSInteger)currentPage {
    if (currentPage < 0) currentPage = 0;
    if (self.numberOfPages > 0 && currentPage >= self.numberOfPages) currentPage = self.numberOfPages - 1;
    _currentPage = currentPage;
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    (void)rect;
    NSInteger count = self.numberOfPages;
    if (count < 1) return;
    CGFloat dot = 7.0;
    CGFloat gap = 8.0;
    CGFloat total = count * dot + (count - 1) * gap;
    CGFloat x = floor((CGRectGetWidth(self.bounds) - total) / 2.0);
    CGFloat y = floor((CGRectGetHeight(self.bounds) - dot) / 2.0);
    for (NSInteger i = 0; i < count; i++) {
        CGRect frame = CGRectMake(x, y, dot, dot);
        UIBezierPath *circle = [UIBezierPath bezierPathWithOvalInRect:frame];
        if (i == self.currentPage) {
            [[UIColor colorWithRed:0.15 green:0.37 blue:0.68 alpha:1.0] setFill];
            [circle fill];
            [[UIColor colorWithWhite:1.0 alpha:0.55] setStroke];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectInset(frame, 1.5, 2.5)] stroke];
        } else {
            [[UIColor colorWithWhite:0.55 alpha:1.0] setFill];
            [circle fill];
            [[UIColor colorWithWhite:1.0 alpha:0.75] setStroke];
            circle.lineWidth = 1.0;
            [circle stroke];
        }
        x += dot + gap;
    }
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    (void)event;
    UITouch *touch = [touches anyObject];
    if (!touch || self.numberOfPages < 1) return;
    CGPoint point = [touch locationInView:self];
    CGFloat dot = 7.0;
    CGFloat gap = 8.0;
    CGFloat total = self.numberOfPages * dot + (self.numberOfPages - 1) * gap;
    CGFloat start = (CGRectGetWidth(self.bounds) - total) / 2.0;
    NSInteger page = (NSInteger)((point.x - start) / (dot + gap));
    if (page < 0) page = 0;
    if (page >= self.numberOfPages) page = self.numberOfPages - 1;
    self.currentPage = page;
    if (self.pageChanged) self.pageChanged(page);
}

@end
