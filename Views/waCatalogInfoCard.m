#import "waCatalogInfoCard.h"
#import "waPlaceholder.h"
#import "../Services/waTheme.h"
#import <QuartzCore/QuartzCore.h>

@interface waCatalogInfoCard ()
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong, readwrite) UIImageView *coverView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong, readwrite) UILabel *stateLabel;
@property (nonatomic, strong, readwrite) UIButton *likeButton;
@property (nonatomic, strong, readwrite) UIButton *downloadButton;
@property (nonatomic, strong, readwrite) UIButton *playAllButton;
@property (nonatomic, strong) waMediaItem *item;
@property (nonatomic, assign) BOOL artistCard;
@property (nonatomic, assign) BOOL playlistCard;
@property (nonatomic, assign) BOOL landscapeLayout;
@end

@implementation waCatalogInfoCard

- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth;

        _cardView = [[UIView alloc] initWithFrame:CGRectZero];
        _cardView.backgroundColor = [waTheme surfaceColor];
        _cardView.layer.cornerRadius = 10.0;
        _cardView.layer.borderWidth = 0.0;
        _cardView.layer.shadowColor = [UIColor blackColor].CGColor;
        _cardView.layer.shadowOpacity = 0.09;
        _cardView.layer.shadowOffset = CGSizeMake(0.0, 1.0);
        _cardView.layer.shadowRadius = 4.0;
        [self addSubview:_cardView];

        _coverView = [[UIImageView alloc] initWithImage:waPlaceholderImage()];
        _coverView.contentMode = UIViewContentModeScaleAspectFill;
        _coverView.clipsToBounds = YES;
        _coverView.layer.cornerRadius = 6.0;
        _coverView.layer.borderWidth = 0.0;
        [_cardView addSubview:_coverView];

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        [waTheme applyPrimaryTextStyleToLabel:_titleLabel];
        _titleLabel.font = [waTheme extraBoldFontOfSize:22.0];
        _titleLabel.numberOfLines = 2;
        _titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
        [_cardView addSubview:_titleLabel];

        _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _subtitleLabel.backgroundColor = [UIColor clearColor];
        _subtitleLabel.textColor = [waTheme primaryTextColor];
        _subtitleLabel.font = [waTheme mediumFontOfSize:15.0];
        _subtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [_cardView addSubview:_subtitleLabel];

        _detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        [waTheme applySecondaryTextStyleToLabel:_detailLabel];
        _detailLabel.font = [waTheme secondaryRegularFontOfSize:13.0];
        _detailLabel.numberOfLines = 2;
        _detailLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [_cardView addSubview:_detailLabel];

        _likeButton = [self actionButtonWithTitle:@"Like" action:@selector(likePressed:)];
        _downloadButton = [self actionButtonWithTitle:@"Download" action:@selector(downloadPressed:)];
        _playAllButton = [self actionButtonWithTitle:@"Play All" action:@selector(playAllPressed:)];
        [_cardView addSubview:_likeButton];
        [_cardView addSubview:_downloadButton];
        [_cardView addSubview:_playAllButton];

        _stateLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        [waTheme applySecondaryTextStyleToLabel:_stateLabel];
        _stateLabel.font = [waTheme secondaryRegularFontOfSize:11.0];
        _stateLabel.textAlignment = NSTextAlignmentCenter;
        [_cardView addSubview:_stateLabel];
    }
    return self;
}

- (UIButton *)actionButtonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    [button setTitle:title forState:UIControlStateNormal];
    [waTheme applySkeuomorphicStyleToButton:button];
    button.titleLabel.font = [waTheme boldFontOfSize:12.0];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.72;
    button.titleLabel.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.65];
    button.titleLabel.shadowOffset = CGSizeMake(0.0, -1.0);
    button.contentEdgeInsets = UIEdgeInsetsMake(0.0, 3.0, 0.0, 3.0);
    button.layer.shadowColor = [UIColor blackColor].CGColor;
    button.layer.shadowOpacity = 0.25;
    button.layer.shadowOffset = CGSizeMake(0.0, 2.0);
    button.layer.shadowRadius = 1.5;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)applyTheme {
    self.cardView.backgroundColor = [waTheme surfaceColor];
    self.coverView.layer.borderColor = [UIColor colorWithWhite:0.0 alpha:0.35].CGColor;
    self.titleLabel.textColor = [waTheme primaryTextColor];
    self.subtitleLabel.textColor = self.playlistCard ? [waTheme secondaryTextColor] : [waTheme primaryTextColor];
    self.detailLabel.textColor = [waTheme secondaryTextColor];
    self.stateLabel.textColor = [waTheme secondaryTextColor];
    for (UIButton *button in @[self.likeButton, self.downloadButton, self.playAllButton]) {
        [waTheme applySkeuomorphicStyleToButton:button];
    }
    [self setNeedsLayout];
}

