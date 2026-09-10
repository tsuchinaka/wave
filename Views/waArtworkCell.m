#import "waArtworkCell.h"
#import "../Services/waTheme.h"
#import "../Services/waAPIClient.h"
#import "waMediaActionSheet.h"
#import <QuartzCore/QuartzCore.h>

static UITableView *waTableForCell(UIView *view) {
    UIView *ancestor = view.superview;
    while (ancestor) {
        if ([ancestor isKindOfClass:[UITableView class]]) return (UITableView *)ancestor;
        ancestor = ancestor.superview;
    }
    return nil;
}

static void waApplyCellCorners(UIView *view, waCellCornerStyle style) {
    (void)style;
    view.layer.mask = nil;
    view.layer.cornerRadius = 0.0;
}

@interface waArtworkCell ()
@property (nonatomic, strong) UILabel *downloadStateLabel;
@property (nonatomic, strong) UILabel *chevronLabel;
@property (nonatomic, strong) UIImageView *downloadIconView;
@property (nonatomic, strong) UIProgressView *downloadProgressView;
@property (nonatomic, strong) UIImageView *explicitIconView;
@property (nonatomic, strong) UILabel *explicitIconLabel; // legacy fallback if image missing
@property (nonatomic, strong) UIImageView *geniusIconView;
@property (nonatomic, assign) BOOL usesValue1Layout;
@property (nonatomic, strong) waMediaItem *likeItem;
@property (nonatomic, strong) UIButton *likeButton;
// Cached per-theme values so layoutSubviews (which runs every scroll frame)
// does not hit NSUserDefaults or rebuild tinted icons on every pass.
@property (nonatomic, copy) NSString *cachedThemeName;
@property (nonatomic, strong) UIColor *cachedSurfaceColor;
@property (nonatomic, strong) UIColor *cachedSelectedColor;
@property (nonatomic, strong) UIColor *cachedBarColor;
@property (nonatomic, strong) UIColor *cachedPrimaryTextColor;
@property (nonatomic, strong) UIColor *cachedSecondaryTextColor;
@property (nonatomic, strong) UIImage *cachedHeartNormal;
@property (nonatomic, strong) UIImage *cachedHeartSelected;
@property (nonatomic, strong) UIImage *cachedDownloadIcon;
@property (nonatomic, strong) UIImage *cachedGeniusIcon;
@property (nonatomic, strong) UIFont *cachedTitleFont;
@property (nonatomic, strong) UIFont *cachedDetailFont;
// Corner style resolved from the table is cached per configuration cycle so
// layoutSubviews (every scroll frame) skips the superview walk + table
// lookup. Set whenever the cell is reconfigured; cleared after resolving.
@property (nonatomic, assign) BOOL cornersDirty;
@end

@implementation waArtworkCell

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleGray;
        self.usesValue1Layout = style == UITableViewCellStyleValue1;
        self.cardStyle = YES;
        self.circleArtwork = NO;
        self.multilineDetail = NO;
        self.cornerStyle = waCellCornerStyleAll;
        self.cornersDirty = YES;
        [waTheme applyPrimaryTextStyleToLabel:self.textLabel];
        [waTheme applySecondaryTextStyleToLabel:self.detailTextLabel];
        // Static artwork layer setup once: layoutSubviews runs every scroll
        // frame, and redundant layer commits cost compositing on legacy GPUs.
        // Only cornerRadius stays in layout (depends on circleArtwork/theme).
        self.imageView.contentMode = UIViewContentModeScaleAspectFill;
        self.imageView.clipsToBounds = YES;
        self.imageView.layer.borderColor = [UIColor colorWithWhite:0.0 alpha:0.22].CGColor;
        self.imageView.layer.borderWidth = 1.0;
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.cornersDirty = YES;
    self.explicitIconLabel.hidden = YES;
    self.geniusIconView.hidden = YES;
    self.reserveAccessorySpace = NO;
    self.multilineDetail = NO;
    self.artworkIdentifier = nil;
    self.imageView.image = nil;
    self.accessoryView = nil;
    [self setLikeItem:nil];
}

