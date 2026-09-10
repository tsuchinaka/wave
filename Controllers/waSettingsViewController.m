#import "waSettingsViewController.h"
#import "waProfileViewController.h"
#import "waThemeViewController.h"
#import "waEQViewController.h"
#import "waLogsViewController.h"
#import "waQRScannerViewController.h"
#import "../Models/waPreferences.h"
#import "../Services/waAPIClient.h"
#import "../Services/waDownloadManager.h"
#import "../Services/waImageLoader.h"
#import "../Services/waTheme.h"
#import "../Services/waLastFMClient.h"
#import "waDeezerLoginViewController.h"
#import "../Services/waDeezerClient.h"
#import "../Services/waRPCClient.h"
#import "../Services/waAudioPlayer.h"
#import "../Services/waDebugLog.h"
#import "waStorageViewController.h"
#import "../Vendor/OrigamiEngine/Plugins/HTTPSource.h"
#import "../Views/waActions.h"
#import "../Views/waAction.h"
#import "../Views/waSettingsCell.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static NSInteger const waAlertLastFMLogout = 102;

typedef NS_ENUM(NSInteger, waSettingsItemKind) {
    waSettingsItemKindInfo,    // static detail, no selection
    waSettingsItemKindAction,  // tap runs, no chevron (alerts, ping, export)
    waSettingsItemKindSheet,   // tap runs, chevron (option sheets)
    waSettingsItemKindPush,    // tap pushes, chevron
    waSettingsItemKindSwitch,  // UISwitch accessory
    waSettingsItemKindStepper  // UIStepper accessory (crossfade)
};

// One row descriptor. Blocks read live state through weakSelf, so the
// table is built once and never goes stale when rows move between
// sections — no more section == X && row == Y conditionals.
@interface waSettingsItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, assign) waSettingsItemKind kind;
@property (nonatomic, copy) NSString *(^detail)(void);
@property (nonatomic, copy) void (^select)(void);
@property (nonatomic, copy) BOOL (^switchState)(void);
@property (nonatomic, copy) void (^switchSet)(BOOL on);
@property (nonatomic, copy) BOOL (^busy)(void);
@property (nonatomic, copy) NSString *busyTitle;
@property (nonatomic, copy) double (^stepperValue)(void);
@property (nonatomic, copy) void (^stepperSet)(double value);
+ (id)itemWithTitle:(NSString *)title kind:(waSettingsItemKind)kind;
@end

@implementation waSettingsItem
+ (id)itemWithTitle:(NSString *)title kind:(waSettingsItemKind)kind {
    waSettingsItem *item = [[self alloc] init];
    item.title = title;
    item.kind = kind;
    return item;
}
@end

@interface waSettingsViewController () <waQRScannerViewControllerDelegate>
@property (nonatomic, strong) NSArray *sections;
@property (nonatomic, strong) waSettingsItem *pingItem;
@property (nonatomic, strong) waSettingsItem *storageItem;
@property (nonatomic, strong) waSettingsItem *crossfadeItem;
@property (nonatomic, strong) waSettingsItem *sleepItem;
@property (nonatomic, strong) NSTimer *pingTimer;
@property (nonatomic, copy) NSString *pingStatus;
@property (nonatomic, assign) BOOL pingInFlight;
@property (nonatomic, assign) unsigned long long cachedImageBytes;
@property (nonatomic, assign) unsigned long long cachedStreamBytes;
@property (nonatomic, assign) unsigned long long downloadedBytes;
@property (nonatomic, assign) BOOL statsRefreshInFlight;
// Controls are expensive to build and iOS 6 cells recycle often; keep one
// instance per row and re-attach it to whichever cell is being configured.
@property (nonatomic, strong) NSMutableDictionary *switchCache;
@property (nonatomic, strong) UIStepper *crossfadeStepper;
- (void)pairDiscordBridge;
- (void)showManualDiscordPairing;
- (void)pairDiscordPIN:(NSString *)pin;
- (void)showSleepOptions;
- (void)exportLog;
@end

