#import "waStorageViewController.h"
#import "waDownloadedSongsViewController.h"
#import "../Models/waPreferences.h"
#import "../Services/waDownloadManager.h"
#import "../Services/waImageLoader.h"
#import "../Services/waTheme.h"
#import "../Vendor/OrigamiEngine/Plugins/HTTPSource.h"
#import "../Views/waActions.h"
#import "../Views/waAction.h"
#import "../Views/waSettingsCell.h"

@interface waStorageMeterCell : waSettingsCell
// Stacked fractions of the track width. otherFraction == 0 draws the
// single-segment (cache) variant with the same look.
@property (nonatomic, assign) double waveFraction;
@property (nonatomic, assign) double otherFraction;
@property (nonatomic, copy) NSString *caption;
@end

@implementation waStorageMeterCell {
    UIView *_meterTrack;
    UIView *_meterOther;
    UIView *_meterWave;
    UILabel *_meterCaption;
}

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.userInteractionEnabled = NO;
        _meterTrack = [[UIView alloc] initWithFrame:CGRectZero];
        _meterTrack.backgroundColor = [waTheme separatorColor];
        [self.contentView addSubview:_meterTrack];
        _meterOther = [[UIView alloc] initWithFrame:CGRectZero];
        _meterOther.backgroundColor = [waTheme secondaryTextColor];
        [_meterTrack addSubview:_meterOther];
        _meterWave = [[UIView alloc] initWithFrame:CGRectZero];
        _meterWave.backgroundColor = [waTheme barColor];
        [_meterTrack addSubview:_meterWave];
        _meterCaption = [[UILabel alloc] initWithFrame:CGRectZero];
        _meterCaption.font = [waTheme secondaryRegularFontOfSize:13.0];
        _meterCaption.textColor = [waTheme secondaryTextColor];
        _meterCaption.backgroundColor = [UIColor clearColor];
        [self.contentView addSubview:_meterCaption];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // Measured from our own bounds, never the table's: grouped cells,
    // insets and rotation can all make tableView.bounds lie about the
    // width we actually have.
    CGFloat width = MAX(0.0, self.contentView.bounds.size.width - 30.0);
    _meterTrack.frame = CGRectMake(15.0, 12.0, width, 10.0);
    _meterCaption.frame = CGRectMake(15.0, 26.0, width, 18.0);
    _meterTrack.backgroundColor = [waTheme separatorColor];
    _meterOther.backgroundColor = [waTheme secondaryTextColor];
    _meterWave.backgroundColor = [waTheme barColor];
    double wave = MIN(1.0, MAX(0.0, self.waveFraction));
    double other = MIN(1.0 - wave, MAX(0.0, self.otherFraction));
    CGFloat barWidth = _meterTrack.bounds.size.width;
    CGFloat barHeight = _meterTrack.bounds.size.height;
    _meterWave.frame = CGRectMake(0.0, 0.0, barWidth * wave, barHeight);
    _meterOther.frame = CGRectMake(barWidth * wave, 0.0, barWidth * other, barHeight);
    _meterCaption.text = self.caption;
}

@end

@interface waStorageViewController ()
@property (nonatomic, assign) NSUInteger completedCount;
@property (nonatomic, assign) unsigned long long downloadedBytes;
@property (nonatomic, assign) unsigned long long imageBytes;
@property (nonatomic, assign) unsigned long long streamBytes;
@property (nonatomic, assign) unsigned long long deviceFreeBytes;
@property (nonatomic, assign) unsigned long long deviceTotalBytes;
@property (nonatomic, assign) BOOL statsInFlight;
@property (nonatomic, assign) BOOL deletingDownloads;
@property (nonatomic, assign) BOOL deletingCache;
- (void)refreshStats;
- (void)showCacheOptions;
- (void)confirmDeleteDownloads;
- (void)confirmDeleteCache;
- (void)showMessage:(NSString *)title message:(NSString *)message;
- (unsigned long long)waveBytes;
@end

@implementation waStorageViewController

- (id)initWithStyle:(UITableViewStyle)style {
    if ((self = [super initWithStyle:style])) self.title = @"Storage";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    self.tableView.backgroundColor = [waTheme backgroundColor];
    UIView *tableBackground = [[UIView alloc] initWithFrame:CGRectZero];
    tableBackground.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tableBackground.backgroundColor = [waTheme backgroundColor];
    self.tableView.backgroundView = tableBackground;
    [waTheme applyToView:self.view];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(statsDidChange:) name:waDownloadManagerDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeDidChange:) name:waThemeDidChangeNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshStats];
}

- (void)statsDidChange:(NSNotification *)notification {
    (void)notification;
    [self refreshStats];
}

