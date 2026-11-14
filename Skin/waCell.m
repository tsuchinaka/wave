#import "waCell.h"
#import "waSkin.h"
#import "waSession.h"

@interface waCell ()
@property (nonatomic, strong) UIImageView *explicitView;
@property (nonatomic, strong) UILabel *downloadedView;
@end

@implementation waCell

+ (waCell *)cellForTable:(UITableView *)table {
    return [self cellForTable:table subtitle:NO];
}

+ (waCell *)cellForTable:(UITableView *)table subtitle:(BOOL)subtitle {
    NSString *identifier = subtitle ? @"waCellSubtitle" : @"waCell";
    waCell *cell = (waCell *)[table dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[waCell alloc] initWithStyle:subtitle ? UITableViewCellStyleSubtitle : UITableViewCellStyleDefault
                             reuseIdentifier:identifier];
    }
    return cell;
}

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = [UIColor whiteColor];
        self.textLabel.backgroundColor = [UIColor clearColor];
        self.detailTextLabel.backgroundColor = [UIColor clearColor];
        [waSkin applyPlainCellFonts:self];

        _artworkView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _artworkView.contentMode = UIViewContentModeScaleAspectFill;
        _artworkView.clipsToBounds = YES;
        _artworkView.opaque = YES;
        _artworkView.backgroundColor = [UIColor colorWithWhite:0.92 alpha:1.0];
        [self.contentView addSubview:_artworkView];

        _explicitView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _explicitView.image = [UIImage imageNamed:@"explicit-glyph-small"];
        _explicitView.hidden = YES;
        [self.contentView addSubview:_explicitView];

        _badgeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _badgeLabel.backgroundColor = [UIColor clearColor];
        _badgeLabel.font = [UIFont systemFontOfSize:13.0];
        _badgeLabel.textColor = [UIColor grayColor];
        _badgeLabel.textAlignment = UITextAlignmentRight;
        [self.contentView addSubview:_badgeLabel];

        _indexLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _indexLabel.backgroundColor = [UIColor clearColor];
        _indexLabel.font = [UIFont boldSystemFontOfSize:15.0];
        _indexLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
        _indexLabel.textAlignment = UITextAlignmentRight;
        _indexLabel.hidden = YES;
        [self.contentView addSubview:_indexLabel];

        _downloadedView = [[UILabel alloc] initWithFrame:CGRectZero];
        _downloadedView.backgroundColor = [UIColor clearColor];
        _downloadedView.font = [UIFont boldSystemFontOfSize:13.0];
        _downloadedView.textColor = [UIColor colorWithRed:0.22 green:0.55 blue:0.28 alpha:1.0];
        _downloadedView.textAlignment = UITextAlignmentCenter;
        _downloadedView.text = @"✓";
        _downloadedView.hidden = YES;
        [self.contentView addSubview:_downloadedView];

        _sectionPosition = 3;
    }
    return self;
}

- (void)setSectionPosition:(NSInteger)position {
    _sectionPosition = position;
}

- (void)setDownloaded:(BOOL)downloaded {
    self.downloadedMark = downloaded;
    self.downloadedView.hidden = !downloaded;
    [self setNeedsLayout];
}

