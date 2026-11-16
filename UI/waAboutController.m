#import "waAboutController.h"
#import "../Core/waDownloader.h"
#import <sys/sysctl.h>

static NSString *waHardwareIdentifier(void) {
    size_t size = 0;
    if (sysctlbyname("hw.machine", NULL, &size, NULL, 0) != 0 || size == 0) return nil;
    char *machine = malloc(size);
    if (!machine) return nil;
    NSString *identifier = nil;
    if (sysctlbyname("hw.machine", machine, &size, NULL, 0) == 0) {
        identifier = [NSString stringWithUTF8String:machine];
    }
    free(machine);
    return identifier.length ? identifier : nil;
}

static NSString *waFriendlyModel(NSString *identifier) {
    if (!identifier.length) return [[UIDevice currentDevice] model];
    NSDictionary *names = [NSDictionary dictionaryWithObjectsAndKeys:
                           @"iPhone 3GS", @"iPhone2,1",
                           @"iPhone 4", @"iPhone3,1",
                           @"iPhone 4 (GSM)", @"iPhone3,2",
                           @"iPhone 4 (CDMA)", @"iPhone3,3",
                           @"iPhone 4S", @"iPhone4,1",
                           @"iPhone 5", @"iPhone5,1",
                           @"iPhone 5", @"iPhone5,2",
                           @"iPod touch (2nd gen)", @"iPod2,1",
                           @"iPod touch (3rd gen)", @"iPod3,1",
                           @"iPod touch (4th gen)", @"iPod4,1",
                           @"iPad", @"iPad1,1",
                           @"iPad 2", @"iPad2,1",
                           @"iPad 2", @"iPad2,2",
                           @"iPad 2", @"iPad2,3",
                           @"iPad 2", @"iPad2,4",
                           @"iPad (3rd gen)", @"iPad3,1",
                           @"iPad (3rd gen)", @"iPad3,2",
                           @"iPad (3rd gen)", @"iPad3,3",
                           nil];
    NSString *friendly = [names objectForKey:identifier];
    return friendly.length ? friendly : identifier;
}

static NSString *waByteString(unsigned long long bytes) {
    if (bytes < 1024ULL) return [NSString stringWithFormat:@"%llu B", bytes];
    double value = (double)bytes / 1024.0;
    if (value < 1024.0) return [NSString stringWithFormat:@"%.1f MB", value];
    value /= 1024.0;
    return [NSString stringWithFormat:@"%.1f GB", value];
}

static NSString *waBundleVersion(void) {
    NSString *version = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
    return [version isKindOfClass:[NSString class]] && version.length ? version : @"0.3.0";
}

#pragma mark - header

@interface waAboutHeader : UIView
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *taglineLabel;
@end

@implementation waAboutHeader

- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _iconView.image = [UIImage imageNamed:@"Icon.png"];
        _iconView.layer.cornerRadius = 10.0;
        _iconView.layer.masksToBounds = YES;
        _iconView.layer.borderWidth = 1.0;
        _iconView.layer.borderColor = [UIColor colorWithWhite:0.0 alpha:0.18].CGColor;
        [self addSubview:_iconView];

        _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _nameLabel.backgroundColor = [UIColor clearColor];
        _nameLabel.font = [UIFont boldSystemFontOfSize:22.0];
        _nameLabel.textColor = [UIColor blackColor];
        _nameLabel.text = @"Wave";
        [self addSubview:_nameLabel];

        _taglineLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _taglineLabel.backgroundColor = [UIColor clearColor];
        _taglineLabel.font = [UIFont systemFontOfSize:13.0];
        _taglineLabel.textColor = [UIColor grayColor];
        _taglineLabel.numberOfLines = 2;
        _taglineLabel.text = @"Deezer client for iOS 5.1";
        [self addSubview:_taglineLabel];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    CGFloat side = 57.0;
    self.iconView.frame = CGRectMake(16.0, (height - side) / 2.0, side, side);
    CGFloat textLeft = CGRectGetMaxX(self.iconView.frame) + 12.0;
    CGFloat textWidth = width - textLeft - 16.0;
    if (textWidth < 80.0) textWidth = 80.0;
    self.nameLabel.frame = CGRectMake(textLeft, height / 2.0 - 26.0, textWidth, 28.0);
    self.taglineLabel.frame = CGRectMake(textLeft, height / 2.0 + 4.0, textWidth, 34.0);
}

@end

#pragma mark - licenses

@interface waLicensesController : UIViewController
@end

@implementation waLicensesController

