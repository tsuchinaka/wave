#import "waMediaInfoCell.h"
#import "../Services/waTheme.h"
#import "waPlaceholder.h"
#import <QuartzCore/QuartzCore.h>

@interface waMediaInfoCell ()
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong, readwrite) UIImageView *coverView;
@property (nonatomic, strong, readwrite) UILabel *titleLabel;
@property (nonatomic, strong, readwrite) UILabel *subtitleLabel;
@property (nonatomic, strong, readwrite) UILabel *yearLabel;
@property (nonatomic, strong, readwrite) UILabel *countLabel;
@property (nonatomic, strong, readwrite) UILabel *stateLabel;
@property (nonatomic, strong, readwrite) UIButton *likeButton;
@property (nonatomic, strong, readwrite) UIButton *downloadButton;
@property (nonatomic, strong, readwrite) UIButton *playAllButton;
@property (nonatomic, strong) UILabel *explicitIconLabel;
@end

@implementation waMediaInfoCell

- (CGFloat)preferredHeight {
    CGFloat width = self.bounds.size.width > 0.0 ? self.bounds.size.width : 320.0;
    CGFloat buttonsY = [self buttonsYForWidth:width];
    return MAX(170.0, buttonsY + (self.stateLabel.text.length ? 78.0 : 58.0));
}

- (CGFloat)titleHeightForWidth:(CGFloat)width {
    (void)width;
    // Reserve two lines at all times. Catalog responses can replace a long
    // provisional title with a shorter canonical one; measuring the text made
    // the entire product card visibly collapse when that happened.
    return ceil(self.titleLabel.font.lineHeight * 2.0);
}

- (CGFloat)buttonsYForWidth:(CGFloat)width {
    CGFloat textBottom = 10.0 + [self titleHeightForWidth:width] + 4.0 + 20.0 + 20.0 + 18.0;
    return MAX(112.0, textBottom + 7.0);
}

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = [UIColor clearColor];
        self.contentView.backgroundColor = [UIColor clearColor];

        _cardView = [[UIView alloc] initWithFrame:CGRectZero];
        _cardView.backgroundColor = [waTheme surfaceColor];
        _cardView.layer.cornerRadius = 8.0;
        _cardView.layer.borderWidth = 0.0;
        _cardView.layer.shadowColor = [UIColor blackColor].CGColor;
        _cardView.layer.shadowOpacity = 0.08;
        _cardView.layer.shadowOffset = CGSizeMake(0.0, 1.0);
        _cardView.layer.shadowRadius = 3.0;
        [self.contentView addSubview:_cardView];

        _coverView = [[UIImageView alloc] initWithImage:waPlaceholderImage()];
        _coverView.contentMode = UIViewContentModeScaleAspectFill;
        _coverView.clipsToBounds = YES;
        _coverView.layer.cornerRadius = 6.0;
        _coverView.layer.borderWidth = 0.0;
        [self.contentView addSubview:_coverView];

        _titleLabel = [[UILabel alloc] init];
        [waTheme applyPrimaryTextStyleToLabel:_titleLabel];
        _titleLabel.font = [waTheme extraBoldFontOfSize:21.0];
        _titleLabel.numberOfLines = 2;
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.contentView addSubview:_titleLabel];

        _explicitIconLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _explicitIconLabel.text = @"z";
        _explicitIconLabel.font = [UIFont fontWithName:@"Deezer-Font-Icon" size:14.0] ?: [waTheme boldFontOfSize:11.0];
        _explicitIconLabel.textColor = [waTheme secondaryTextColor];
        _explicitIconLabel.textAlignment = NSTextAlignmentCenter;
        _explicitIconLabel.backgroundColor = [UIColor clearColor];
        _explicitIconLabel.accessibilityLabel = @"Explicit content";
        _explicitIconLabel.hidden = YES;
        [self.contentView addSubview:_explicitIconLabel];

        NSArray *labels = @[[[UILabel alloc] init], [[UILabel alloc] init], [[UILabel alloc] init]];
        _subtitleLabel = labels[0];
        _yearLabel = labels[1];
        _countLabel = labels[2];
        for (UILabel *label in labels) {
            [waTheme applySecondaryTextStyleToLabel:label];
            label.font = [waTheme regularFontOfSize:13.0];
            label.lineBreakMode = NSLineBreakByTruncatingTail;
            [self.contentView addSubview:label];
        }

        _likeButton = [self actionButtonWithTitle:@"Like" action:@selector(likePressed:)];
        _downloadButton = [self actionButtonWithTitle:@"Download" action:@selector(downloadPressed:)];
        _playAllButton = [self actionButtonWithTitle:@"Play All" action:@selector(playAllPressed:)];
        [self.contentView addSubview:_likeButton];
        [self.contentView addSubview:_downloadButton];
        [self.contentView addSubview:_playAllButton];

        _stateLabel = [[UILabel alloc] init];
        [waTheme applySecondaryTextStyleToLabel:_stateLabel];
        _stateLabel.font = [waTheme regularFontOfSize:12.0];
        _stateLabel.textAlignment = NSTextAlignmentCenter;
        _stateLabel.backgroundColor = [UIColor clearColor];
        [self.contentView addSubview:_stateLabel];
    }
    return self;
}

- (void)applyTheme {
    self.cardView.backgroundColor = [waTheme surfaceColor];
    self.titleLabel.textColor = [waTheme primaryTextColor];
    self.subtitleLabel.textColor = [waTheme secondaryTextColor];
    self.yearLabel.textColor = [waTheme secondaryTextColor];
    self.countLabel.textColor = [waTheme secondaryTextColor];
    self.stateLabel.textColor = [waTheme secondaryTextColor];
    for (UIButton *button in @[self.likeButton, self.downloadButton, self.playAllButton]) {
        [waTheme applySkeuomorphicStyleToButton:button];
    }
    [self setNeedsLayout];
}