@implementation waSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    self.title = nil;
    self.navigationItem.title = @"Settings";
    [self buildSections];
    self.tableView.backgroundColor = [waTheme backgroundColor];
    UIView *tableBackground = [[UIView alloc] initWithFrame:CGRectZero];
    tableBackground.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tableBackground.backgroundColor = [waTheme backgroundColor];
    self.tableView.backgroundView = tableBackground;
    [waTheme applyToView:self.view];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(rpcStateDidChange:) name:waRPCClientDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(statsDidChange:) name:waDownloadManagerDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerDidChange:) name:waAudioPlayerDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeDidChange:) name:waThemeDidChangeNotification object:nil];
    [self refreshStorageStats];
}

- (void)playerDidChange:(NSNotification *)notification {
    (void)notification;
    if (self.view.window) [self reloadItem:self.sleepItem];
}

- (void)statsDidChange:(NSNotification *)notification {
    (void)notification;
    [self refreshStorageStats];
}

#pragma mark - Sections model

- (NSArray *)itemsInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sections.count) return @[];
    NSArray *items = self.sections[section][@"items"];
    return [items isKindOfClass:[NSArray class]] ? items : @[];
}

- (waSettingsItem *)itemAtIndexPath:(NSIndexPath *)path {
    NSArray *items = [self itemsInSection:path.section];
    return path.row < (NSInteger)items.count ? items[path.row] : nil;
}

- (NSIndexPath *)indexPathForItem:(waSettingsItem *)item {
    if (!item) return nil;
    for (NSInteger section = 0; section < (NSInteger)self.sections.count; section++) {
        NSArray *items = [self itemsInSection:section];
        NSUInteger row = [items indexOfObjectIdenticalTo:item];
        if (row != NSNotFound) return [NSIndexPath indexPathForRow:row inSection:section];
    }
    return nil;
}

