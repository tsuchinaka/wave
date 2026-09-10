#import "waCatalogTrackCell.h"
#import "waPlaceholder.h"
#import "../Services/waAPIClient.h"
#import "../Services/waImageLoader.h"
#import "../Services/waTheme.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>

typedef NS_ENUM(NSInteger, waCatalogTrackLayout) {
    waCatalogTrackLayoutArtist = 0,
    waCatalogTrackLayoutAlbum,
    waCatalogTrackLayoutPlaylist
};

@interface waCatalogTrackCell ()
@property (nonatomic, strong, readwrite) waMediaItem *trackItem;
@property (nonatomic, strong) UIImageView *artworkView;
@property (nonatomic, strong) UILabel *numberLabel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *artistLabel;
@property (nonatomic, strong) UILabel *albumLabel;
@property (nonatomic, strong) UILabel *durationLabel;
@property (nonatomic, strong) UILabel *explicitLabel;
@property (nonatomic, strong) UIButton *likeButton;
@property (nonatomic, strong) UIImageView *downloadIconView;
@property (nonatomic, copy) NSString *expectedArtworkURL;
@property (nonatomic, assign) waCatalogTrackLayout layoutMode;
// Cached per-theme tinted icons so configure never rebuilds them per row
// (follows the waArtworkCell refreshThemeCacheIfNeeded pattern).
@property (nonatomic, copy) NSString *cachedIconThemeKey;
@property (nonatomic, strong) UIImage *cachedHeartNormal;
@property (nonatomic, strong) UIImage *cachedHeartSelected;
@property (nonatomic, strong) UIImage *cachedDownloadIcon;
// Cached explicit-badge title measurement, keyed by text + available width.
@property (nonatomic, copy) NSString *measuredTitleText;
@property (nonatomic, assign) CGFloat measuredTitleAvailWidth;
@property (nonatomic, assign) CGFloat measuredTitleWidth;
@end

static NSString *waCatalogDurationText(NSTimeInterval duration) {
    if (!isfinite(duration) || duration <= 0.0) return @"";
    // Some older catalog responses expose milliseconds as `duration`. The
    // model handles explicit duration_ms fields, but this final guard keeps
    // the cell correct for mixed Deezer payloads too.
    if (duration > 100000.0) duration /= 1000.0;
    NSInteger seconds = (NSInteger)floor(duration + 0.5);
    if (seconds <= 0) return @"";
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(seconds / 60), (long)(seconds % 60)];
}

