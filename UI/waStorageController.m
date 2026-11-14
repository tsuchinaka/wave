#import "waStorageController.h"

enum {
    waStorageAlertImages = 1,
    waStorageAlertStream = 2,
    waStorageAlertAll = 3
};

static NSString *waByteString(unsigned long long bytes) {
    if (bytes < 1024ULL) return [NSString stringWithFormat:@"%llu B", bytes];
    double value = (double)bytes / 1024.0;
    if (value < 1024.0) return [NSString stringWithFormat:@"%.1f KB", value];
    value /= 1024.0;
    if (value < 1024.0) return [NSString stringWithFormat:@"%.1f MB", value];
    value /= 1024.0;
    return [NSString stringWithFormat:@"%.1f GB", value];
}

static unsigned long long waFolderSize(NSString *path) {
    NSFileManager *manager = [NSFileManager defaultManager];
    BOOL directory = NO;
    if (![manager fileExistsAtPath:path isDirectory:&directory] || !directory) return 0;
    unsigned long long total = 0;
    NSArray *items = [manager subpathsOfDirectoryAtPath:path error:NULL];
    for (NSString *item in items) {
        NSString *full = [path stringByAppendingPathComponent:item];
        NSDictionary *attrs = [manager attributesOfItemAtPath:full error:NULL];
        if ([[attrs fileType] isEqualToString:NSFileTypeRegular]) total += [attrs fileSize];
    }
    return total;
}

@interface waStorageController () <UIAlertViewDelegate>
@property (nonatomic, assign) unsigned long long imageBytes;
@property (nonatomic, assign) unsigned long long streamBytes;
@property (nonatomic, assign) unsigned long long downloadBytes;
@property (nonatomic, assign) unsigned long long freeBytes;
@property (nonatomic, assign) unsigned long long totalBytes;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, strong) UIProgressView *usageBar;
@end

@implementation waStorageController

- (id)init {
    return [self initWithStyle:UITableViewStyleGrouped];
}

- (id)initWithStyle:(UITableViewStyle)style {
    if ((self = [super initWithStyle:style])) self.title = @"Storage";
    return self;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return orientation != UIInterfaceOrientationPortraitUpsideDown;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = [UIColor groupTableViewBackgroundColor];
    self.usageBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.usageBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshSizes];
}

- (NSString *)cachesPath {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    return paths.count ? [paths objectAtIndex:0] : nil;
}

- (void)refreshSizes {
    if (self.busy) return;
    self.busy = YES;
    NSString *caches = [self cachesPath];
    __weak waStorageController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        unsigned long long images = waFolderSize([caches stringByAppendingPathComponent:@"Artwork"]);
        unsigned long long stream = waFolderSize([caches stringByAppendingPathComponent:@"StreamCache"]);
        unsigned long long downloads = waFolderSize([caches stringByAppendingPathComponent:@"Downloads"]);
        NSDictionary *fs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:NSHomeDirectory() error:NULL];
        unsigned long long freeBytes = [[fs objectForKey:NSFileSystemFreeSize] unsignedLongLongValue];
        unsigned long long totalBytes = [[fs objectForKey:NSFileSystemSize] unsignedLongLongValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            waStorageController *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.busy = NO;
            strongSelf.imageBytes = images;
            strongSelf.streamBytes = stream;
            strongSelf.downloadBytes = downloads;
            strongSelf.freeBytes = freeBytes;
            strongSelf.totalBytes = totalBytes;
            if (strongSelf.view.window) [strongSelf.tableView reloadData];
        });
    });
}

- (unsigned long long)usedBytes {
    return self.imageBytes + self.streamBytes + self.downloadBytes;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return 4;
    if (section == 1) return 1;
    return 3;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return @"Usage";
    if (section == 1) return @"Device";
    return @"Clear Cache";
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (indexPath.section == 1) return 72.0;
    return 44.0;
}

- (UITableViewCell *)valueCell:(NSString *)reuse {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:reuse];
        cell.textLabel.font = [UIFont systemFontOfSize:17.0];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (indexPath.section == 0) {
        UITableViewCell *cell = [self valueCell:@"storage.usage"];
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Images";
            cell.detailTextLabel.text = waByteString(self.imageBytes);
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Stream";
            cell.detailTextLabel.text = waByteString(self.streamBytes);
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"Downloads";
            cell.detailTextLabel.text = waByteString(self.downloadBytes);
        } else {
            cell.textLabel.text = @"Total";
            cell.textLabel.font = [UIFont boldSystemFontOfSize:17.0];
            cell.detailTextLabel.text = waByteString([self usedBytes]);
        }
        return cell;
    }
    if (indexPath.section == 1) {
        static NSString *kMeter = @"storage.meter";
        UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:kMeter];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kMeter];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            UIProgressView *bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
            bar.tag = 500;
            bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            [cell.contentView addSubview:bar];
            cell.textLabel.font = [UIFont boldSystemFontOfSize:17.0];
            cell.detailTextLabel.font = [UIFont systemFontOfSize:12.0];
            cell.detailTextLabel.textColor = [UIColor grayColor];
        }
        UIProgressView *bar = (UIProgressView *)[cell.contentView viewWithTag:500];
        CGFloat w = CGRectGetWidth(cell.contentView.bounds);
        if (w < 2.0) w = CGRectGetWidth(self.tableView.bounds) - 20.0;
        bar.frame = CGRectMake(10.0, 52.0, w - 20.0, 9.0);
        float fraction = 0.0f;
        if (self.totalBytes > 0) fraction = (float)((double)[self usedBytes] / (double)self.totalBytes);
        if (fraction < 0.0f) fraction = 0.0f;
        if (fraction > 1.0f) fraction = 1.0f;
        bar.progress = fraction;
        cell.textLabel.text = @" ";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ used · %@ free", waByteString([self usedBytes]), waByteString(self.freeBytes)];
        return cell;
    }
    UITableViewCell *cell = [self valueCell:@"storage.clear"];
    cell.selectionStyle = UITableViewCellSelectionStyleBlue;
    if (indexPath.row == 0) cell.textLabel.text = @"Clear Image Cache";
    else if (indexPath.row == 1) cell.textLabel.text = @"Clear Stream Cache";
    else {
        cell.textLabel.text = @"Clear All";
        cell.textLabel.textColor = [UIColor redColor];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 2) return;
    NSInteger tag = waStorageAlertImages;
    NSString *title = @"Clear Image Cache";
    NSString *message = @"Delete cached artwork?";
    if (indexPath.row == 1) {
        tag = waStorageAlertStream;
        title = @"Clear Stream Cache";
        message = @"Delete cached streams?";
    } else if (indexPath.row == 2) {
        tag = waStorageAlertAll;
        title = @"Clear All";
        message = @"Delete all cached data?";
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
    NSString *caches = [self cachesPath];
    NSFileManager *manager = [NSFileManager defaultManager];
    if (alertView.tag == waStorageAlertImages || alertView.tag == waStorageAlertAll) {
        [manager removeItemAtPath:[caches stringByAppendingPathComponent:@"Artwork"] error:NULL];
    }
    if (alertView.tag == waStorageAlertStream || alertView.tag == waStorageAlertAll) {
        [manager removeItemAtPath:[caches stringByAppendingPathComponent:@"StreamCache"] error:NULL];
    }
    [self refreshSizes];
}

@end