- (void)setIndexText:(NSString *)indexText {
    _indexText = [indexText copy];
    self.indexLabel.text = _indexText;
    self.indexLabel.hidden = (_indexText.length == 0);
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.contentView.bounds);
    CGFloat height = CGRectGetHeight(self.contentView.bounds);
    self.textLabel.lineBreakMode = UILineBreakModeTailTruncation;
    self.detailTextLabel.lineBreakMode = UILineBreakModeTailTruncation;
    self.textLabel.numberOfLines = 1;
    self.detailTextLabel.numberOfLines = 1;

    CGFloat durationW = 0.0;
    if (self.badgeLabel.text.length) {
        durationW = [self.badgeLabel.text sizeWithFont:self.badgeLabel.font].width + 4.0;
        if (durationW < 36.0) durationW = 36.0;
        if (durationW > 52.0) durationW = 52.0;
    }
    CGFloat explicitWidth = self.explicitView.hidden ? 0.0 : 16.0;
    CGFloat markW = self.downloadedMark ? 14.0 : 0.0;
    self.downloadedView.hidden = !self.downloadedMark;
    self.indexLabel.text = self.indexText;
    self.indexLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    self.indexLabel.font = [UIFont boldSystemFontOfSize:15.0];
    self.indexLabel.hidden = (self.indexText.length == 0);
    BOOL showsArt = (self.artworkView.image != nil) || (self.expectedArtworkURL.length > 0);
    if (showsArt) {
        CGFloat side = height - 10.0;
        if (side < 34.0) side = 34.0;
        if (side > 52.0) side = 52.0;
        self.artworkView.hidden = NO;
        self.artworkView.frame = CGRectMake(10.0, (height - side) / 2.0, side, side);
    } else {
        self.artworkView.hidden = YES;
        self.artworkView.frame = CGRectZero;
    }
    CGFloat left = self.artworkView.hidden ? 8.0 : CGRectGetMaxX(self.artworkView.frame) + 8.0;
    if (!self.indexLabel.hidden) {
        CGFloat indexW = 20.0;
        if (self.indexText.length) {
            indexW = [self.indexText sizeWithFont:self.indexLabel.font].width + 6.0;
            if (indexW < 20.0) indexW = 20.0;
            if (indexW > 36.0) indexW = 36.0;
        }
        self.indexLabel.frame = CGRectMake(left, 0.0, indexW, height);
        left = CGRectGetMaxX(self.indexLabel.frame) + 8.0;
    } else {
        self.indexLabel.frame = CGRectZero;
    }
    CGFloat right = 8.0 + durationW + explicitWidth + markW;
    CGFloat textW = width - left - right;
    if (textW < 40.0) textW = 40.0;
    CGRect textFrame = self.textLabel.frame;
    textFrame.origin.x = left;
    textFrame.size.width = textW;
    self.textLabel.frame = textFrame;
    CGRect detailFrame = self.detailTextLabel.frame;
    detailFrame.origin.x = left;
    detailFrame.size.width = textW;
    self.detailTextLabel.frame = detailFrame;
    CGFloat markX = width - durationW - explicitWidth - markW - 4.0;
    self.downloadedView.frame = CGRectMake(markX, 0.0, 14.0, height);
    self.explicitView.frame = CGRectMake(width - durationW - 8.0 - explicitWidth, (height - 12.0) / 2.0, 12.0, 12.0);
    self.badgeLabel.frame = CGRectMake(width - durationW - 6.0, 0.0, durationW, height);
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [[waSession shared] cancelArtworkForOwner:self];
    self.artworkView.image = nil;
    self.expectedArtworkURL = nil;
    self.badgeLabel.text = nil;
    self.indexText = nil;
    self.downloadedMark = NO;
    self.downloadedView.hidden = YES;
    self.explicitView.hidden = YES;
    self.accessoryView = nil;
    self.accessoryType = UITableViewCellAccessoryNone;
    self.textLabel.text = nil;
    self.detailTextLabel.text = nil;
}

- (void)loadArtworkForURL:(NSString *)url size:(CGSize)size {
    if ([self.expectedArtworkURL isEqualToString:url] && self.artworkView.image) return;
    self.expectedArtworkURL = [url copy];
    UIImage *cached = url.length ? [[waSession shared] cachedArtwork:url size:size] : nil;
    if (cached) {
        if (self.artworkView.image != cached) {
            self.artworkView.image = cached;
            [self setNeedsLayout];
        }
        return;
    }
    if (self.artworkView.image) {
        self.artworkView.image = nil;
        [self setNeedsLayout];
    } else if (url.length) {
        [self setNeedsLayout];
    }
    if (!url.length) return;
    __weak waCell *weakSelf = self;
    [[waSession shared] loadArtwork:url size:size owner:self completion:^(UIImage *image) {
        waCell *cell = weakSelf;
        if (!cell || ![cell.expectedArtworkURL isEqualToString:url]) return;
        cell.artworkView.image = image;
        [cell setNeedsLayout];
    }];
}

- (NSString *)subtitleForItem:(waItem *)item {
    if ([item isKindOfClass:[waTrack class]]) {
        waTrack *t = (waTrack *)item;
        return t.artistName.length ? t.artistName : @"";
    }
    if ([item isKindOfClass:[waAlbum class]]) {
        waAlbum *a = (waAlbum *)item;
        return a.artistName.length ? a.artistName : @"";
    }
    if ([item isKindOfClass:[waArtist class]]) {
        waArtist *a = (waArtist *)item;
        if (a.fanCount > 0) return [NSString stringWithFormat:@"%ld fans", (long)a.fanCount];
        return @"Artist";
    }
    if ([item isKindOfClass:[waPlaylist class]]) {
        waPlaylist *p = (waPlaylist *)item;
        if (p.trackCount > 0) return [NSString stringWithFormat:@"%ld songs", (long)p.trackCount];
        if (p.creatorName.length) return p.creatorName;
        return @"Playlist";
    }
    return item.subtitle.length ? item.subtitle : @"";
}

