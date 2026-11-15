#import "waStorageController.h"
#import "../Core/waImageCache.h"
#import "waRootController.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>

// HTTPSource keeps the cache files a decoder or the cast server is reading.
// Removing one of those mid-playback kills the stream, so the screen skips them.
extern NSArray *waActiveStreamCachePathList(void);

enum {
    waStorageAlertArtwork = 1,
    waStorageAlertStreams = 2,
    waStorageAlertAll = 3
};

static NSString *waByteString(unsigned long long bytes) {
    if (bytes < 1024ULL) return [NSString stringWithFormat:@"%llu B", bytes];
    double value = (double)bytes / 1024.0;
    const char *units[] = {"KB", "MB", "GB"};
    for (int unit = 0; unit < 3; unit++) {
        if (value < 1024.0 || unit == 2) {
            double rounded = (double)((unsigned long long)(value + 0.5));
            if (fabs(value - rounded) < 0.05) return [NSString stringWithFormat:@"%.0f %s", rounded, units[unit]];
            return [NSString stringWithFormat:@"%.1f %s", value, units[unit]];
        }
        value /= 1024.0;
    }
    return [NSString stringWithFormat:@"%llu B", bytes];
}

static NSString *waPercentString(double fraction) {
    if (fraction < 0.0) fraction = 0.0;
    if (fraction > 1.0) fraction = 1.0;
    double percent = fraction * 100.0;
    if (fraction > 0.0 && percent < 1.0) return @"<1%";
    return [NSString stringWithFormat:@"%.0f%%", percent];
}

static NSString *waCachesPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    return paths.count ? [paths objectAtIndex:0] : nil;
}

static NSString *waDocumentsPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths.count ? [paths objectAtIndex:0] : nil;
}

static NSString *waArtworkDirectory(void) {
    return [waCachesPath() stringByAppendingPathComponent:@"Artwork"];
}

static NSString *waStreamDirectory(void) {
    return [waCachesPath() stringByAppendingPathComponent:@"StreamCache"];
}

static NSString *waDownloadsDirectory(void) {
    return [waDocumentsPath() stringByAppendingPathComponent:@"WaveDownloads"];
}

static unsigned long long waFolderSize(NSString *path) {
    NSFileManager *manager = [NSFileManager defaultManager];
    BOOL directory = NO;
    if (![manager fileExistsAtPath:path isDirectory:&directory] || !directory) return 0;
    unsigned long long total = 0;
    NSDirectoryEnumerator *enumerator = [manager enumeratorAtPath:path];
    for (NSString *item in enumerator) {
        NSDictionary *attributes = [manager attributesOfItemAtPath:[path stringByAppendingPathComponent:item] error:NULL];
        if ([[attributes fileType] isEqualToString:NSFileTypeRegular]) total += [attributes fileSize];
    }
    return total;
}

// Returns the bytes removed. Files named in keep (a decoder is reading them)
// stay, and so do their bytes.
static unsigned long long waEmptyFolder(NSString *path, NSSet *keep) {
    NSFileManager *manager = [NSFileManager defaultManager];
    BOOL directory = NO;
    if (![manager fileExistsAtPath:path isDirectory:&directory] || !directory) return 0;
    NSMutableArray *targets = [NSMutableArray array];
    NSMutableArray *sizes = [NSMutableArray array];
    NSDirectoryEnumerator *enumerator = [manager enumeratorAtPath:path];
    for (NSString *item in enumerator) {
        NSString *full = [path stringByAppendingPathComponent:item];
        if (keep && [keep containsObject:full]) continue;
        NSDictionary *attributes = [manager attributesOfItemAtPath:full error:NULL];
        if (![[attributes fileType] isEqualToString:NSFileTypeRegular]) continue;
        [targets addObject:full];
        [sizes addObject:[attributes objectForKey:NSFileSize] ?: @0];
    }
    unsigned long long removed = 0;
    for (NSUInteger index = 0; index < targets.count; index++) {
        NSString *full = [targets objectAtIndex:index];
        unsigned long long size = [[sizes objectAtIndex:index] unsignedLongLongValue];
        if ([manager removeItemAtPath:full error:NULL]) removed += size;
    }
    return removed;
}