- (void)refreshThemeCacheIfNeeded {
    // renderCacheKeyForColor(barColor) fingerprints the active theme using
    // only the public waTheme API.
    NSString *themeName = [waTheme renderCacheKeyForColor:[waTheme barColor]];
    if ([themeName isEqualToString:self.cachedThemeName]) return;
    self.cachedThemeName = themeName;
    self.cachedSurfaceColor = [waTheme surfaceColor];
    self.cachedSelectedColor = [waTheme selectedSurfaceColor];
    self.cachedBarColor = [waTheme barColor];
    self.cachedPrimaryTextColor = [waTheme primaryTextColor];
    self.cachedSecondaryTextColor = [waTheme secondaryTextColor];
    self.cachedTitleFont = [waTheme mediumFontOfSize:17.0];
    self.cachedDetailFont = [waTheme secondaryRegularFontOfSize:13.0];
    UIImage *heart = [UIImage imageNamed:@"wave-love"];
    self.cachedHeartNormal = [waTheme tintedIcon:heart withColor:self.cachedBarColor];
    self.cachedHeartSelected = [waTheme tintedIcon:heart withColor:[waTheme likeSelectedColor]];
    self.cachedDownloadIcon = [waTheme tintedIcon:[UIImage imageNamed:@"wave-downloaded"] withColor:self.cachedBarColor];
    self.cachedGeniusIcon = [waTheme tintedIcon:[UIImage imageNamed:@"WaveGenius"] withColor:self.cachedBarColor];
    if (self.downloadIconView) self.downloadIconView.image = self.cachedDownloadIcon;
    if (self.geniusIconView) self.geniusIconView.image = self.cachedGeniusIcon;
    if (self.likeButton) {
        [self.likeButton setImage:self.cachedHeartNormal forState:UIControlStateNormal];
        [self.likeButton setImage:self.cachedHeartSelected forState:UIControlStateSelected];
    }
    if (self.downloadStateLabel) self.downloadStateLabel.textColor = self.cachedBarColor;
    if (self.explicitIconLabel) self.explicitIconLabel.textColor = self.cachedSecondaryTextColor;
    if (self.explicitIconView) {
        UIImage *base = [UIImage imageNamed:@"explicit-glyph-medium"];
        self.explicitIconView.image = [waTheme tintedIcon:base withColor:self.cachedSecondaryTextColor];
    }
    if (self.chevronLabel) self.chevronLabel.textColor = self.cachedBarColor;
}

- (void)setLikeItem:(waMediaItem *)item {
    _likeItem = (item.type == waMediaItemTypeSong || item.type == waMediaItemTypeAlbum || item.type == waMediaItemTypeArtist || item.type == waMediaItemTypePlaylist) ? item : nil;
    if (!self.likeButton) {
        self.likeButton = [UIButton buttonWithType:UIButtonTypeCustom];
        self.likeButton.frame = CGRectMake(0.0, 0.0, 30.0, 34.0);
        self.likeButton.adjustsImageWhenHighlighted = YES;
        self.likeButton.backgroundColor = [UIColor clearColor];
        [self.likeButton addTarget:self action:@selector(likePressed:) forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:self.likeButton];
    }
    self.likeButton.hidden = !self.likeItem;
    self.likeButton.selected = self.likeItem.isLiked;
    self.likeButton.accessibilityLabel = self.likeItem ? (self.likeItem.isLiked ? @"Unlike" : @"Like") : nil;
    [self refreshThemeCacheIfNeeded];
    [self.likeButton setImage:self.cachedHeartNormal forState:UIControlStateNormal];
    [self.likeButton setImage:self.cachedHeartSelected forState:UIControlStateSelected];
    self.cornersDirty = YES;
    [self setNeedsLayout];
}

- (void)refreshLikeState {
    // In-place heart refresh for like notifications: callers update the model
    // and refresh only visible cells instead of reloading the whole table.
    if (!self.likeButton) return;
    self.likeButton.selected = self.likeItem.isLiked;
    self.likeButton.accessibilityLabel = self.likeItem ? (self.likeItem.isLiked ? @"Unlike" : @"Like") : nil;
}