- (void)reloadItem:(waSettingsItem *)item {
    NSIndexPath *path = [self indexPathForItem:item];
    if (!path || !self.view.window) return;
    [self.tableView reloadRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)buildSections {
    __weak waSettingsViewController *weakSelf = self;
    NSArray *qualityTitles = @[@"MP3 128 kbps", @"MP3 320 kbps", @"Lossless (FLAC direct)"];

    // Account
    waSettingsItem *deezerAccount = [waSettingsItem itemWithTitle:@"Deezer account" kind:waSettingsItemKindPush];
     deezerAccount.detail = ^NSString *{
        if ([[waDeezerClient sharedClient] isAuthenticated]) {
            NSString *name = [waDeezerClient sharedClient].userName;
            return name.length ? [NSString stringWithFormat:@"%@ · Deezer", name] : @"Connected to Deezer";
        }
        return @"Sign in to Deezer";
    };
    deezerAccount.select = ^{ [weakSelf selectProfile]; };
    waSettingsItem *lastfmAccount = [waSettingsItem itemWithTitle:@"Last.fm" kind:waSettingsItemKindPush];
    lastfmAccount.detail = ^NSString *{
        return [waLastFMClient sharedClient].isAuthenticated ? ([[NSUserDefaults standardUserDefaults] stringForKey:@"wa.lastfm.username"] ?: @"Connected") : @"Not connected";
    };
    lastfmAccount.select = ^{ [weakSelf selectLastFM]; };
    waSettingsItem *scrobble = [waSettingsItem itemWithTitle:@"Scrobble to Last.fm" kind:waSettingsItemKindSwitch];
    scrobble.switchState = ^BOOL{ return [waPreferences sharedPreferences].lastFMScrobblingEnabled; };
    scrobble.switchSet = ^(BOOL on){ [waPreferences sharedPreferences].lastFMScrobblingEnabled = on; };
    waSettingsItem *privateSession = [waSettingsItem itemWithTitle:@"Private session" kind:waSettingsItemKindSwitch];
    privateSession.switchState = ^BOOL{ return [waPreferences sharedPreferences].privateSession; };
    privateSession.switchSet = ^(BOOL on){ [waPreferences sharedPreferences].privateSession = on; };

    // Playback
    waSettingsItem *playbackQuality = [waSettingsItem itemWithTitle:@"Playback quality" kind:waSettingsItemKindSheet];
    playbackQuality.detail = ^NSString *{ return qualityTitles[MIN(2, [waPreferences sharedPreferences].deezerQuality)]; };
    playbackQuality.select = ^{ [weakSelf showDeezerQualityOptions]; };
    waSettingsItem *equalizer = [waSettingsItem itemWithTitle:@"Equalizer" kind:waSettingsItemKindPush];
    equalizer.detail = ^NSString *{ return [waPreferences sharedPreferences].equalizerPreset; };
    equalizer.select = ^{ [weakSelf.navigationController pushViewController:[[waEQViewController alloc] init] animated:YES]; };
    waSettingsItem *crossfade = [waSettingsItem itemWithTitle:@"Crossfade" kind:waSettingsItemKindStepper];
    crossfade.detail = ^NSString *{
        NSTimeInterval duration = [waPreferences sharedPreferences].crossfadeDuration;
        return duration > 0.0 ? [NSString stringWithFormat:@"%.0fs", duration] : @"Off";
    };
    crossfade.stepperValue = ^double{ return [waPreferences sharedPreferences].crossfadeDuration; };
    crossfade.stepperSet = ^(double value){ [waPreferences sharedPreferences].crossfadeDuration = value; };
    self.crossfadeItem = crossfade;
    waSettingsItem *sleep = [waSettingsItem itemWithTitle:@"Sleep timer" kind:waSettingsItemKindSheet];
    sleep.detail = ^NSString *{
        NSTimeInterval remaining = [[waAudioPlayer sharedPlayer] sleepTimeRemaining];
        return remaining > 0.0 ? [NSString stringWithFormat:@"%d:%02d", (int)(remaining / 60.0), ((int)remaining) % 60] : @"Off";
    };
    sleep.select = ^{ [weakSelf showSleepOptions]; };
    self.sleepItem = sleep;

    // Downloads
    waSettingsItem *downloadQuality = [waSettingsItem itemWithTitle:@"Download quality" kind:waSettingsItemKindSheet];
    downloadQuality.detail = ^NSString *{ return qualityTitles[MIN(2, [waPreferences sharedPreferences].downloadQuality)]; };
    downloadQuality.select = ^{ [weakSelf showDownloadQualityOptions]; };
    waSettingsItem *parallel = [waSettingsItem itemWithTitle:@"Maximum parallel" kind:waSettingsItemKindAction];
    parallel.detail = ^NSString *{ return [NSString stringWithFormat:@"%lu", (unsigned long)[waPreferences sharedPreferences].maximumParallelDownloads]; };
    parallel.select = ^{ [weakSelf showParallelDownloadOptions]; };
    waSettingsItem *cellular = [waSettingsItem itemWithTitle:@"Use cellular data" kind:waSettingsItemKindSwitch];
    cellular.switchState = ^BOOL{ return [waPreferences sharedPreferences].cellularDataAllowed; };
    cellular.switchSet = ^(BOOL on){ [waPreferences sharedPreferences].cellularDataAllowed = on; };
    waSettingsItem *storage = [waSettingsItem itemWithTitle:@"Storage" kind:waSettingsItemKindPush];
    storage.detail = ^NSString *{
        waSettingsViewController *controller = weakSelf;
        return waFileSizeString(controller.cachedImageBytes + controller.cachedStreamBytes + controller.downloadedBytes);
    };
    storage.select = ^{ [weakSelf.navigationController pushViewController:[[waStorageViewController alloc] initWithStyle:UITableViewStyleGrouped] animated:YES]; };
    self.storageItem = storage;

    // Appearance
    waSettingsItem *theme = [waSettingsItem itemWithTitle:@"Theme" kind:waSettingsItemKindPush];
    theme.detail = ^NSString *{ return [waPreferences sharedPreferences].theme; };
    theme.select = ^{ [weakSelf showThemeOptions]; };

    // Connections (serverless: no backend URL/port; Ping checks the
    // fallback backend endpoint, Discord rows manage the local bridge).
    waSettingsItem *ping = [waSettingsItem itemWithTitle:@"Ping" kind:waSettingsItemKindAction];
    ping.detail = ^NSString *{ return weakSelf.pingStatus ?: @"Checking…"; };
    ping.select = ^{ [weakSelf pingNow]; };
    self.pingItem = ping;
    waSettingsItem *discordStatus = [waSettingsItem itemWithTitle:@"Connection" kind:waSettingsItemKindInfo];
    discordStatus.detail = ^NSString *{ return [[waRPCClient sharedClient] isConnected] ? @"Connected" : @"Not connected"; };
    waSettingsItem *discordPair = [waSettingsItem itemWithTitle:@"Pair with Bridge" kind:waSettingsItemKindSheet];
    discordPair.detail = ^NSString *{ return @"Scan QR or enter PIN"; };
    discordPair.select = ^{ [weakSelf pairDiscordBridge]; };
    waSettingsItem *discordShow = [waSettingsItem itemWithTitle:@"Show in Discord" kind:waSettingsItemKindSwitch];
    discordShow.switchState = ^BOOL{ return [[waRPCClient sharedClient] isShowInDiscord]; };
    discordShow.switchSet = ^(BOOL on){ [waRPCClient sharedClient].showInDiscord = on; };

    // About
    waSettingsItem *logs = [waSettingsItem itemWithTitle:@"Logs" kind:waSettingsItemKindPush];
    logs.detail = ^NSString *{ return @"In memory — 300 entries"; };
    logs.select = ^{ [weakSelf.navigationController pushViewController:[[waLogsViewController alloc] init] animated:YES]; };
    waSettingsItem *exportLog = [waSettingsItem itemWithTitle:@"Export log" kind:waSettingsItemKindAction];
    exportLog.select = ^{ [weakSelf exportLog]; };
    waSettingsItem *version = [waSettingsItem itemWithTitle:@"Version" kind:waSettingsItemKindInfo];
    version.detail = ^NSString *{ return [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"] ?: @"1.0"; };

    self.sections = @[
        @{@"title": @"Account", @"items": @[deezerAccount, lastfmAccount, scrobble, privateSession]},
        @{@"title": @"Playback", @"items": @[playbackQuality, equalizer, crossfade, sleep]},
        @{@"title": @"Downloads", @"items": @[downloadQuality, parallel, cellular, storage]},
        @{@"title": @"Appearance", @"items": @[theme]},
        @{@"title": @"Connections", @"items": @[ping, discordStatus, discordPair, discordShow]},
        @{@"title": @"About", @"items": @[logs, exportLog, version]}
    ];
}

- (void)refreshStorageStats {
    // Cheap pure reads happen in cellForRow; the O(n) sweeps and disk
    // scans run here on a background queue, then visible rows refresh.
    if (self.statsRefreshInFlight) return;
    self.statsRefreshInFlight = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        unsigned long long imageBytes = [[waImageLoader sharedLoader] cachedBytes];
        unsigned long long streamBytes = [HTTPSource streamCacheBytes];
        unsigned long long downloadedBytes = [[waDownloadManager sharedManager] downloadedBytes];
        dispatch_async(dispatch_get_main_queue(), ^{
            waSettingsViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.statsRefreshInFlight = NO;
            strongSelf.cachedImageBytes = imageBytes;
            strongSelf.cachedStreamBytes = streamBytes;
            strongSelf.downloadedBytes = downloadedBytes;
            if (!strongSelf.view.window) return;
            NSMutableArray *reload = [NSMutableArray array];
            NSIndexPath *storagePath = [strongSelf indexPathForItem:strongSelf.storageItem];
            if (storagePath && [[strongSelf.tableView indexPathsForVisibleRows] containsObject:storagePath]) [reload addObject:storagePath];
            if (reload.count) [strongSelf.tableView reloadRowsAtIndexPaths:reload withRowAnimation:UITableViewRowAnimationNone];
        });
    });
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [waTheme applyToView:self.view];
    self.tableView.backgroundView.backgroundColor = [waTheme backgroundColor];
    [self.tableView reloadData];
    [self refreshStorageStats];
    [self startPingMonitoring];
}

- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; [self.pingTimer invalidate]; self.pingTimer = nil; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return self.sections.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; return [self itemsInSection:section].count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView; return (section >= 0 && section < (NSInteger)self.sections.count) ? self.sections[section][@"title"] : nil; }

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    (void)tableView;
    waSettingsHeader *header = [[waSettingsHeader alloc] initWithReuseIdentifier:@"settings-header"];
    header.textLabel.text = (section >= 0 && section < (NSInteger)self.sections.count) ? self.sections[section][@"title"] : nil;
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

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"setting"];
    if (!cell) cell = [[waSettingsCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"setting"];

    waSettingsItem *item = [self itemAtIndexPath:path];
    BOOL busy = item.busy && item.busy();
    cell.textLabel.text = (busy && item.busyTitle.length) ? item.busyTitle : item.title;
    cell.textLabel.font = [waTheme mediumFontOfSize:17.0];
    cell.detailTextLabel.text = item.detail ? item.detail() : nil;
    cell.detailTextLabel.font = [waTheme secondaryRegularFontOfSize:13.0];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    NSInteger rowCount = (NSInteger)[self itemsInSection:path.section].count;
    ((waSettingsCell *)cell).sectionPosition = rowCount == 1 ? 3 : (path.row == 0 ? 0 : (path.row == rowCount - 1 ? 2 : 1));
    cell.userInteractionEnabled = !busy;
    cell.textLabel.enabled = !busy;

    if (busy) {
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
        [spinner startAnimating];
        cell.accessoryView = spinner;
    } else if (item.kind == waSettingsItemKindSwitch) {
        cell.accessoryView = [self reusableSwitchForItem:item atIndexPath:path];
    } else if (item.kind == waSettingsItemKindStepper) {
        UIStepper *stepper = [self reusableCrossfadeStepper];
        stepper.value = item.stepperValue ? item.stepperValue() : 0.0;
        // Container adds 10pt breathing room between "5s" and stepper
        UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 104.0, 29.0)];
        stepper.frame = CGRectMake(10.0, 0.0, 94.0, 29.0);
        [container addSubview:stepper];
        cell.accessoryView = container;
    } else if (item.kind == waSettingsItemKindPush || item.kind == waSettingsItemKindSheet) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    [waTheme applyToView:cell];
    return cell;
}