- (void)loadView {
    UITextView *text = [[UITextView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    text.editable = NO;
    text.alwaysBounceVertical = YES;
    text.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    text.backgroundColor = [UIColor whiteColor];
    text.font = [UIFont systemFontOfSize:13.0];
    text.textColor = [UIColor colorWithWhite:0.15 alpha:1.0];
    text.text = @"OrigamiEngine\nMIT License. Copyright (c) 2012 ap4y.\n\n"
                @"libFLAC\nBSD License. Copyright (c) 2000-2007 Josh Coalson, Xiph.Org Foundation.\n\n"
                @"quirc\nISC License. Copyright (c) 2010-2012 Daniel Beer.\n\n"
                @"mbedTLS\nApache License 2.0. Copyright (c) ARM Limited.\n\n"
                @"All four are used unmodified apart from build flags.";
    self.view = text;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Licenses";
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return orientation != UIInterfaceOrientationPortraitUpsideDown;
}

@end

#pragma mark - about

@interface waAboutController ()
@property (nonatomic, copy) NSString *deviceName;
@property (nonatomic, copy) NSString *hardware;
@property (nonatomic, assign) BOOL copyFlash;
@end

@implementation waAboutController

- (id)init {
    return [self initWithStyle:UITableViewStyleGrouped];
}

- (id)initWithStyle:(UITableViewStyle)style {
    if ((self = [super initWithStyle:style])) self.title = @"About";
    return self;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return orientation != UIInterfaceOrientationPortraitUpsideDown;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = [UIColor groupTableViewBackgroundColor];
    self.tableView.separatorColor = [UIColor lightGrayColor];
    self.hardware = waHardwareIdentifier();
    self.deviceName = waFriendlyModel(self.hardware);
    self.tableView.tableHeaderView = [[waAboutHeader alloc] initWithFrame:CGRectMake(0.0, 0.0, CGRectGetWidth(self.tableView.bounds), 96.0)];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIView *header = self.tableView.tableHeaderView;
    CGFloat width = CGRectGetWidth(self.tableView.bounds);
    if (header && fabs(CGRectGetWidth(header.frame) - width) > 0.5) {
        CGRect frame = header.frame;
        frame.size.width = width;
        header.frame = frame;
        self.tableView.tableHeaderView = header;
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return 3;
    return section == 1 ? 2 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return section == 1 ? @"This App" : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section != 2) return nil;
    return @"Unofficial Deezer client. Not affiliated with Deezer.";
}

- (UITableViewCell *)valueCellWithIdentifier:(NSString *)identifier {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:identifier];
        cell.textLabel.font = [UIFont systemFontOfSize:17.0];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:17.0];
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.32 alpha:1.0];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.textLabel.textColor = [UIColor blackColor];
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (indexPath.section == 0) {
        UITableViewCell *cell = [self valueCellWithIdentifier:@"about.value"];
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Version";
            NSString *build = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleVersion"];
            NSString *version = waBundleVersion();
            if ([build isKindOfClass:[NSString class]] && build.length && ![build isEqualToString:version]) {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ (%@)", version, build];
            } else {
                cell.detailTextLabel.text = version;
            }
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Software";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"iOS %@", [[UIDevice currentDevice] systemVersion]];
        } else {
            cell.textLabel.text = @"Model";
            cell.detailTextLabel.text = self.deviceName.length ? self.deviceName : @"Device";
        }
        return cell;
    }
    if (indexPath.section == 1) {
        UITableViewCell *cell = [self valueCellWithIdentifier:@"about.link"];
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.detailTextLabel.text = nil;
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Source Code";
            cell.textLabel.textColor = [UIColor colorWithRed:0.16 green:0.33 blue:0.58 alpha:1.0];
        } else {
            cell.textLabel.text = @"Licenses";
        }
        return cell;
    }
    UITableViewCell *cell = [self valueCellWithIdentifier:@"about.copy"];
    cell.textLabel.text = @"Copy Diagnostics";
    cell.textLabel.textColor = [UIColor blackColor];
    cell.selectionStyle = UITableViewCellSelectionStyleBlue;
    cell.detailTextLabel.text = self.copyFlash ? @"Copied" : @"";
    return cell;
}

- (NSString *)diagnostics {
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"wave %@\n", waBundleVersion()];
    [text appendFormat:@"iOS %@\n", [[UIDevice currentDevice] systemVersion]];
    [text appendFormat:@"%@%@\n", self.deviceName ?: @"Device", self.hardware.length ? [NSString stringWithFormat:@" (%@)", self.hardware] : @""];
    [text appendFormat:@"%@\n", [[NSBundle mainBundle] bundleIdentifier] ?: @"com.sokubit.wave"];
    waDownloader *downloader = [waDownloader shared];
    NSUInteger tracks = 0;
    NSUInteger busy = 0;
    for (waDownload *download in [downloader downloads]) {
        if (download.state == waDownloadCompleted) tracks++;
        else if (download.state == waDownloadQueued || download.state == waDownloadDownloading) busy++;
    }
    [text appendFormat:@"Downloads %lu saved, %lu in progress, %@\n",
        (unsigned long)tracks, (unsigned long)busy, waByteString([downloader downloadedBytes])];
    [text appendFormat:@"Hardware %@", self.hardware.length ? self.hardware : @"unknown"];
    return text;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            NSURL *url = [NSURL URLWithString:@"https://github.com/tsuchinaka/wave"];
            if (url) [[UIApplication sharedApplication] openURL:url];
        } else {
            [self.navigationController pushViewController:[[waLicensesController alloc] init] animated:YES];
        }
        return;
    }
    if (indexPath.section != 2) return;
    [[UIPasteboard generalPasteboard] setString:[self diagnostics]];
    self.copyFlash = YES;
    NSIndexPath *path = [NSIndexPath indexPathForRow:0 inSection:2];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:path];
    if ([cell isKindOfClass:[UITableViewCell class]]) cell.detailTextLabel.text = @"Copied";
    __weak waAboutController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        waAboutController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.copyFlash = NO;
        UITableViewCell *current = [strongSelf.tableView cellForRowAtIndexPath:path];
        if ([current isKindOfClass:[UITableViewCell class]]) current.detailTextLabel.text = @"";
    });
}

@end