- (UIButton *)actionButtonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    [button setTitle:title forState:UIControlStateNormal];
    [waTheme applySkeuomorphicStyleToButton:button];
    button.titleLabel.font = [waTheme boldFontOfSize:13.0];
    button.titleLabel.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.65];
    button.titleLabel.shadowOffset = CGSizeMake(0.0, -1.0);
    button.contentEdgeInsets = UIEdgeInsetsMake(0.0, 4.0, 0.0, 4.0);
    button.layer.shadowColor = [UIColor blackColor].CGColor;
    button.layer.shadowOpacity = 0.28;
    button.layer.shadowOffset = CGSizeMake(0.0, 2.0);
    button.layer.shadowRadius = 1.5;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)configureWithItem:(waMediaItem *)item year:(NSString *)year countText:(NSString *)countText listenerText:(NSString *)listenerText {
    self.titleLabel.text = item.title ?: @"Untitled";
    self.explicitIconLabel.hidden = !item.isExplicit;
    self.coverView.image = waPlaceholderImage();
    self.subtitleLabel.text = @"";
    self.yearLabel.text = year ?: @"";
    self.countLabel.text = countText ?: @"";

    BOOL album = item.type == waMediaItemTypeAlbum;
    BOOL artist = item.type == waMediaItemTypeArtist;
    self.subtitleLabel.text = album ? (item.artistName ?: @"") : (artist ? @"Artist" : (item.subtitle ?: @""));
    if (artist) {
        // Keep the artist card's metadata lines consecutive like an album:
        // Artist on line one, Fans on line two, no empty year row.
        self.yearLabel.text = listenerText ?: @"";
        self.countLabel.text = @"";
    }
    self.likeButton.hidden = NO;
    self.downloadButton.hidden = artist;
    self.playAllButton.hidden = NO;
    [self.likeButton setTitle:item.isLiked ? @"Unlike" : @"Like" forState:UIControlStateNormal];
    self.likeButton.selected = item.isLiked;
    [self.playAllButton setTitle:item.type == waMediaItemTypeSong ? @"Play" : @"Play All" forState:UIControlStateNormal];
    [self applyTheme];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.contentView.bounds.size.width;
    CGFloat coverSize = 88.0;
    CGFloat cardInset = 9.0;
    self.cardView.frame = CGRectMake(cardInset, 6.0, width - cardInset * 2.0, self.contentView.bounds.size.height - 12.0);
    self.cardView.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.cardView.bounds cornerRadius:self.cardView.layer.cornerRadius].CGPath;
    CGFloat textX = 120.0;
    CGFloat textWidth = MAX(80.0, width - textX - 20.0);
    self.coverView.frame = CGRectMake(20.0, 14.0, coverSize, coverSize);
    CGFloat titleHeight = [self titleHeightForWidth:width];
    self.explicitIconLabel.frame = CGRectMake(width - 42.0, 12.0, 20.0, 20.0);
    self.titleLabel.frame = CGRectMake(textX, 12.0, MAX(40.0, textWidth - (self.explicitIconLabel.hidden ? 0.0 : 24.0)), titleHeight);
    CGFloat textY = CGRectGetMaxY(self.titleLabel.frame) + 4.0;
    self.subtitleLabel.frame = CGRectMake(textX, textY, textWidth, 18.0);
    textY += 20.0;
    self.yearLabel.frame = CGRectMake(textX, textY, textWidth, 18.0);
    textY += 20.0;
    self.countLabel.frame = CGRectMake(textX, textY, textWidth, 18.0);

    NSMutableArray *buttons = [NSMutableArray array];
    if (!self.likeButton.hidden) [buttons addObject:self.likeButton];
    if (!self.downloadButton.hidden) [buttons addObject:self.downloadButton];
    if (!self.playAllButton.hidden) [buttons addObject:self.playAllButton];
    CGFloat left = 20.0;
    CGFloat gap = buttons.count > 1 ? 6.0 : 0.0;
    CGFloat buttonWidth = buttons.count ? (width - 40.0 - gap * (buttons.count - 1)) / buttons.count : 0.0;
    CGFloat buttonsY = [self buttonsYForWidth:width];
    for (UIButton *button in buttons) {
        // Keep the full recommended iOS touch target without changing the
        // visual spacing between the buttons.
        button.frame = CGRectMake(left, buttonsY, buttonWidth, 44.0);
        button.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:button.bounds cornerRadius:6.0].CGPath;
        left += buttonWidth + gap;
    }
    self.stateLabel.frame = CGRectMake(20.0, buttons.count ? buttonsY + 48.0 : textY + 7.0, width - 40.0, self.stateLabel.text.length ? 16.0 : 0.0);
}

- (void)likePressed:(id)sender { if ([self.delegate respondsToSelector:@selector(mediaInfoCellDidPressLike:)]) [self.delegate mediaInfoCellDidPressLike:self]; }
- (void)downloadPressed:(id)sender { if ([self.delegate respondsToSelector:@selector(mediaInfoCellDidPressDownload:)]) [self.delegate mediaInfoCellDidPressDownload:self]; }
- (void)playAllPressed:(id)sender { if ([self.delegate respondsToSelector:@selector(mediaInfoCellDidPressPlayAll:)]) [self.delegate mediaInfoCellDidPressPlayAll:self]; }

@end