- (UISwitch *)reusableSwitchForItem:(waSettingsItem *)item atIndexPath:(NSIndexPath *)path {
    (void)item;
    NSInteger tag = path.section * 100 + path.row;
    UISwitch *toggle = self.switchCache[@(tag)];
    if (!toggle) {
        toggle = [[UISwitch alloc] init];
        toggle.tag = tag;
        [toggle addTarget:self action:@selector(settingChanged:) forControlEvents:UIControlEventValueChanged];
        [waTheme applyToView:toggle];
        if (!self.switchCache) self.switchCache = [NSMutableDictionary dictionary];
        self.switchCache[@(tag)] = toggle;
    }
    waSettingsItem *current = [self itemAtIndexPath:path];
    if (current.switchState) toggle.on = current.switchState();
    return toggle;
}

- (UIStepper *)reusableCrossfadeStepper {
    if (!self.crossfadeStepper) {
        UIStepper *stepper = [[UIStepper alloc] initWithFrame:CGRectMake(0.0, 0.0, 94.0, 29.0)];
        stepper.minimumValue = 0.0;
        stepper.maximumValue = 15.0;
        stepper.stepValue = 1.0;
        stepper.continuous = YES;
        stepper.autorepeat = YES;
        stepper.tintColor = [waTheme barColor];
        [stepper addTarget:self action:@selector(crossfadeStepperChanged:) forControlEvents:UIControlEventValueChanged];
        self.crossfadeStepper = stepper;
    }
    // Always follow theme (barColor changes per Dark purple/green etc)
    self.crossfadeStepper.tintColor = [waTheme barColor];
    return self.crossfadeStepper;
}