// Same budget HTTPSource and waImageCache share: 3/4 streams, 1/4 artwork.
static unsigned long long waCacheBudget(void) {
    NSInteger configured = [[NSUserDefaults standardUserDefaults] integerForKey:@"wave.cacheSizeMB"];
    if (configured <= 0) configured = 512;
    if (configured > 1024) configured = 1024;
    return (unsigned long long)configured * 1024ULL * 1024ULL;
}

static UIColor *waArtworkColor(void) { return [UIColor colorWithRed:0.24 green:0.44 blue:0.67 alpha:1.0]; }
static UIColor *waStreamColor(void) { return [UIColor colorWithRed:0.18 green:0.58 blue:0.53 alpha:1.0]; }
static UIColor *waDeviceColor(void) { return [UIColor colorWithRed:0.34 green:0.45 blue:0.60 alpha:1.0]; }

#pragma mark - capacity bar

// A stock-looking capsule filled by one or more proportional segments.
@interface waStorageBar : UIView
@property (nonatomic, strong) NSArray *segments; // NSDictionary {color, bytes}
@property (nonatomic, assign) unsigned long long capacity;
@end

@implementation waStorageBar

- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithWhite:0.86 alpha:1.0];
        self.clipsToBounds = YES;
        self.layer.cornerRadius = 3.0;
        _segments = [NSArray array];
    }
    return self;
}

- (void)setSegments:(NSArray *)segments {
    _segments = [segments copy];
    [self setNeedsLayout];
}

- (void)setCapacity:(unsigned long long)capacity {
    _capacity = capacity;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    for (UIView *view in [self.subviews copy]) [view removeFromSuperview];
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    if (width < 1.0 || height < 1.0) return;
    unsigned long long capacity = self.capacity ? self.capacity : 1ULL;
    CGFloat x = 0.0;
    for (NSDictionary *segment in self.segments) {
        unsigned long long bytes = [[segment objectForKey:@"bytes"] unsignedLongLongValue];
        if (!bytes) continue;
        CGFloat share = (CGFloat)((double)bytes / (double)capacity);
        if (share > 1.0) share = 1.0;
        CGFloat span = share * width;
        if (span < 2.0) span = 2.0;
        if (x + span > width) span = width - x;
        if (span <= 0.0) break;
        UIView *fill = [[UIView alloc] initWithFrame:CGRectMake(x, 0.0, span, height)];
        fill.backgroundColor = [segment objectForKey:@"color"];
        [self addSubview:fill];
        x += span;
    }
}

@end

#pragma mark - cells

@interface waStorageMeterCell : UITableViewCell
@property (nonatomic, strong) UILabel *meterTitleLabel;
@property (nonatomic, strong) UILabel *meterValueLabel;
@property (nonatomic, strong) UILabel *captionLabel;
@property (nonatomic, strong) waStorageBar *bar;
@end

@implementation waStorageMeterCell

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _meterTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _meterTitleLabel.backgroundColor = [UIColor clearColor];
        _meterTitleLabel.font = [UIFont boldSystemFontOfSize:15.0];
        _meterTitleLabel.textColor = [UIColor blackColor];
        [self.contentView addSubview:_meterTitleLabel];
        _meterValueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _meterValueLabel.backgroundColor = [UIColor clearColor];
        _meterValueLabel.font = [UIFont boldSystemFontOfSize:15.0];
        _meterValueLabel.textColor = [UIColor blackColor];
        _meterValueLabel.textAlignment = UITextAlignmentRight;
        [self.contentView addSubview:_meterValueLabel];
        _bar = [[waStorageBar alloc] initWithFrame:CGRectZero];
        [self.contentView addSubview:_bar];
        _captionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _captionLabel.backgroundColor = [UIColor clearColor];
        _captionLabel.font = [UIFont systemFontOfSize:12.0];
        _captionLabel.textColor = [UIColor grayColor];
        [self.contentView addSubview:_captionLabel];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.contentView.bounds);
    CGFloat valueWidth = 0.0;
    if (self.meterValueLabel.text.length) valueWidth = [self.meterValueLabel.text sizeWithFont:self.meterValueLabel.font].width + 2.0;
    if (valueWidth < 8.0) valueWidth = 8.0;
    if (valueWidth > width * 0.55) valueWidth = width * 0.55;
    self.meterValueLabel.frame = CGRectMake(width - 16.0 - valueWidth, 8.0, valueWidth, 20.0);
    CGFloat titleWidth = CGRectGetMinX(self.meterValueLabel.frame) - 16.0 - 8.0;
    if (titleWidth < 60.0) titleWidth = 60.0;
    self.meterTitleLabel.frame = CGRectMake(16.0, 8.0, titleWidth, 20.0);
    self.bar.frame = CGRectMake(16.0, 34.0, width - 32.0, 8.0);
    self.captionLabel.frame = CGRectMake(16.0, 48.0, width - 32.0, 16.0);
}

