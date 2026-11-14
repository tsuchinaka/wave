#import "waTileView.h"
#import "waSession.h"

@implementation waTileView

+ (CGFloat)heightForArtworkSide:(CGFloat)side {
    return side + 32.0;
}

- (id)initWithFrame:(CGRect)frame item:(waItem *)item artworkSide:(CGFloat)side {
    if ((self = [super initWithFrame:frame])) {
        _artworkSide = side > 0.0 ? side : 88.0;
        self.backgroundColor = [UIColor clearColor];

        _artworkView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _artworkView.contentMode = UIViewContentModeScaleAspectFill;
        _artworkView.clipsToBounds = YES;
        _artworkView.opaque = YES;
        _artworkView.backgroundColor = [UIColor colorWithWhite:0.9 alpha:1.0];
        _artworkView.userInteractionEnabled = NO;
        [self addSubview:_artworkView];

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.backgroundColor = [UIColor clearColor];
        _titleLabel.font = [UIFont boldSystemFontOfSize:12.0];
        _titleLabel.textColor = [UIColor blackColor];
        _titleLabel.textAlignment = UITextAlignmentLeft;
        _titleLabel.lineBreakMode = UILineBreakModeTailTruncation;
        _titleLabel.userInteractionEnabled = NO;
        [self addSubview:_titleLabel];

        _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _subtitleLabel.backgroundColor = [UIColor clearColor];
        _subtitleLabel.font = [UIFont systemFontOfSize:11.0];
        _subtitleLabel.textColor = [UIColor grayColor];
        _subtitleLabel.textAlignment = UITextAlignmentLeft;
        _subtitleLabel.lineBreakMode = UILineBreakModeTailTruncation;
        _subtitleLabel.userInteractionEnabled = NO;
        [self addSubview:_subtitleLabel];

        [self configureWithItem:item];
    }
    return self;
}

- (void)configureWithItem:(waItem *)item {
    BOOL same = (_item == item && self.artworkView.image != nil);
    if (!same) [[waSession shared] cancelArtworkForOwner:self];
    _item = item;
    self.titleLabel.text = item.title.length ? item.title : @"";
    NSString *sub = @"";
    if ([item isKindOfClass:[waTrack class]]) {
        waTrack *t = (waTrack *)item;
        sub = t.artistName.length ? t.artistName : @"";
    } else if ([item isKindOfClass:[waAlbum class]]) {
        waAlbum *a = (waAlbum *)item;
        sub = a.artistName.length ? a.artistName : @"";
    } else if ([item isKindOfClass:[waArtist class]]) {
        waArtist *a = (waArtist *)item;
        if (a.fanCount > 0) sub = [NSString stringWithFormat:@"%ld fans", (long)a.fanCount];
    } else if ([item isKindOfClass:[waPlaylist class]]) {
        waPlaylist *p = (waPlaylist *)item;
        if (p.trackCount > 0) sub = [NSString stringWithFormat:@"%ld songs", (long)p.trackCount];
        else if (p.creatorName.length) sub = p.creatorName;
    } else {
        sub = item.subtitle.length ? item.subtitle : @"";
    }
    self.subtitleLabel.text = sub;
    if (!same) [self loadArtwork];
    [self setNeedsLayout];
}

- (NSString *)artworkURL {
    return [self.item artworkURLForSide:self.artworkSide];
}

- (void)loadArtwork {
    NSString *url = [self artworkURL];
    CGSize size = CGSizeMake(self.artworkSide, self.artworkSide);
    UIImage *cached = [[waSession shared] cachedArtwork:url size:size];
    if (cached) {
        self.artworkView.image = cached;
        return;
    }
    self.artworkView.image = nil;
    if (!url.length) return;
    __weak waTileView *weakSelf = self;
    NSString *copy = [url copy];
    [[waSession shared] loadArtwork:copy size:size owner:self completion:^(UIImage *image) {
        waTileView *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (![[strongSelf artworkURL] isEqualToString:copy]) return;
        strongSelf.artworkView.image = image;
    }];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = CGRectGetWidth(self.bounds);
    CGFloat side = self.artworkSide;
    if (side > w) side = w;
    self.artworkView.frame = CGRectMake(0.0, 0.0, side, side);
    self.titleLabel.frame = CGRectMake(0.0, side + 2.0, w, 16.0);
    self.subtitleLabel.frame = CGRectMake(0.0, side + 18.0, w, 14.0);
}

@end