- (void)crossfadeStepperChanged:(UIStepper *)stepper {
    [waPreferences sharedPreferences].crossfadeDuration = stepper.value;
    [self reloadItem:self.crossfadeItem];
}

- (void)settingChanged:(UISwitch *)toggle {
    NSInteger section = toggle.tag / 100;
    NSInteger row = toggle.tag % 100;
    waSettingsItem *item = nil;
    NSArray *items = [self itemsInSection:section];
    if (row >= 0 && row < (NSInteger)items.count) item = items[row];
    if (item.switchSet) item.switchSet(toggle.isOn);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    waSettingsItem *item = [self itemAtIndexPath:path];
    if (!item || (item.busy && item.busy())) return;
    if (item.kind == waSettingsItemKindSwitch || item.kind == waSettingsItemKindStepper || item.kind == waSettingsItemKindInfo) return;
    if (item.select) item.select();
}

- (void)pairDiscordBridge {
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:@"Connect Wave RPC" delegate:self cancelButtonTitle:@"Cancel" destructiveButtonTitle:nil otherButtonTitles:@"Scan QR", @"Enter PIN", nil];
    sheet.tag = 800;
    [sheet showInView:self.view];
}

- (void)showManualDiscordPairing {
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Connect Wave RPC" message:@"Enter the six-digit PIN shown by the bridge." delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Connect", nil];
    alert.alertViewStyle = UIAlertViewStylePlainTextInput;
    alert.tag = 700;
    UITextField *field = [alert textFieldAtIndex:0];
    field.keyboardType = UIKeyboardTypeNumberPad;
    field.placeholder = @"123456";
    [alert show];
}

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (actionSheet.tag != 800) return;
    if (buttonIndex == 0) {
        waQRScannerViewController *scanner = [[waQRScannerViewController alloc] init];
        scanner.delegate = self;
        [self presentViewController:scanner animated:YES completion:nil];
    } else if (buttonIndex == 1) {
        [self showManualDiscordPairing];
    }
}