- (void)configureWithItem:(waMediaItem *)item listenerText:(NSString *)listenerText detailText:(NSString *)detailText {
    self.item = item;
    self.artistCard = item.type == waMediaItemTypeArtist;
    self.playlistCard = item.type == waMediaItemTypePlaylist;
    self.titleLabel.text = item.title.length ? item.title : @"Untitled";
    self.titleLabel.numberOfLines = self.artistCard ? 1 : 0;
    self.titleLabel.lineBreakMode = self.artistCard ? NSLineBreakByTruncatingTail : NSLineBreakByWordWrapping;
    self.subtitleLabel.text = self.artistCard ? @"Artist" : (item.artistName.length ? item.artistName : item.subtitle);
    self.subtitleLabel.font = self.playlistCard ? [waTheme secondaryRegularFontOfSize:12.5] : [waTheme mediumFontOfSize:15.0];
    self.subtitleLabel.textColor = self.playlistCard ? [waTheme secondaryTextColor] : [waTheme primaryTextColor];
    self.subtitleLabel.numberOfLines = self.playlistCard ? 2 : 1;
    self.subtitleLabel.lineBreakMode = self.playlistCard ? NSLineBreakByWordWrapping : NSLineBreakByTruncatingTail;
    self.detailLabel.text = detailText.length ? detailText : (self.artistCard ? listenerText : @"");
    self.stateLabel.text = self.stateLabel.text ?: @"";
    self.likeButton.selected = item.isLiked;
    [self.likeButton setTitle:item.isLiked ? @"Unlike" : @"Like" forState:UIControlStateNormal];
    self.downloadButton.hidden = self.artistCard;
    self.playAllButton.hidden = NO;
    NSString *playTitle = self.artistCard ? @"Play Top Tracks" : (item.type == waMediaItemTypePlaylist ? @"Play Playlist" : @"Play Album");
    [self.playAllButton setTitle:playTitle forState:UIControlStateNormal];
    self.coverView.image = waPlaceholderImage();
    [self applyTheme];
    [self setNeedsLayout];
}

- (CGFloat)preferredHeightForWidth:(CGFloat)width landscape:(BOOL)landscape {
    self.landscapeLayout = landscape;
    CGFloat cardWidth = MAX(0.0, width - 20.0);
    CGFloat coverSize = landscape ? MIN(112.0, MAX(96.0, cardWidth * 0.26)) : MIN(106.0, MAX(92.0, cardWidth * 0.30));
    CGFloat headerHeight = MAX(landscape ? 112.0 : 106.0, coverSize + 4.0);
    CGFloat titleWidth = MAX(40.0, cardWidth - coverSize - 36.0);
    CGFloat titleHeight = [self titleHeightForWidth:titleWidth];
    if (titleHeight > 42.0) headerHeight += titleHeight - 42.0;
    CGFloat subtitleHeight = [self subtitleHeightForWidth:titleWidth];
    if (subtitleHeight > 19.0) headerHeight += subtitleHeight - 19.0;
    if (self.detailLabel.text.length > 48) headerHeight += 10.0;
    // One information row, one status row and one equal-width action row.
    // The actions never compete with the artwork for horizontal space.
    return 10.0 + 12.0 + headerHeight + 4.0 + 15.0 + 4.0 + 40.0 + 10.0;
}

- (CGFloat)titleHeightForWidth:(CGFloat)width {
    if (self.artistCard) return 26.0;
    CGSize size = [self.titleLabel.text sizeWithFont:self.titleLabel.font constrainedToSize:CGSizeMake(MAX(40.0, width), 160.0) lineBreakMode:NSLineBreakByWordWrapping];
    return MAX(26.0, ceil(size.height));
}