@implementation waCatalogTrackCell

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleGray;
        self.backgroundColor = [UIColor clearColor];
        self.contentView.backgroundColor = [UIColor clearColor];

        _numberLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _numberLabel.backgroundColor = [UIColor clearColor];
        [waTheme applySecondaryTextStyleToLabel:_numberLabel];
        _numberLabel.font = [waTheme secondaryMediumFontOfSize:11.0];
        _numberLabel.textAlignment = NSTextAlignmentCenter;
        [self.contentView addSubview:_numberLabel];

        _artworkView = [[UIImageView alloc] initWithImage:waPlaceholderImage()];
        _artworkView.contentMode = UIViewContentModeScaleAspectFill;
        _artworkView.clipsToBounds = YES;
        _artworkView.layer.cornerRadius = [waTheme cornerRadius];
        _artworkView.layer.borderWidth = 1.0;
        _artworkView.layer.borderColor = [UIColor colorWithWhite:0.0 alpha:0.30].CGColor;
        [self.contentView addSubview:_artworkView];

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.backgroundColor = [UIColor clearColor];
        [waTheme applyPrimaryTextStyleToLabel:_titleLabel];
        _titleLabel.font = [waTheme mediumFontOfSize:16.0];
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.contentView addSubview:_titleLabel];

        _artistLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _artistLabel.backgroundColor = [UIColor clearColor];
        [waTheme applySecondaryTextStyleToLabel:_artistLabel];
        _artistLabel.font = [waTheme secondaryRegularFontOfSize:12.5];
        _artistLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.contentView addSubview:_artistLabel];

        _albumLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _albumLabel.backgroundColor = [UIColor clearColor];
        [waTheme applySecondaryTextStyleToLabel:_albumLabel];
        _albumLabel.font = [waTheme secondaryRegularFontOfSize:11.5];
        _albumLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.contentView addSubview:_albumLabel];

        _durationLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _durationLabel.backgroundColor = [UIColor clearColor];
        [waTheme applySecondaryTextStyleToLabel:_durationLabel];
        _durationLabel.font = [waTheme secondaryRegularFontOfSize:10.5];
        _durationLabel.textAlignment = NSTextAlignmentRight;
        [self.contentView addSubview:_durationLabel];

        _explicitLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _explicitLabel.text = @"z";
        _explicitLabel.font = [UIFont fontWithName:@"Deezer-Font-Icon" size:14.0] ?: [waTheme boldFontOfSize:11.0];
        _explicitLabel.textColor = [waTheme secondaryTextColor];
        _explicitLabel.textAlignment = NSTextAlignmentCenter;
        _explicitLabel.backgroundColor = [UIColor clearColor];
        _explicitLabel.accessibilityLabel = @"Explicit content";
        _explicitLabel.hidden = YES;
        [self.contentView addSubview:_explicitLabel];

        _likeButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _likeButton.backgroundColor = [UIColor clearColor];
        _likeButton.adjustsImageWhenHighlighted = YES;
        _likeButton.imageView.contentMode = UIViewContentModeScaleAspectFit;
        _likeButton.accessibilityLabel = @"Like song";
        [_likeButton addTarget:self action:@selector(likePressed:) forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:_likeButton];
        [self updateLikeImages];

        _downloadIconView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _downloadIconView.contentMode = UIViewContentModeScaleAspectFit;
        _downloadIconView.hidden = YES;
        _downloadIconView.accessibilityLabel = @"Downloaded";
        [self.contentView addSubview:_downloadIconView];

        UIView *selected = [[UIView alloc] initWithFrame:CGRectZero];
        selected.backgroundColor = [waTheme selectedSurfaceColor];
        self.selectedBackgroundView = selected;
    }
    return self;
}

- (void)refreshIconCacheIfNeeded {
    NSString *key = [waTheme renderCacheKeyForColor:[waTheme barColor]];
    if ([key isEqualToString:self.cachedIconThemeKey]) return;
    self.cachedIconThemeKey = key;
    UIImage *heart = [UIImage imageNamed:@"wave-love"];
    self.cachedHeartNormal = [waTheme tintedIcon:heart withColor:[waTheme barColor]];
    self.cachedHeartSelected = [waTheme tintedIcon:heart withColor:[waTheme likeSelectedColor]];
    self.cachedDownloadIcon = [waTheme tintedIcon:[UIImage imageNamed:@"wave-downloaded"] withColor:[waTheme barColor]];
}

- (void)updateLikeImages {
    [self refreshIconCacheIfNeeded];
    [_likeButton setImage:self.cachedHeartNormal forState:UIControlStateNormal];
    [_likeButton setImage:self.cachedHeartSelected forState:UIControlStateSelected];
}

- (void)applyTheme {
    [self refreshIconCacheIfNeeded];
    self.measuredTitleText = nil;
    self.contentView.backgroundColor = [UIColor clearColor];
    self.numberLabel.textColor = [waTheme secondaryTextColor];
    self.titleLabel.textColor = [waTheme primaryTextColor];
    self.artistLabel.textColor = [waTheme secondaryTextColor];
    self.albumLabel.textColor = [waTheme secondaryTextColor];
    self.durationLabel.textColor = [waTheme secondaryTextColor];
    self.explicitLabel.textColor = [waTheme secondaryTextColor];
    self.selectedBackgroundView.backgroundColor = [waTheme selectedSurfaceColor];
    [self updateLikeImages];
    if (!self.downloadIconView.hidden) self.downloadIconView.image = self.cachedDownloadIcon;
    [self setNeedsLayout];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.trackItem = nil;
    self.expectedArtworkURL = nil;
    self.measuredTitleText = nil;
    self.layoutMode = waCatalogTrackLayoutArtist;
    self.artworkView.image = waPlaceholderImage();
    self.artworkView.hidden = NO;
    self.numberLabel.text = @"";
    self.numberLabel.hidden = YES;
    self.titleLabel.text = nil;
    self.titleLabel.hidden = NO;
    self.artistLabel.text = nil;
    self.artistLabel.hidden = NO;
    self.albumLabel.text = nil;
    self.albumLabel.hidden = NO;
    self.durationLabel.text = nil;
    self.explicitLabel.hidden = YES;
    self.likeButton.selected = NO;
    self.downloadIconView.hidden = YES;
    self.downloadIconView.image = nil;
}