- (void)pairDiscordPIN:(NSString *)pin {
    __weak waSettingsViewController *weakSelf = self;
    [[waRPCClient sharedClient] pairWithPIN:pin completion:^(BOOL success, NSError *error) {
        waSettingsViewController *controller = weakSelf;
        if (!controller) return;
        [controller.tableView reloadData];
        if (!success) [controller showMessage:@"Bridge" message:error.localizedDescription];
    }];
}

- (void)qrScanner:(waQRScannerViewController *)scanner didScanPayload:(NSString *)payload {
    [self dismissViewControllerAnimated:YES completion:^{
        [[waRPCClient sharedClient] pairWithQRPayload:payload completion:^(BOOL success, NSError *error) {
            [self.tableView reloadData];
            if (!success) [self showMessage:@"Bridge" message:error.localizedDescription];
        }];
    }];
}

- (void)qrScannerDidCancel:(waQRScannerViewController *)scanner {
    [self dismissViewControllerAnimated:YES completion:^{
        [self showManualDiscordPairing];
    }];
}

- (void)selectProfile {
    if (![[waDeezerClient sharedClient] isAuthenticated]) {
        __weak waSettingsViewController *weakSelf = self;
        waDeezerLoginViewController *login = [[waDeezerLoginViewController alloc] initWithCompletion:^(NSError *error) {
            if (error && error.code != NSUserCancelledError) [weakSelf showMessage:@"Deezer Login" message:error.localizedDescription];
            if (!error) { [weakSelf.tableView reloadData]; }
        }];
        UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:login];
        [self presentViewController:navigation animated:YES completion:nil];
        return;
    }
    __weak waSettingsViewController *weakSelf = self;
    waAction *logout = [waAction actionWithIdentifier:@"settings.logout" title:@"Logout" destructive:YES availability:nil handler:^(id object) {
        (void)object;
        [[waDeezerClient sharedClient] logout]; [weakSelf.tableView reloadData];
    }];
    waAction *profile = [waAction actionWithIdentifier:@"settings.profile" title:@"View profile" handler:^(id object) {
        (void)object;
        [weakSelf.navigationController pushViewController:[[waProfileViewController alloc] initWithStyle:UITableViewStyleGrouped] animated:YES];
    }];
    [self presentSettingActions:@[profile, logout] title:@"Profile" object:nil];
}