- (void)likePressed:(UIButton *)button {
    waMediaItem *item = self.likeItem;
    if (!item) return;
    if (![[waAPIClient sharedClient] isAuthenticated]) {
        [[[UIAlertView alloc] initWithTitle:@"Like" message:@"Sign in to save this item." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
        return;
    }
    BOOL liked = !item.isLiked;
    item.liked = liked;
    button.selected = liked;
    button.enabled = NO;
    NSString *kind = item.type == waMediaItemTypeAlbum ? @"album" : (item.type == waMediaItemTypeArtist ? @"artist" : (item.type == waMediaItemTypePlaylist ? @"playlist" : @"song"));
    button.accessibilityLabel = liked ? [NSString stringWithFormat:@"Unlike %@", kind] : [NSString stringWithFormat:@"Like %@", kind];
    void (^completion)(BOOL, NSError *) = ^(BOOL success, NSError *error) {
        button.enabled = YES;
        if (!success) {
            item.liked = !liked;
            button.selected = item.isLiked;
            button.accessibilityLabel = item.isLiked ? [NSString stringWithFormat:@"Unlike %@", kind] : [NSString stringWithFormat:@"Like %@", kind];
            [[[UIAlertView alloc] initWithTitle:@"Like" message:error.localizedDescription ?: @"Unable to update like." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
            return;
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:waMediaLikeDidChangeNotification object:item userInfo:@{waMediaLikeIdentifierKey: item.identifier ?: @"", waMediaLikeTypeKey: @(item.type)}];
    };
    if (self.likeItem.type == waMediaItemTypeAlbum) [[waAPIClient sharedClient] setLiked:liked album:self.likeItem completion:completion];
    else if (self.likeItem.type == waMediaItemTypeArtist) [[waAPIClient sharedClient] setLiked:liked artist:self.likeItem completion:completion];
    else if (self.likeItem.type == waMediaItemTypePlaylist) [[waAPIClient sharedClient] setLiked:liked playlist:self.likeItem completion:completion];
    else [[waAPIClient sharedClient] setLiked:liked song:self.likeItem completion:completion];
}

- (void)setExplicit:(BOOL)explicit {
    if (!self.explicitIconView) {
        UIImage *base = [UIImage imageNamed:@"explicit-glyph-medium"];
        if (!base) base = [UIImage imageNamed:@"explicit-glyph-small"];
        UIImage *tinted = base ? [waTheme tintedIcon:base withColor:[waTheme secondaryTextColor]] : nil;
        if (tinted) {
            self.explicitIconView = [[UIImageView alloc] initWithImage:tinted];
            self.explicitIconView.contentMode = UIViewContentModeScaleAspectFit;
            self.explicitIconView.backgroundColor = [UIColor clearColor];
            self.explicitIconView.accessibilityLabel = @"Explicit content";
            [self.contentView addSubview:self.explicitIconView];
        } else {
            // Fallback to Deezer font if image missing
            self.explicitIconLabel = [[UILabel alloc] initWithFrame:CGRectZero];
            self.explicitIconLabel.text = @"z";
            self.explicitIconLabel.font = [UIFont fontWithName:@"Deezer-Font-Icon" size:14.0] ?: [waTheme boldFontOfSize:11.0];
            self.explicitIconLabel.textColor = [waTheme secondaryTextColor];
            self.explicitIconLabel.textAlignment = NSTextAlignmentCenter;
            self.explicitIconLabel.backgroundColor = [UIColor clearColor];
            self.explicitIconLabel.accessibilityLabel = @"Explicit content";
            [self.contentView addSubview:self.explicitIconLabel];
        }
    }
    if (self.explicitIconView) {
        self.explicitIconView.hidden = !explicit;
        if (!explicit) {} else {
            UIImage *base = [UIImage imageNamed:@"explicit-glyph-medium"];
            self.explicitIconView.image = [waTheme tintedIcon:base withColor:[waTheme secondaryTextColor]];
        }
        if (self.explicitIconLabel) self.explicitIconLabel.hidden = YES;
    } else if (self.explicitIconLabel) {
        self.explicitIconLabel.hidden = !explicit;
    }
    self.cornersDirty = YES;
    [self setNeedsLayout];
}

- (void)setDownloadState:(waDownloadState)state progress:(float)progress {
    if (!self.downloadStateLabel) {
        self.downloadStateLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.downloadStateLabel.font = [waTheme boldFontOfSize:10.0];
        self.downloadStateLabel.textAlignment = NSTextAlignmentRight;
        self.downloadStateLabel.textColor = [waTheme barColor];
        self.downloadStateLabel.backgroundColor = [UIColor clearColor];
        [self.contentView addSubview:self.downloadStateLabel];
        self.downloadProgressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        [self.contentView addSubview:self.downloadProgressView];
        self.downloadIconView = [[UIImageView alloc] initWithImage:nil];
        self.downloadIconView.contentMode = UIViewContentModeScaleAspectFit;
        self.downloadIconView.hidden = YES;
        [self.contentView addSubview:self.downloadIconView];
    }
    // The tinted image follows theme changes via refreshThemeCacheIfNeeded.
    [self refreshThemeCacheIfNeeded];
    self.downloadIconView.image = self.cachedDownloadIcon;
    self.downloadIconView.hidden = state != waDownloadStateCompleted;
    self.downloadStateLabel.hidden = YES;
    self.downloadProgressView.hidden = YES;
    self.downloadStateLabel.text = nil;
    self.cornersDirty = YES;
    [self setNeedsLayout];
}

- (void)setGeniusRecommended:(BOOL)recommended {
    [self refreshThemeCacheIfNeeded];
    if (!self.geniusIconView) {
        self.geniusIconView = [[UIImageView alloc] initWithImage:self.cachedGeniusIcon];
        self.geniusIconView.contentMode = UIViewContentModeScaleAspectFit;
        self.geniusIconView.accessibilityLabel = @"Genius recommendation";
        [self.contentView addSubview:self.geniusIconView];
    }
    self.geniusIconView.image = self.cachedGeniusIcon;
    self.geniusIconView.hidden = !recommended;
    self.cornersDirty = YES;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self refreshThemeCacheIfNeeded];

    self.contentView.backgroundColor = [UIColor clearColor];
    if (self.cardStyle) {
        // Resolve the corner style at most once per configuration cycle.
        // Every scroll frame re-enters layoutSubviews, so reuse the cached
        // value unless the cell was reconfigured since the last resolve.
        if (self.cornersDirty) {
            UITableView *tableView = waTableForCell(self);
            NSIndexPath *indexPath = tableView ? [tableView indexPathForCell:self] : nil;
            if (indexPath) {
                NSInteger count = [tableView numberOfRowsInSection:indexPath.section];
                self.cornerStyle = count == 1 ? waCellCornerStyleAll : (indexPath.row == 0 ? waCellCornerStyleTop : (indexPath.row == count - 1 ? waCellCornerStyleBottom : waCellCornerStyleNone));
            }
            self.cornersDirty = NO;
        }
        CGFloat extension = MAX(0.0, self.frame.origin.x);
        self.backgroundView.frame = CGRectMake(-extension, 0.0, self.bounds.size.width + extension * 2.0, self.bounds.size.height);
        self.backgroundView.backgroundColor = self.cachedSurfaceColor;
        waApplyCellCorners(self.backgroundView, self.cornerStyle);
        self.selectedBackgroundView.frame = self.backgroundView.frame;
        self.selectedBackgroundView.backgroundColor = self.cachedSelectedColor;
        waApplyCellCorners(self.selectedBackgroundView, self.cornerStyle);
    } else {
        // Flat full-width rows (Queue): no table lookup, no per-frame theme
        // reads. Background is styled once at creation in cellForRow; only
        // keep an explicit backgroundView (other screens) full-bleed.
        if (self.backgroundView) self.backgroundView.frame = self.bounds;
        if (self.selectedBackgroundView) self.selectedBackgroundView.frame = self.bounds;
    }

    // UIKit can restore the default fonts for Value1 cells after the cell is
    // initialized. Reapply the Deezer weights here so album track rows keep
    // the same typography as subtitle rows.
    self.textLabel.font = self.cachedTitleFont;
    self.detailTextLabel.font = self.cachedDetailFont;
    if (!self.textLabel.textColor || [self.textLabel.textColor isEqual:[UIColor blackColor]]) self.textLabel.textColor = self.cachedPrimaryTextColor;
    if (!self.detailTextLabel.textColor || [self.detailTextLabel.textColor isEqual:[UIColor blackColor]]) self.detailTextLabel.textColor = self.cachedSecondaryTextColor;
    if (self.accessoryType == UITableViewCellAccessoryDisclosureIndicator && !self.accessoryView) {
        // prepareForReuse detaches the accessoryView on every recycle; rebuild
        // the label once per cell instead of on every pass.
        if (!self.chevronLabel) {
            UILabel *chevron = [[UILabel alloc] initWithFrame:CGRectMake(0.0, 0.0, 18.0, 32.0)];
            chevron.text = @"›";
            chevron.font = [UIFont systemFontOfSize:28.0];
            chevron.textAlignment = NSTextAlignmentCenter;
            chevron.textColor = self.cachedBarColor;
            chevron.backgroundColor = [UIColor clearColor];
            self.chevronLabel = chevron;
        }
        self.accessoryView = self.chevronLabel;
    }

    UIImageView *artworkView = self.imageView;
    BOOL hasArtwork = artworkView.image != nil;
    CGFloat size = [waTheme standardArtworkSize];
    CGFloat left = [waTheme standardMargin];
    CGFloat top = MAX(0.0, (self.contentView.bounds.size.height - size) / 2.0);
    artworkView.hidden = !hasArtwork;
    artworkView.frame = hasArtwork ? CGRectMake(left, top, size, size) : CGRectZero;
    CGFloat wantRadius = self.circleArtwork ? size / 2.0 : [waTheme cornerRadius];
    if (artworkView.layer.cornerRadius != wantRadius) artworkView.layer.cornerRadius = wantRadius;
    // Keep the original cell geometry, but do not rasterize the image view.
    // Rasterization can make downloaded artwork look softer on Retina devices.

    CGFloat textLeft = hasArtwork ? left + size + 10.0 : [waTheme standardMargin] + 7.0;
    BOOL hasDownloadIcon = self.downloadIconView && !self.downloadIconView.hidden;
    BOOL hasDownloadState = self.downloadStateLabel && !self.downloadStateLabel.hidden;
    BOOL hasLike = self.likeButton && !self.likeButton.hidden;
    CGFloat stateWidth = hasDownloadIcon ? 32.0 : (hasDownloadState ? 72.0 : 0.0);
    BOOL hasGeniusIcon = self.geniusIconView && !self.geniusIconView.hidden;
    CGFloat geniusWidth = hasGeniusIcon ? 28.0 : 0.0;
    BOOL hasExplicitIcon = (self.explicitIconView && !self.explicitIconView.hidden) || (self.explicitIconLabel && !self.explicitIconLabel.hidden);
    CGFloat rightInset = (self.accessoryType == UITableViewCellAccessoryNone && !self.reserveAccessorySpace) ? [waTheme standardMargin] : 32.0;
    if (hasLike) rightInset += 32.0;
    CGFloat contentWidth = CGRectGetWidth(self.contentView.bounds);
    // Detect Value1 (title + detail on same line) vs Subtitle (detail below title)
    BOOL isValue1 = self.usesValue1Layout;
    if (isValue1) {
        CGFloat detailWidth = 64.0;
        CGFloat gap = 8.0;
        CGFloat titleWidth = MAX(0.0, contentWidth - textLeft - detailWidth - stateWidth - geniusWidth - rightInset - gap - (hasExplicitIcon ? 22.0 : 0.0));
        CGRect titleFrame = self.textLabel.frame;
        titleFrame.origin.x = textLeft;
        titleFrame.origin.y = 7.0;
        titleFrame.size.width = titleWidth;
        titleFrame.size.height = MAX(28.0, CGRectGetHeight(self.contentView.bounds) - 14.0);
        self.textLabel.frame = titleFrame;
        self.textLabel.numberOfLines = 1;
        self.textLabel.adjustsFontSizeToFitWidth = NO;
        self.textLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        CGRect detailFrame = self.detailTextLabel.frame;
        detailFrame.origin.x = contentWidth - detailWidth - stateWidth - geniusWidth - rightInset;
        detailFrame.origin.y = 7.0;
        detailFrame.size.width = detailWidth;
        detailFrame.size.height = MAX(28.0, CGRectGetHeight(self.contentView.bounds) - 14.0);
        self.detailTextLabel.frame = detailFrame;
        self.detailTextLabel.numberOfLines = 1;
        self.detailTextLabel.adjustsFontSizeToFitWidth = NO;
        self.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        self.detailTextLabel.textAlignment = NSTextAlignmentRight;
    } else {
        CGFloat textWidth = MAX(0.0, contentWidth - textLeft - rightInset - stateWidth - geniusWidth - (hasExplicitIcon ? 22.0 : 0.0));
        BOOL singleLine = self.detailTextLabel.text.length == 0;
        CGRect titleFrame = self.textLabel.frame;
        titleFrame.origin.x = textLeft;
        titleFrame.origin.y = self.multilineDetail ? 4.0 : (singleLine ? MAX(0.0, (CGRectGetHeight(self.contentView.bounds) - 28.0) / 2.0) : 5.0);
        titleFrame.size.width = textWidth;
        titleFrame.size.height = self.multilineDetail ? 20.0 : (singleLine ? 28.0 : 24.0);
        self.textLabel.frame = titleFrame;
        self.textLabel.numberOfLines = 1;
        self.textLabel.adjustsFontSizeToFitWidth = NO;
        self.textLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        CGRect detailFrame = self.detailTextLabel.frame;
        detailFrame.origin.x = textLeft;
        detailFrame.origin.y = self.multilineDetail ? 24.0 : (singleLine ? 0.0 : 28.0);
        detailFrame.size.width = textWidth;
        detailFrame.size.height = self.multilineDetail ? MAX(32.0, CGRectGetHeight(self.contentView.bounds) - 27.0) : (singleLine ? 0.0 : 20.0);
        self.detailTextLabel.frame = detailFrame;
        self.detailTextLabel.numberOfLines = self.multilineDetail ? 2 : 1;
        self.detailTextLabel.adjustsFontSizeToFitWidth = NO;
        self.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        self.detailTextLabel.textAlignment = NSTextAlignmentLeft;
    }
    self.textLabel.adjustsFontSizeToFitWidth = NO;
    self.textLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.detailTextLabel.adjustsFontSizeToFitWidth = NO;
    self.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    CGFloat actionRight = contentWidth - [waTheme standardMargin];
    if (hasLike) {
        self.likeButton.frame = CGRectMake(actionRight - 30.0, (CGRectGetHeight(self.contentView.bounds) - 34.0) / 2.0, 30.0, 34.0);
        actionRight -= 34.0;
    } else self.likeButton.frame = CGRectZero;
    CGFloat iconHeight = 16.0;
    self.downloadIconView.frame = CGRectMake(actionRight - 24.0, (CGRectGetHeight(self.contentView.bounds) - iconHeight) / 2.0, 24.0, iconHeight);
    if (hasDownloadIcon) actionRight -= 30.0;
    self.geniusIconView.frame = CGRectMake(actionRight - 24.0, (CGRectGetHeight(self.contentView.bounds) - iconHeight) / 2.0, 24.0, iconHeight);
    if (hasGeniusIcon) actionRight -= 30.0;
    self.downloadStateLabel.frame = CGRectMake(actionRight - 70.0, 7.0, 70.0, 16.0);
    self.downloadProgressView.frame = CGRectMake(textLeft, CGRectGetHeight(self.contentView.bounds) - 5.0, MAX(20.0, contentWidth - textLeft - rightInset), 2.0);
    CGFloat explicitX = contentWidth - rightInset - (hasDownloadIcon ? 42.0 : 20.0) - geniusWidth;
    // Value1 album rows reserve the right side for duration. Put the marker
    // immediately before that duration instead of underneath its label.
    if (isValue1) explicitX = contentWidth - 64.0 - stateWidth - geniusWidth - rightInset - 22.0;
    if (self.explicitIconView) {
        self.explicitIconView.frame = CGRectMake(explicitX, (CGRectGetHeight(self.contentView.bounds) - 14.0) / 2.0, 20.0, 14.0);
    }
    self.explicitIconLabel.frame = CGRectMake(explicitX, (CGRectGetHeight(self.contentView.bounds) - 20.0) / 2.0, 20.0, 20.0);
}

@end