- (void)configureItem:(waMediaItem *)item artistName:(NSString *)artistName albumName:(NSString *)albumName trackNumber:(NSUInteger)trackNumber layout:(waCatalogTrackLayout)layout {
    self.trackItem = item;
    self.layoutMode = layout;
    self.numberLabel.text = trackNumber ? [NSString stringWithFormat:@"%lu", (unsigned long)trackNumber] : @"";
    self.numberLabel.hidden = trackNumber == 0;
    self.titleLabel.text = item.title.length ? item.title : @"Untitled track";
    self.artistLabel.text = artistName.length ? artistName : (item.artistName.length ? item.artistName : item.subtitle);
    self.albumLabel.text = albumName.length ? albumName : item.albumName;
    self.artworkView.hidden = layout == waCatalogTrackLayoutAlbum;
    self.artistLabel.hidden = layout == waCatalogTrackLayoutAlbum;
    self.albumLabel.hidden = layout != waCatalogTrackLayoutArtist;
    self.explicitLabel.hidden = !item.isExplicit;
    self.likeButton.selected = item.isLiked;
    self.likeButton.accessibilityLabel = item.isLiked ? @"Unlike song" : @"Like song";
    NSString *durationText = waCatalogDurationText(item.duration);
    self.durationLabel.text = layout == waCatalogTrackLayoutAlbum && !durationText.length ? @"0:00" : durationText;
    self.artworkView.image = waPlaceholderImage();
    self.expectedArtworkURL = layout == waCatalogTrackLayoutAlbum ? nil : [item.thumbnailURL copy];
    NSString *artist = self.artistLabel.text.length ? self.artistLabel.text : @"";
    self.accessibilityLabel = artist.length ? [NSString stringWithFormat:@"%@, %@", self.titleLabel.text, artist] : self.titleLabel.text;
    self.accessibilityValue = self.durationLabel.text.length ? self.durationLabel.text : nil;
    [self applyTheme];
    if (layout != waCatalogTrackLayoutAlbum && self.expectedArtworkURL.length) {
        NSURL *url = [NSURL URLWithString:self.expectedArtworkURL];
        if (!url.scheme.length) url = [[waAPIClient sharedClient] URLForPath:self.expectedArtworkURL];
        __weak waCatalogTrackCell *weakCell = self;
        [[waImageLoader sharedLoader] loadThumbnailAtURL:url.absoluteString targetSize:CGSizeMake(128.0, 128.0) placeholder:waPlaceholderImage() completion:^(UIImage *image) {
            waCatalogTrackCell *cell = weakCell;
            if (cell && cell.trackItem == item && [cell.expectedArtworkURL isEqualToString:item.thumbnailURL] && image) cell.artworkView.image = image;
        }];
    }
    [self setNeedsLayout];
}

- (void)configureWithItem:(waMediaItem *)item artistName:(NSString *)artistName albumName:(NSString *)albumName trackNumber:(NSUInteger)trackNumber {
    [self configureItem:item artistName:artistName albumName:albumName trackNumber:trackNumber layout:trackNumber ? waCatalogTrackLayoutAlbum : waCatalogTrackLayoutArtist];
}

- (void)configureForPlaylistItem:(waMediaItem *)item artistName:(NSString *)artistName {
    [self configureItem:item artistName:artistName albumName:nil trackNumber:0 layout:waCatalogTrackLayoutPlaylist];
}