- (void)setItem:(waItem *)item {
    self.textLabel.text = item.title.length ? item.title : @"";
    self.detailTextLabel.text = [self subtitleForItem:item];
    self.explicitView.hidden = !item.explicitLyrics;
    self.badgeLabel.text = nil;
    [self loadArtworkForURL:[item artworkURLForSide:52.0] size:CGSizeMake(52.0, 52.0)];
}

- (void)setTrack:(waTrack *)track showAlbum:(BOOL)showAlbum {
    [self setTrack:track showAlbum:showAlbum showsArtwork:YES];
}

- (void)setTrack:(waTrack *)track showAlbum:(BOOL)showAlbum showsArtwork:(BOOL)showsArtwork {
    self.textLabel.text = track.title.length ? track.title : @"";
    if (showAlbum && track.albumTitle.length) {
        self.detailTextLabel.text = track.artistName.length
            ? [NSString stringWithFormat:@"%@ · %@", track.artistName, track.albumTitle]
            : track.albumTitle;
    } else {
        self.detailTextLabel.text = track.artistName.length ? track.artistName : @"";
    }
    self.explicitView.hidden = !track.explicitLyrics;
    self.badgeLabel.text = nil;
    NSString *local = [[waSession shared] localArtworkPathForTrack:track];
    NSString *art = local.length ? local : [track artworkURLForSide:52.0];
    self.expectedArtworkURL = showsArtwork ? art : nil;
    if (showsArtwork) {
        [self loadArtworkForURL:art size:CGSizeMake(52.0, 52.0)];
    } else {
        self.artworkView.image = nil;
    }
}

@end

@implementation waSectionHeader

- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.backgroundColor = [UIColor clearColor];
        _titleLabel.font = [UIFont boldSystemFontOfSize:17.0];
        _titleLabel.textColor = [UIColor colorWithWhite:0.25 alpha:1.0];
        _titleLabel.shadowColor = [UIColor colorWithWhite:1.0 alpha:0.8];
        _titleLabel.shadowOffset = CGSizeMake(0.0, 1.0);
        [self addSubview:_titleLabel];
        _actionButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _actionButton.titleLabel.font = [UIFont boldSystemFontOfSize:12.0];
        [_actionButton setTitleColor:[UIColor colorWithRed:0.0 green:0.32 blue:0.60 alpha:1.0] forState:UIControlStateNormal];
        [self addSubview:_actionButton];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = CGRectGetWidth(self.bounds);
    CGFloat h = CGRectGetHeight(self.bounds);
    self.titleLabel.frame = CGRectMake(19.0, 2.0, w - 120.0, h - 4.0);
    self.actionButton.frame = CGRectMake(w - 95.0, 2.0, 80.0, h - 4.0);
}

@end

@implementation waEmptyState

- (id)initWithTitle:(NSString *)title message:(NSString *)message {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.backgroundColor = [UIColor clearColor];
        _title = [title copy];
        _message = [message copy];

        UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        titleLabel.tag = 101;
        titleLabel.backgroundColor = [UIColor clearColor];
        titleLabel.font = [UIFont boldSystemFontOfSize:17.0];
        titleLabel.textColor = [UIColor grayColor];
        titleLabel.textAlignment = UITextAlignmentCenter;
        titleLabel.text = _title;
        [self addSubview:titleLabel];

        UILabel *messageLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        messageLabel.tag = 102;
        messageLabel.backgroundColor = [UIColor clearColor];
        messageLabel.font = [UIFont systemFontOfSize:13.0];
        messageLabel.textColor = [UIColor grayColor];
        messageLabel.textAlignment = UITextAlignmentCenter;
        messageLabel.numberOfLines = 0;
        messageLabel.lineBreakMode = UILineBreakModeWordWrap;
        messageLabel.text = _message;
        [self addSubview:messageLabel];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = CGRectGetWidth(self.bounds);
    UILabel *titleLabel = (UILabel *)[self viewWithTag:101];
    UILabel *messageLabel = (UILabel *)[self viewWithTag:102];
    titleLabel.frame = CGRectMake(20.0, 60.0, w - 40.0, 24.0);
    messageLabel.frame = CGRectMake(20.0, 88.0, w - 40.0, 60.0);
}

@end