- (CGFloat)subtitleHeightForWidth:(CGFloat)width {
    if (!self.playlistCard) return 19.0;
    CGSize size = [self.subtitleLabel.text sizeWithFont:self.subtitleLabel.font constrainedToSize:CGSizeMake(MAX(40.0, width), 48.0) lineBreakMode:NSLineBreakByWordWrapping];
    return MAX(19.0, MIN(42.0, ceil(size.height)));
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width;
    CGFloat height = self.bounds.size.height;
    CGFloat outerInset = self.landscapeLayout ? 9.0 : 10.0;
    self.cardView.frame = CGRectMake(outerInset, 5.0, MAX(0.0, width - outerInset * 2.0), MAX(0.0, height - 10.0));
    self.cardView.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.cardView.bounds cornerRadius:12.0].CGPath;

    CGRect cardBounds = self.cardView.bounds;
    CGFloat cardWidth = CGRectGetWidth(cardBounds);
    CGFloat cardHeight = CGRectGetHeight(cardBounds);
    CGFloat contentInset = 12.0;
    CGFloat actionHeight = 40.0;
    CGFloat buttonY = cardHeight - 10.0 - actionHeight;
    CGFloat stateY = buttonY - 19.0;
    CGFloat headerY = 12.0;
    CGFloat headerHeight = MAX(0.0, stateY - headerY - 5.0);

    CGFloat coverSize = self.landscapeLayout ? MIN(112.0, headerHeight - 4.0) : MIN(106.0, headerHeight - 4.0);
    coverSize = MAX(0.0, coverSize);
    CGFloat coverX = contentInset;
    CGFloat coverY = headerY + MAX(0.0, (headerHeight - coverSize) / 2.0);
    self.coverView.frame = CGRectMake(coverX, coverY, coverSize, coverSize);

    CGFloat textX = CGRectGetMaxX(self.coverView.frame) + 12.0;
    CGFloat textWidth = MAX(40.0, cardWidth - textX - contentInset);
    CGFloat titleHeight = [self titleHeightForWidth:textWidth];
    CGFloat subtitleHeight = [self subtitleHeightForWidth:textWidth];
    self.titleLabel.frame = CGRectMake(textX, headerY, textWidth, titleHeight);
    self.subtitleLabel.frame = CGRectMake(textX, CGRectGetMaxY(self.titleLabel.frame) + 2.0, textWidth, subtitleHeight);
    self.detailLabel.frame = CGRectMake(textX, CGRectGetMaxY(self.subtitleLabel.frame) + 2.0, textWidth, MAX(0.0, headerHeight - titleHeight - subtitleHeight - 4.0));

    self.stateLabel.frame = CGRectMake(contentInset, stateY, MAX(0.0, cardWidth - contentInset * 2.0), 15.0);

    NSMutableArray *buttons = [NSMutableArray array];
    if (!self.likeButton.hidden) [buttons addObject:self.likeButton];
    if (!self.downloadButton.hidden) [buttons addObject:self.downloadButton];
    if (!self.playAllButton.hidden) [buttons addObject:self.playAllButton];
    CGFloat gap = buttons.count > 1 ? 6.0 : 0.0;
    CGFloat rowWidth = MAX(0.0, cardWidth - contentInset * 2.0);
    CGFloat buttonWidth = buttons.count ? MAX(1.0, (rowWidth - gap * (buttons.count - 1)) / buttons.count) : 0.0;
    CGFloat left = contentInset;
    for (UIButton *button in buttons) {
        button.frame = CGRectMake(left, buttonY, buttonWidth, actionHeight);
        button.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:button.bounds cornerRadius:7.0].CGPath;
        left += buttonWidth + gap;
    }
}

- (void)likePressed:(id)sender {
    (void)sender;
    if ([self.delegate respondsToSelector:@selector(catalogInfoCardDidPressLike:)]) [self.delegate catalogInfoCardDidPressLike:self];
}
- (void)downloadPressed:(id)sender {
    (void)sender;
    if ([self.delegate respondsToSelector:@selector(catalogInfoCardDidPressDownload:)]) [self.delegate catalogInfoCardDidPressDownload:self];
}
- (void)playAllPressed:(id)sender {
    (void)sender;
    if ([self.delegate respondsToSelector:@selector(catalogInfoCardDidPressPlayAll:)]) [self.delegate catalogInfoCardDidPressPlayAll:self];
}

@end