- (void)setDownloadState:(waDownloadState)state progress:(float)progress {
    (void)progress;
    [self refreshIconCacheIfNeeded];
    self.downloadIconView.image = self.cachedDownloadIcon;
    self.downloadIconView.hidden = state != waDownloadStateCompleted;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.contentView.bounds);
    CGFloat height = CGRectGetHeight(self.contentView.bounds);

    if (self.layoutMode == waCatalogTrackLayoutAlbum) {
        CGFloat leftInset = [waTheme standardMargin];
        CGFloat numberWidth = 34.0;
        CGFloat textX = leftInset + numberWidth + 6.0;
        CGFloat actionWidth = 42.0;
        CGFloat likeX = MAX(textX, width - actionWidth - [waTheme standardMargin]);
        BOOL downloaded = !self.downloadIconView.hidden;
        CGFloat downloadWidth = downloaded ? 26.0 : 0.0;
        CGFloat downloadX = likeX - downloadWidth;
        CGFloat durationWidth = self.durationLabel.text.length ? 42.0 : 0.0;
        CGFloat durationX = downloadX - (durationWidth ? 6.0 : 0.0) - durationWidth;
        CGFloat explicitWidth = self.explicitLabel.hidden ? 0.0 : 20.0;
        CGFloat explicitX = durationX - (explicitWidth ? 6.0 : 0.0) - explicitWidth;
        CGFloat titleRight = explicitWidth ? explicitX - 6.0 : durationX - 6.0;

        self.numberLabel.frame = CGRectMake(leftInset, 0.0, numberWidth, height);
        self.artworkView.frame = CGRectZero;
        self.artistLabel.frame = CGRectZero;
        self.albumLabel.frame = CGRectZero;
        self.titleLabel.frame = CGRectMake(textX, MAX(0.0, (height - 22.0) / 2.0), MAX(20.0, titleRight - textX), 22.0);
        self.durationLabel.frame = durationWidth ? CGRectMake(durationX, 0.0, durationWidth, height) : CGRectZero;
        self.explicitLabel.frame = explicitWidth ? CGRectMake(explicitX, MAX(0.0, (height - 18.0) / 2.0), explicitWidth, 18.0) : CGRectZero;
        self.downloadIconView.frame = downloaded ? CGRectMake(downloadX + 3.0, MAX(0.0, (height - 20.0) / 2.0), 20.0, 20.0) : CGRectZero;
        self.likeButton.frame = CGRectMake(likeX, MAX(0.0, (height - 40.0) / 2.0), actionWidth, 40.0);
        return;
    }

    if (self.layoutMode == waCatalogTrackLayoutPlaylist) {
        CGFloat artworkSize = height >= 58.0 ? 48.0 : 44.0;
        CGFloat artworkX = [waTheme standardMargin];
        CGFloat textX = artworkX + artworkSize + 10.0;
        CGFloat actionWidth = 42.0;
        CGFloat likeX = MAX(textX, width - actionWidth - [waTheme standardMargin]);
        BOOL downloaded = !self.downloadIconView.hidden;
        CGFloat downloadWidth = downloaded ? 26.0 : 0.0;
        CGFloat downloadX = likeX - downloadWidth;
        CGFloat durationWidth = self.durationLabel.text.length ? 42.0 : 0.0;
        CGFloat durationX = downloadX - (durationWidth ? 6.0 : 0.0) - durationWidth;
        CGFloat explicitWidth = self.explicitLabel.hidden ? 0.0 : 20.0;
        CGFloat explicitX = durationX - (explicitWidth ? 6.0 : 0.0) - explicitWidth;
        CGFloat titleRight = explicitWidth ? explicitX - 6.0 : durationX - 6.0;

        self.numberLabel.frame = CGRectZero;
        self.artworkView.frame = CGRectMake(artworkX, MAX(0.0, (height - artworkSize) / 2.0), artworkSize, artworkSize);
        self.titleLabel.frame = CGRectMake(textX, 6.0, MAX(20.0, titleRight - textX), 22.0);
        self.artistLabel.frame = CGRectMake(textX, 29.0, MAX(20.0, titleRight - textX), 18.0);
        self.albumLabel.frame = CGRectZero;
        self.durationLabel.frame = durationWidth ? CGRectMake(durationX, 0.0, durationWidth, height) : CGRectZero;
        self.explicitLabel.frame = explicitWidth ? CGRectMake(explicitX, MAX(0.0, (height - 18.0) / 2.0), explicitWidth, 18.0) : CGRectZero;
        self.downloadIconView.frame = downloaded ? CGRectMake(downloadX + 3.0, MAX(0.0, (height - 20.0) / 2.0), 20.0, 20.0) : CGRectZero;
        self.likeButton.frame = CGRectMake(likeX, MAX(0.0, (height - 40.0) / 2.0), actionWidth, 40.0);
        return;
    }

    BOOL landscape = width > height * 1.45;
    CGFloat artworkSize = landscape ? 48.0 : 54.0;
    BOOL numbered = !self.numberLabel.hidden;
    CGFloat artworkX = numbered ? 31.0 : [waTheme standardMargin] + 2.0;
    CGFloat artworkY = MAX(0.0, (height - artworkSize) / 2.0);
    self.numberLabel.frame = numbered ? CGRectMake(2.0, 0.0, 24.0, height) : CGRectZero;
    self.artworkView.frame = CGRectMake(artworkX, artworkY, artworkSize, artworkSize);

    // Reserve only the actual action column. The text column therefore grows
    // with the cell instead of stopping at an arbitrary fixed width.
    BOOL downloaded = !self.downloadIconView.hidden;
    CGFloat actionColumnWidth = 44.0 + (downloaded ? 26.0 : 0.0);
    CGFloat textX = CGRectGetMaxX(self.artworkView.frame) + 9.0;
    CGFloat textRight = MAX(textX + 32.0, width - actionColumnWidth - 6.0);
    CGFloat textWidth = MAX(32.0, textRight - textX);
    CGFloat durationWidth = self.durationLabel.text.length ? 42.0 : 0.0;
    CGFloat albumRight = MAX(textX + 28.0, textRight - (durationWidth ? durationWidth + 6.0 : 0.0));

    CGFloat likeX = MAX(0.0, width - 44.0 - 8.0);
    CGFloat downloadX = likeX - (downloaded ? 26.0 : 0.0);
    self.likeButton.frame = CGRectMake(likeX, MAX(0.0, (height - 40.0) / 2.0), 44.0, 40.0);
    self.downloadIconView.frame = downloaded ? CGRectMake(downloadX + 3.0, MAX(0.0, (height - 20.0) / 2.0), 20.0, 20.0) : CGRectZero;
    self.titleLabel.frame = CGRectMake(textX, landscape ? 4.0 : 5.0, textWidth, 19.0);
    self.artistLabel.frame = CGRectMake(textX, landscape ? 23.0 : 26.0, textWidth, 16.0);
    self.albumLabel.frame = CGRectMake(textX, landscape ? 41.0 : 45.0, MAX(28.0, albumRight - textX), 16.0);
    if (durationWidth) self.durationLabel.frame = CGRectMake(textRight - durationWidth, landscape ? 41.0 : 45.0, durationWidth, 16.0);
    else self.durationLabel.frame = CGRectZero;

    if (!self.explicitLabel.hidden) {
        CGFloat badgeWidth = 20.0;
        CGFloat gap = 4.0;
        // sizeWithFont runs on every layoutSubviews (every scroll frame);
        // cache the measured width per text + available width.
        if (![self.titleLabel.text isEqualToString:self.measuredTitleText] || fabs(textWidth - self.measuredTitleAvailWidth) > 0.5) {
            self.measuredTitleText = [self.titleLabel.text copy];
            self.measuredTitleAvailWidth = textWidth;
            self.measuredTitleWidth = ceil([self.titleLabel.text sizeWithFont:self.titleLabel.font].width);
        }
        CGFloat titleWidth = MIN(textWidth - badgeWidth - gap, MAX(28.0, self.measuredTitleWidth));
        titleWidth = MAX(28.0, titleWidth);
        self.titleLabel.frame = CGRectMake(textX, landscape ? 4.0 : 5.0, titleWidth, 19.0);
        CGFloat badgeX = MIN(textRight - badgeWidth, CGRectGetMaxX(self.titleLabel.frame) + gap);
        self.explicitLabel.frame = CGRectMake(MAX(textX, badgeX), landscape ? 5.0 : 6.0, badgeWidth, 17.0);
    } else self.explicitLabel.frame = CGRectZero;
}

- (void)likePressed:(id)sender {
    (void)sender;
    if ([self.delegate respondsToSelector:@selector(catalogTrackCellDidPressLike:item:)]) [self.delegate catalogTrackCellDidPressLike:self item:self.trackItem];
}

@end
