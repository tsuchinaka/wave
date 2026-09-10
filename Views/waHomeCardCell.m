#import "waHomeCardCell.h"
#import "../Services/waTheme.h"
#import "../Services/waImageLoader.h"
#import "waPlaceholder.h"
#import <QuartzCore/QuartzCore.h>

@interface waHomeCardCell ()
@property (nonatomic, strong) UIImageView *artworkView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) waMediaItem *item;
@property (nonatomic, copy) NSString *expectedArtworkURL;
@property (nonatomic, copy) NSString *layout;
// Cached title measurement, keyed by text + available width, so
// layoutSubviews never calls sizeWithFont on every scroll frame.
@property (nonatomic, copy) NSString *measuredTitleText;
@property (nonatomic, assign) CGFloat measuredTitleAvailWidth;
@property (nonatomic, assign) CGFloat measuredTitleHeight;
@end

@implementation waHomeCardCell

- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.artworkView = [[UIImageView alloc] initWithFrame:CGRectZero];
        self.artworkView.contentMode = UIViewContentModeScaleAspectFill;
        self.artworkView.clipsToBounds = YES;
        self.artworkView.layer.shouldRasterize = YES;
        self.artworkView.layer.rasterizationScale = [UIScreen mainScreen].scale;
        [self.contentView addSubview:self.artworkView];
        self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.titleLabel.backgroundColor = [UIColor clearColor];
        self.titleLabel.textColor = [UIColor whiteColor];
        self.titleLabel.font = [waTheme mediumFontOfSize:15.5];
        self.titleLabel.numberOfLines = 2;
        self.titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
        [self.contentView addSubview:self.titleLabel];
        self.subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.subtitleLabel.backgroundColor = [UIColor clearColor];
        self.subtitleLabel.textColor = [waTheme secondaryTextColor];
        self.subtitleLabel.font = [waTheme secondaryRegularFontOfSize:13.0];
        self.subtitleLabel.numberOfLines = 3;
        self.subtitleLabel.lineBreakMode = NSLineBreakByWordWrapping;
        [self.contentView addSubview:self.subtitleLabel];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.item = nil;
    self.expectedArtworkURL = nil;
    self.measuredTitleText = nil;
    self.artworkView.image = waPlaceholderImage();
    self.titleLabel.text = nil;
    self.subtitleLabel.text = nil;
}

- (void)configureWithItem:(waMediaItem *)item layout:(NSString *)layout {
    self.item = item;
    self.layout = layout ?: @"square";
    self.titleLabel.text = item.title ?: @"";
    self.subtitleLabel.text = item.subtitle.length ? item.subtitle : (item.artistName ?: @"");
    BOOL circle = [self.layout isEqualToString:@"circle"];
    CGFloat radius = circle ? 70.0 : 7.0;
    if (fabs(self.artworkView.layer.cornerRadius - radius) > 0.5) {
        self.artworkView.layer.cornerRadius = radius;
    }
    self.artworkView.layer.masksToBounds = YES;
    self.artworkView.image = waPlaceholderImage();
    self.expectedArtworkURL = [item.thumbnailURL copy];
    if (self.expectedArtworkURL.length) {
        __weak waHomeCardCell *weakCell = self;
        // Home cards are 160pt wide. The generic thumbnail method defaults to
        // 44pt for list rows, so explicitly request a 320px source here.
        [[waImageLoader sharedLoader] loadThumbnailAtURL:self.expectedArtworkURL targetSize:CGSizeMake(320.0, 320.0) placeholder:waPlaceholderImage() completion:^(UIImage *image) {
            waHomeCardCell *cell = weakCell;
            if (cell && cell.item == item && [cell.expectedArtworkURL isEqualToString:item.thumbnailURL] && image) cell.artworkView.image = image;
        }];
    }
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    BOOL list = [self.layout isEqualToString:@"song-list"];
    BOOL circle = [self.layout isEqualToString:@"circle"];
    CGFloat artworkSize = list ? 64.0 : MIN(self.bounds.size.width, 164.0);
    CGFloat y = list ? 4.0 : 0.0;
    self.artworkView.frame = CGRectMake(0.0, y, artworkSize, artworkSize);
    if (list) {
        self.titleLabel.frame = CGRectMake(76.0, 7.0, self.bounds.size.width - 82.0, 30.0);
        self.subtitleLabel.frame = CGRectMake(76.0, 39.0, self.bounds.size.width - 82.0, 22.0);
    } else {
        CGFloat textWidth = MAX(0.0, self.bounds.size.width);
        CGFloat titleHeight = 0.0;
        if (self.titleLabel.text.length) {
            if (![self.titleLabel.text isEqualToString:self.measuredTitleText] || fabs(textWidth - self.measuredTitleAvailWidth) > 0.5) {
                CGSize titleSize = [self.titleLabel.text sizeWithFont:self.titleLabel.font constrainedToSize:CGSizeMake(textWidth, 38.0) lineBreakMode:NSLineBreakByWordWrapping];
                self.measuredTitleText = [self.titleLabel.text copy];
                self.measuredTitleAvailWidth = textWidth;
                self.measuredTitleHeight = titleSize.height > 0.0 ? MIN(34.0, MAX(18.0, ceil(titleSize.height))) : 0.0;
            }
            titleHeight = self.measuredTitleHeight;
        }
        CGFloat titleTop = artworkSize + (titleHeight > 0.0 ? 5.0 : 0.0);
        CGFloat subtitleTop = titleTop + titleHeight + (titleHeight > 0.0 ? 1.0 : 0.0);
        self.titleLabel.frame = CGRectMake(0.0, titleTop, textWidth, titleHeight);
        self.subtitleLabel.frame = CGRectMake(0.0, subtitleTop, textWidth, MAX(18.0, self.bounds.size.height - subtitleTop));
    }
    if (circle) self.artworkView.layer.cornerRadius = artworkSize / 2.0;
}

@end