- (void)themeDidChange:(NSNotification *)notification {
    (void)notification;
    self.tableView.backgroundColor = [waTheme backgroundColor];
    if (self.view.window) [self.tableView reloadData];
}

- (unsigned long long)waveBytes {
    return self.downloadedBytes + self.imageBytes + self.streamBytes;
}

- (void)refreshStats {
    if (self.statsInFlight) return;
    self.statsInFlight = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSUInteger completed = [[waDownloadManager sharedManager] completedCount];
        unsigned long long downloaded = [[waDownloadManager sharedManager] downloadedBytes];
        unsigned long long imageBytes = [[waImageLoader sharedLoader] cachedBytes];
        unsigned long long streamBytes = [HTTPSource streamCacheBytes];
        NSDictionary *fs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:NSHomeDirectory() error:NULL];
        unsigned long long freeBytes = [fs[NSFileSystemFreeSize] respondsToSelector:@selector(unsignedLongLongValue)] ? [fs[NSFileSystemFreeSize] unsignedLongLongValue] : 0;
        unsigned long long totalBytes = [fs[NSFileSystemSize] respondsToSelector:@selector(unsignedLongLongValue)] ? [fs[NSFileSystemSize] unsignedLongLongValue] : 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            waStorageViewController *controller = weakSelf;
            if (!controller) return;
            controller.statsInFlight = NO;
            controller.completedCount = completed;
            controller.downloadedBytes = downloaded;
            controller.imageBytes = imageBytes;
            controller.streamBytes = streamBytes;
            controller.deviceFreeBytes = freeBytes;
            controller.deviceTotalBytes = totalBytes;
            if (controller.view.window) [controller.tableView reloadData];
        });
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 4;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return 3;
    if (section == 1) return 1;
    if (section == 2) return 2;
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return @"Usage";
    if (section == 1) return @"Device";
    if (section == 2) return @"Stream & Artwork Cache";
    return @"Danger Zone";
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    (void)tableView;
    waSettingsHeader *header = [[waSettingsHeader alloc] initWithReuseIdentifier:@"storage-header"];
    header.textLabel.text = [self tableView:self.tableView titleForHeaderInSection:section];
    header.textLabel.font = [waTheme boldFontOfSize:14.0];
    return header;
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
        UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
        header.textLabel.font = [waTheme boldFontOfSize:14.0];
    }
}