- (void)selectLastFM {
    waLastFMClient *client = [waLastFMClient sharedClient];
    if (client.isAuthenticated) {
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Last.fm" message:@"Disconnect this Last.fm account?" delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Disconnect", nil];
        alert.tag = waAlertLastFMLogout;
        [alert show];
        return;
    }
    {
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Last.fm" message:@"Enter your Last.fm credentials" delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Sign In", nil];
        alert.alertViewStyle = UIAlertViewStyleLoginAndPasswordInput;
        alert.tag = 103;
        [alert show];
    }
}

- (void)startPingMonitoring { [self.pingTimer invalidate]; self.pingTimer = [NSTimer scheduledTimerWithTimeInterval:10.0 target:self selector:@selector(pingNow) userInfo:nil repeats:YES]; [self pingNow]; }
- (void)pingNow { if (self.pingInFlight) return; self.pingInFlight = YES; self.pingStatus = @"Checking…"; [self reloadItem:self.pingItem]; [[waAPIClient sharedClient] pingWithLatencyCompletion:^(NSTimeInterval milliseconds, NSError *error) { self.pingInFlight = NO; self.pingStatus = error ? @"Offline" : [NSString stringWithFormat:@"Online — %.0f ms", milliseconds]; [self reloadItem:self.pingItem]; }]; }