@end

@interface waStorageUsageCell : UITableViewCell
@property (nonatomic, strong) UIView *swatch;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *sizeLabel;
@end

@implementation waStorageUsageCell

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _swatch = [[UIView alloc] initWithFrame:CGRectZero];
        _swatch.layer.cornerRadius = 2.0;
        _swatch.hidden = YES;
        [self.contentView addSubview:_swatch];
        _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _nameLabel.backgroundColor = [UIColor clearColor];
        _nameLabel.font = [UIFont systemFontOfSize:17.0];
        _nameLabel.textColor = [UIColor blackColor];
        [self.contentView addSubview:_nameLabel];
        _sizeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _sizeLabel.backgroundColor = [UIColor clearColor];
        _sizeLabel.font = [UIFont systemFontOfSize:17.0];
        _sizeLabel.textColor = [UIColor colorWithWhite:0.32 alpha:1.0];
        _sizeLabel.textAlignment = UITextAlignmentRight;
        [self.contentView addSubview:_sizeLabel];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.contentView.bounds);
    CGFloat height = CGRectGetHeight(self.contentView.bounds);
    CGFloat left = 16.0;
    if (!self.swatch.hidden) {
        self.swatch.frame = CGRectMake(16.0, (height - 10.0) / 2.0, 10.0, 10.0);
        left = 36.0;
    } else {
        self.swatch.frame = CGRectZero;
    }
    CGFloat sizeWidth = 0.0;
    if (self.sizeLabel.text.length) sizeWidth = [self.sizeLabel.text sizeWithFont:self.sizeLabel.font].width + 2.0;
    if (sizeWidth < 8.0) sizeWidth = 8.0;
    if (sizeWidth > width - left - 56.0) sizeWidth = width - left - 56.0;
    self.sizeLabel.frame = CGRectMake(width - 16.0 - sizeWidth, 0.0, sizeWidth, height);
    CGFloat nameWidth = CGRectGetMinX(self.sizeLabel.frame) - left - 8.0;
    if (nameWidth < 40.0) nameWidth = 40.0;
    self.nameLabel.frame = CGRectMake(left, 0.0, nameWidth, height);
}

@end

#pragma mark - controller

@interface waStorageController ()
@property (nonatomic, assign) unsigned long long artworkBytes;
@property (nonatomic, assign) unsigned long long streamBytes;
@property (nonatomic, assign) unsigned long long downloadBytes;
@property (nonatomic, assign) unsigned long long freeBytes;
@property (nonatomic, assign) unsigned long long totalBytes;
@property (nonatomic, assign) BOOL measured;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, assign) BOOL needsRefresh;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation waStorageController

- (id)init {
    return [self initWithStyle:UITableViewStyleGrouped];
}

- (id)initWithStyle:(UITableViewStyle)style {
    if ((self = [super initWithStyle:style])) self.title = @"Storage";
    return self;
}

- (void)dealloc {
    [self.spinner stopAnimating];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return orientation != UIInterfaceOrientationPortraitUpsideDown;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = [UIColor groupTableViewBackgroundColor];
    self.tableView.separatorColor = [UIColor lightGrayColor];
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    self.spinner.hidesWhenStopped = YES;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:self.spinner];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self applyMiniInset];
    [self refreshSizes];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self applyMiniInset];
}