- (waSettingsCell *)settingsCell {
    waSettingsCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"storage-setting"];
    if (!cell) cell = [[waSettingsCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"storage-setting"];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.userInteractionEnabled = YES;
    cell.textLabel.enabled = YES;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    (void)tableView;
    if ((path.section == 1 && path.row == 0)) return [self deviceMeterCell];
    if (path.section == 2 && path.row == 0) return [self cacheMeterCell];
    waSettingsCell *cell = [self settingsCell];
    NSInteger rowCount = [self tableView:self.tableView numberOfRowsInSection:path.section];
    cell.sectionPosition = rowCount == 1 ? 3 : (path.row == 0 ? 0 : (path.row == rowCount - 1 ? 2 : 1));
    BOOL busy = NO;
    if (path.section == 0 && path.row == 0) {
        cell.textLabel.text = @"Downloads";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu songs • %@", (unsigned long)self.completedCount, waFileSizeString(self.downloadedBytes)];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (path.section == 0 && path.row == 1) {
        cell.textLabel.text = @"Image cache";
        cell.detailTextLabel.text = waFileSizeString(self.imageBytes);
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (path.section == 0 && path.row == 2) {
        cell.textLabel.text = @"Stream cache";
        cell.detailTextLabel.text = waFileSizeString(self.streamBytes);
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (path.section == 2 && path.row == 1) {
        cell.textLabel.text = @"Cache limit";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu MB", (unsigned long)[waPreferences sharedPreferences].cacheSizeMB];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (path.section == 3 && path.row == 0) {
        busy = self.deletingDownloads;
        cell.textLabel.text = busy ? @"Deleting downloads…" : @"Delete downloads";
    } else {
        busy = self.deletingCache;
        cell.textLabel.text = busy ? @"Deleting cache…" : @"Delete cache";
    }
    if (busy) {
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
        [spinner startAnimating];
        cell.accessoryView = spinner;
        cell.userInteractionEnabled = NO;
        cell.textLabel.enabled = NO;
    }
    [waTheme applyToView:cell];
    return cell;
}

// Stacked device bar: Wave | everything else | free. Answers "how much
// of my phone does Wave eat" at a glance.
- (UITableViewCell *)deviceMeterCell {
    waStorageMeterCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"storage-meter"];
    if (!cell) cell = [[waStorageMeterCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"storage-meter"];
    unsigned long long total = self.deviceTotalBytes;
    unsigned long long waveBytes = [self waveBytes];
    unsigned long long freeBytes = MIN(self.deviceFreeBytes, total);
    if (total > 0) {
        cell.waveFraction = (double)waveBytes / (double)total;
        unsigned long long accounted = MIN(waveBytes, total - freeBytes);
        cell.otherFraction = (double)(total - freeBytes - accounted) / (double)total;
        cell.caption = [NSString stringWithFormat:@"Wave %@ • Free %@ of %@", waFileSizeString(waveBytes), waFileSizeString(freeBytes), waFileSizeString(total)];
    } else {
        cell.waveFraction = 0.0;
        cell.otherFraction = 0.0;
        cell.caption = @"Reading device storage…";
    }
    [cell setNeedsLayout];
    [waTheme applyToView:cell];
    return cell;
}

- (UITableViewCell *)cacheMeterCell {
    waStorageMeterCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"storage-meter"];
    if (!cell) cell = [[waStorageMeterCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"storage-meter"];
    unsigned long long used = self.imageBytes + self.streamBytes;
    unsigned long long limit = (unsigned long long)MAX(1, [waPreferences sharedPreferences].cacheSizeMB) * 1024ULL * 1024ULL;
    cell.waveFraction = (double)used / (double)limit;
    cell.otherFraction = 0.0;
    cell.caption = [NSString stringWithFormat:@"%@ of %@ used", waFileSizeString(used), waFileSizeString(limit)];
    [cell setNeedsLayout];
    [waTheme applyToView:cell];
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)path {
    (void)tableView;
    if ((path.section == 1 && path.row == 0) || (path.section == 2 && path.row == 0)) return 56.0;
    return 44.0;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (path.section == 0 && path.row == 0) return [self.navigationController pushViewController:[[waDownloadedSongsViewController alloc] initWithStyle:UITableViewStylePlain] animated:YES];
    if (path.section == 2 && path.row == 1) return [self showCacheOptions];
    if (path.section == 3 && path.row == 0 && !self.deletingDownloads) return [self confirmDeleteDownloads];
    if (path.section == 3 && path.row == 1 && !self.deletingCache) return [self confirmDeleteCache];
}

- (void)showCacheOptions {
    __weak typeof(self) weakSelf = self;
    NSMutableArray *actions = [NSMutableArray array];
    for (NSNumber *megabytes in @[@128, @256, @512]) {
        [actions addObject:[waAction actionWithIdentifier:[@"settings.cache." stringByAppendingString:[megabytes stringValue]] title:[NSString stringWithFormat:@"%@ MB", megabytes] handler:^(id object) {
            (void)object;
            [waPreferences sharedPreferences].cacheSizeMB = [megabytes unsignedIntegerValue];
            [[waImageLoader sharedLoader] trimCache];
            [HTTPSource trimStreamCache];
            [weakSelf.tableView reloadData];
        }]];
    }
    [[waActions sharedActions] presentTitle:@"Cache size" actions:actions object:nil fromViewController:self];
}

- (void)confirmDeleteDownloads {
    __weak typeof(self) weakSelf = self;
    waAction *action = [waAction actionWithIdentifier:@"storage.deleteDownloads" title:@"Delete" destructive:YES availability:nil handler:^(id object) {
        (void)object;
        waStorageViewController *controller = weakSelf;
        if (!controller) return;
        controller.deletingDownloads = YES;
        [controller.tableView reloadData];
        [[waDownloadManager sharedManager] deleteDownloadsWithCompletion:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                waStorageViewController *strongController = weakSelf;
                if (!strongController) return;
                strongController.deletingDownloads = NO;
                [strongController refreshStats];
                if (error) [strongController showMessage:@"Delete downloads" message:error.localizedDescription];
            });
        }];
    }];
    [[waActions sharedActions] presentTitle:@"Delete downloads?" actions:@[action] object:nil fromViewController:self];
}

- (void)confirmDeleteCache {
    __weak typeof(self) weakSelf = self;
    waAction *action = [waAction actionWithIdentifier:@"storage.deleteCache" title:@"Delete" destructive:YES availability:nil handler:^(id object) {
        (void)object;
        waStorageViewController *controller = weakSelf;
        if (!controller) return;
        controller.deletingCache = YES;
        [controller.tableView reloadData];
        [[waImageLoader sharedLoader] clearCacheWithCompletion:^{
            [HTTPSource clearStreamCacheWithCompletion:^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    waStorageViewController *strongController = weakSelf;
                    if (!strongController) return;
                    strongController.deletingCache = NO;
                    [strongController refreshStats];
                });
            }];
        }];
    }];
    [[waActions sharedActions] presentTitle:@"Delete cache?" actions:@[action] object:nil fromViewController:self];
}

- (void)showMessage:(NSString *)title message:(NSString *)message {
    [[[UIAlertView alloc] initWithTitle:title message:message delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