- (void)presentSettingActions:(NSArray *)actions title:(NSString *)title object:(id)object { [[waActions sharedActions] presentTitle:title actions:actions object:object fromViewController:self]; }
 - (void)showParallelDownloadOptions {
    __weak waSettingsViewController *weakSelf = self;
    NSUInteger cap = [[waPreferences sharedPreferences] waMaximumParallelCap];
    NSMutableArray *actions = [NSMutableArray array];
    NSArray *options = cap <= 2 ? @[@1, @2] : @[@1, @3, @5];
    for (NSNumber *n in options) {
        NSUInteger v = n.unsignedIntegerValue;
        NSString *title = [NSString stringWithFormat:@"%lu%@", (unsigned long)v, v==cap ? @" (max)" : @""];
        NSString *ident = [NSString stringWithFormat:@"settings.downloads.%lu", (unsigned long)v];
        [actions addObject:[waAction actionWithIdentifier:ident title:title handler:^(id object) {
            (void)object; waSettingsViewController *controller = weakSelf; if (!controller) return;
            [waPreferences sharedPreferences].maximumParallelDownloads = v;
            [waDownloadManager sharedManager].maximumParallelDownloads = v;
            [controller.tableView reloadData];
        }]];
    }
    [self presentSettingActions:actions title:@"Maximum parallel downloads" object:nil];
}
- (void)showThemeOptions { [self.navigationController pushViewController:[[waThemeViewController alloc] initWithStyle:UITableViewStyleGrouped] animated:YES]; }
- (void)showSleepOptions {
    __weak waSettingsViewController *weakSelf = self;
    NSMutableArray *actions = [NSMutableArray array];
    NSArray *options = @[@[@"Off", @0], @[@"15 minutes", @900], @[@"30 minutes", @1800], @[@"45 minutes", @2700], @[@"60 minutes", @3600]];
    for (NSArray *option in options) {
        NSString *title = option[0];
        NSTimeInterval interval = [option[1] doubleValue];
        [actions addObject:[waAction actionWithIdentifier:[@"settings.sleep." stringByAppendingString:title] title:title handler:^(id object) {
            (void)object;
            if (interval <= 0.0) [[waAudioPlayer sharedPlayer] cancelSleepTimer];
            else [[waAudioPlayer sharedPlayer] setSleepTimerWithInterval:interval];
            [weakSelf reloadItem:weakSelf.sleepItem];
        }]];
    }
    NSTimeInterval remaining = [[waAudioPlayer sharedPlayer] sleepTimeRemaining];
    NSString *title = remaining > 0.0 ? [NSString stringWithFormat:@"Sleep Timer (%d:%02d left)", (int)(remaining / 60.0), ((int)remaining) % 60] : @"Sleep Timer";
    [self presentSettingActions:actions title:title object:nil];
}
- (void)exportLog {
    NSArray *entries = [[waDebugLog sharedLog] entries];
    NSString *body = [entries isKindOfClass:[NSArray class]] && entries.count ? [entries componentsJoinedByString:@"\n"] : @"wave.log is empty.";
    UIActivityViewController *controller = [[UIActivityViewController alloc] initWithActivityItems:@[body] applicationActivities:nil];
    controller.excludedActivityTypes = @[UIActivityTypePrint, UIActivityTypeAssignToContact, UIActivityTypeSaveToCameraRoll];
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        UIPopoverController *popover = [[UIPopoverController alloc] initWithContentViewController:controller];
        UIView *view = self.view;
        [popover presentPopoverFromRect:CGRectMake(view.bounds.size.width / 2.0, view.bounds.size.height / 4.0, 1.0, 1.0) inView:view permittedArrowDirections:UIPopoverArrowDirectionAny animated:YES];
        objc_setAssociatedObject(controller, "waExportPopover", popover, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        [self presentViewController:controller animated:YES completion:nil];
    }
}
- (void)showDeezerQualityOptions { __weak waSettingsViewController *weakSelf = self; [self presentSettingActions:@[[waAction actionWithIdentifier:@"settings.quality.128" title:@"MP3 128 kbps" handler:^(id object) { (void)object; weakSelf ? ([waPreferences sharedPreferences].deezerQuality = 0, [weakSelf.tableView reloadData]) : (void)0; }], [waAction actionWithIdentifier:@"settings.quality.320" title:@"MP3 320 kbps" handler:^(id object) { (void)object; weakSelf ? ([waPreferences sharedPreferences].deezerQuality = 1, [weakSelf.tableView reloadData]) : (void)0; }], [waAction actionWithIdentifier:@"settings.quality.lossless" title:@"Lossless (FLAC direct)" handler:^(id object) { (void)object; weakSelf ? ([waPreferences sharedPreferences].deezerQuality = 2, [weakSelf.tableView reloadData]) : (void)0; }]] title:@"Deezer quality" object:nil]; }
- (void)showDownloadQualityOptions { __weak waSettingsViewController *weakSelf = self; [self presentSettingActions:@[[waAction actionWithIdentifier:@"settings.downloadQuality.128" title:@"MP3 128 kbps" handler:^(id object) { (void)object; [waPreferences sharedPreferences].downloadQuality = 0; [weakSelf.tableView reloadData]; }], [waAction actionWithIdentifier:@"settings.downloadQuality.320" title:@"MP3 320 kbps" handler:^(id object) { (void)object; [waPreferences sharedPreferences].downloadQuality = 1; [weakSelf.tableView reloadData]; }], [waAction actionWithIdentifier:@"settings.downloadQuality.lossless" title:@"Lossless (FLAC direct)" handler:^(id object) { (void)object; [waPreferences sharedPreferences].downloadQuality = 2; [weakSelf.tableView reloadData]; }]] title:@"Download quality" object:nil]; }
- (void)alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)index {
    if (index != 1) return;
    if (alert.tag == 700) {
        NSString *pin = [[alert textFieldAtIndex:0] text];
        [self pairDiscordPIN:pin];
        return;
    }
    if (alert.tag == waAlertLastFMLogout) {
        [[waLastFMClient sharedClient] logout];
        [self.tableView reloadData];
        return;
    }
    if (alert.tag == 103) {
        NSString *username = [alert textFieldAtIndex:0].text;
        NSString *password = [alert textFieldAtIndex:1].text;
        [[waLastFMClient sharedClient] loginWithUsername:username password:password completion:^(NSError *error) {
            if (error) [self showMessage:@"Last.fm" message:error.localizedDescription];
            else { [self.tableView reloadData]; [self showMessage:@"Last.fm" message:@"Connected."]; }
        }];
        return;
    }
    [self.tableView reloadData];
}

- (void)showMessage:(NSString *)title message:(NSString *)message { [[[UIAlertView alloc] initWithTitle:title message:message delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show]; }
- (void)rpcStateDidChange:(NSNotification *)notification { (void)notification; if (self.view.window) [self.tableView reloadData]; }
- (void)themeDidChange:(NSNotification *)notification {
    (void)notification;
    self.tableView.backgroundColor = [waTheme backgroundColor];
    self.tableView.backgroundView.backgroundColor = [waTheme backgroundColor];
    if (self.view.window) [self.tableView reloadData];
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
@end