// The root controller pads the screen it is showing, not one pushed later, so
// the last section would sit under the mini player until something else moves.
- (void)applyMiniInset {
    CGFloat height = [waRootController miniPlayerCoverHeight];
    UIEdgeInsets inset = self.tableView.contentInset;
    if (fabs(inset.bottom - height) <= 0.5) return;
    inset.bottom = height;
    self.tableView.contentInset = inset;
    self.tableView.scrollIndicatorInsets = inset;
}

- (void)refreshSizes {
    if (self.busy) {
        self.needsRefresh = YES;
        return;
    }
    self.busy = YES;
    [self.spinner startAnimating];
    __weak waStorageController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        unsigned long long artwork = waFolderSize(waArtworkDirectory());
        unsigned long long stream = waFolderSize(waStreamDirectory());
        unsigned long long downloads = waFolderSize(waDownloadsDirectory());
        NSDictionary *fileSystem = [[NSFileManager defaultManager] attributesOfFileSystemForPath:NSHomeDirectory() error:NULL];
        unsigned long long freeBytes = [[fileSystem objectForKey:NSFileSystemFreeSize] unsignedLongLongValue];
        unsigned long long totalBytes = [[fileSystem objectForKey:NSFileSystemSize] unsignedLongLongValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            waStorageController *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.artworkBytes = artwork;
            strongSelf.streamBytes = stream;
            strongSelf.downloadBytes = downloads;
            strongSelf.freeBytes = freeBytes;
            strongSelf.totalBytes = totalBytes;
            strongSelf.measured = YES;
            strongSelf.busy = NO;
            [strongSelf.spinner stopAnimating];
            [strongSelf.tableView reloadData];
            if (strongSelf.needsRefresh) {
                strongSelf.needsRefresh = NO;
                [strongSelf refreshSizes];
            }
        });
    });
}

- (unsigned long long)cacheBytes {
    return self.artworkBytes + self.streamBytes;
}

#pragma mark - table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 4;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return 3;
    return section == 3 ? 3 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return @"Cache";
    if (section == 1) return @"Downloads";
    if (section == 2) return @"Device";
    return @"Clear";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return @"Artwork and streams are trimmed automatically as the cache fills.";
    if (section == 1) return @"Saved on the device and kept until you delete them from Library, Downloads.";
    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (indexPath.section == 0 && indexPath.row == 0) return 72.0;
    if (indexPath.section == 2) return 72.0;
    return 44.0;
}

- (NSString *)pendingOrBytes:(unsigned long long)bytes {
    return self.measured ? waByteString(bytes) : @"…";
}

- (UITableViewCell *)meterCellForSection:(NSInteger)section {
    static NSString *identifier = @"storage.meter";
    waStorageMeterCell *cell = (waStorageMeterCell *)[self.tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[waStorageMeterCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
    if (section == 0) {
        unsigned long long budget = waCacheBudget();
        unsigned long long used = [self cacheBytes];
        cell.meterTitleLabel.text = @"Cache used";
        cell.meterValueLabel.text = [self pendingOrBytes:used];
        cell.bar.capacity = budget;
        cell.bar.segments = [NSArray arrayWithObjects:
                             [NSDictionary dictionaryWithObjectsAndKeys:waArtworkColor(), @"color", [NSNumber numberWithUnsignedLongLong:self.artworkBytes], @"bytes", nil],
                             [NSDictionary dictionaryWithObjectsAndKeys:waStreamColor(), @"color", [NSNumber numberWithUnsignedLongLong:self.streamBytes], @"bytes", nil],
                             nil];
        NSString *caption = [NSString stringWithFormat:@"of %@ · %@", waByteString(budget), waPercentString(budget ? (double)used / (double)budget : 0.0)];
        if (!self.measured) caption = @"of " @"…";
        cell.captionLabel.text = caption;
        [cell setNeedsLayout];
    } else {
        unsigned long long total = self.totalBytes;
        unsigned long long used = total > self.freeBytes ? total - self.freeBytes : 0;
        cell.meterTitleLabel.text = @"Free space";
        cell.meterValueLabel.text = [self pendingOrBytes:self.freeBytes];
        cell.bar.capacity = total ? total : 1ULL;
        cell.bar.segments = [NSArray arrayWithObject:
                             [NSDictionary dictionaryWithObjectsAndKeys:waDeviceColor(), @"color", [NSNumber numberWithUnsignedLongLong:used], @"bytes", nil]];
        NSString *caption = [NSString stringWithFormat:@"of %@ · %@ in use", waByteString(total), waPercentString(total ? (double)used / (double)total : 0.0)];
        if (!self.measured) caption = @"of " @"…";
        cell.captionLabel.text = caption;
        [cell setNeedsLayout];
    }
    return cell;
}

- (UITableViewCell *)usageCellNamed:(NSString *)name bytes:(unsigned long long)bytes color:(UIColor *)color {
    static NSString *identifier = @"storage.usage";
    waStorageUsageCell *cell = (waStorageUsageCell *)[self.tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[waStorageUsageCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
    cell.nameLabel.text = name;
    cell.sizeLabel.text = [self pendingOrBytes:bytes];
    cell.swatch.hidden = (color == nil);
    cell.swatch.backgroundColor = color ?: [UIColor clearColor];
    [cell setNeedsLayout];
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (indexPath.section == 0) {
        if (indexPath.row == 0) return [self meterCellForSection:0];
        if (indexPath.row == 1) return [self usageCellNamed:@"Artwork" bytes:self.artworkBytes color:waArtworkColor()];
        return [self usageCellNamed:@"Streams" bytes:self.streamBytes color:waStreamColor()];
    }
    if (indexPath.section == 1) return [self usageCellNamed:@"Saved tracks" bytes:self.downloadBytes color:nil];
    if (indexPath.section == 2) return [self meterCellForSection:2];
    return [self clearCellForRow:indexPath.row];
}

- (UITableViewCell *)clearCellForRow:(NSInteger)row {
    static NSString *identifier = @"storage.clear";
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:identifier];
        cell.textLabel.font = [UIFont systemFontOfSize:17.0];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:17.0];
    }
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleBlue;
    cell.textLabel.textColor = [UIColor blackColor];
    cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.32 alpha:1.0];
    if (row == 0) {
        cell.textLabel.text = @"Clear Artwork";
        cell.detailTextLabel.text = [self pendingOrBytes:self.artworkBytes];
    } else if (row == 1) {
        cell.textLabel.text = @"Clear Streams";
        cell.detailTextLabel.text = [self pendingOrBytes:self.streamBytes];
    } else {
        cell.textLabel.text = @"Clear All Caches";
        cell.textLabel.textColor = [UIColor redColor];
        cell.detailTextLabel.text = [self pendingOrBytes:[self cacheBytes]];
    }
    cell.textLabel.enabled = self.measured;
    cell.detailTextLabel.enabled = self.measured;
    cell.selectionStyle = self.measured ? UITableViewCellSelectionStyleBlue : UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 3 || !self.measured || self.busy) return;
    NSInteger tag = waStorageAlertArtwork;
    NSString *title = @"Clear Artwork";
    NSString *message = @"Delete cached artwork? Streams and downloads stay.";
    if (indexPath.row == 1) {
        tag = waStorageAlertStreams;
        title = @"Clear Streams";
        message = @"Delete cached streams? Downloads stay.";
    } else if (indexPath.row == 2) {
        tag = waStorageAlertAll;
        title = @"Clear All Caches";
        message = @"Delete cached artwork and streams? Downloads stay.";
    }
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:title
                                                    message:message
                                                   delegate:self
                                          cancelButtonTitle:@"Cancel"
                                          otherButtonTitles:@"Clear", nil];
    alert.tag = tag;
    [alert show];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (buttonIndex != 1) return;
    self.busy = YES;
    [self.spinner startAnimating];
    NSInteger tag = alertView.tag;
    __weak waStorageController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSSet *active = [NSSet setWithArray:waActiveStreamCachePathList() ?: [NSArray array]];
        if (tag == waStorageAlertArtwork || tag == waStorageAlertAll) {
            waEmptyFolder(waArtworkDirectory(), nil);
            [[waImageCache shared] clearMemory];
        }
        if (tag == waStorageAlertStreams || tag == waStorageAlertAll) {
            waEmptyFolder(waStreamDirectory(), active);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            waStorageController *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.busy = NO;
            [strongSelf.spinner stopAnimating];
            [strongSelf refreshSizes];
        });
    });
}

@end
