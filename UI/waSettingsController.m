#import "waSettingsController.h"
#import "waEQController.h"
#import "waStorageController.h"
#import "waLogsController.h"
#import "waAboutController.h"
#import "waSession.h"
#import "waProfileController.h"
#import "waPlayer.h"
#import "waLastFM.h"
#import "waSkin.h"

enum {
    waSettingsSheetPlayback = 1,
    waSettingsSheetDownload = 2,
    waSettingsSheetLastFM = 3,
    waSettingsAlertLogout = 10,
    waSettingsAlertLastFMLogin = 11
};

enum {
    waSettingsSectionAccount = 0,
    waSettingsSectionPlayback,
    waSettingsSectionDownloads,
    waSettingsSectionStorage,
    waSettingsSectionDiagnostics,
    waSettingsSectionBridge
};

static NSString * const waKeyPlaybackQuality = @"wave.playbackQuality";
static NSString * const waKeyCrossfade = @"wave.crossfade";
static NSString * const waKeyCrossfadeDuration = @"wave.crossfadeDuration";
static NSString * const waKeyCompressor = @"wave.compressor";
static NSString * const waKeyDownloadQuality = @"wave.downloadQuality";
static NSString * const waKeyDownloadParallel = @"wave.downloadParallel";
static NSString * const waKeyWifiOnly = @"wave.wifiOnly";
static NSString * const waKeyDiscordRPC = @"wave.discordRPC";

@interface waSettingsController () <UIActionSheetDelegate, UIAlertViewDelegate>
@property (nonatomic, strong) UISwitch *crossfadeSwitch;
@property (nonatomic, strong) UISwitch *compressorSwitch;
@property (nonatomic, strong) UISwitch *wifiSwitch;
@property (nonatomic, strong) UISwitch *rpcSwitch;
@property (nonatomic, strong) UISwitch *lastFMSwitch;
@property (nonatomic, strong) UIStepper *crossfadeStepper;
@property (nonatomic, strong) UIStepper *parallelStepper;
@property (nonatomic, copy) NSArray *sheetQualities;
@property (nonatomic, assign) NSInteger sheetKind;
@end

@implementation waSettingsController

- (id)init {
    return [self initWithStyle:UITableViewStyleGrouped];
}

- (id)initWithStyle:(UITableViewStyle)style {
    if ((self = [super initWithStyle:style])) {
        self.title = @"Settings";
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    (void)orientation;
    return YES;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    NSDictionary *defaults = [NSDictionary dictionaryWithObjectsAndKeys:
                              [NSNumber numberWithInteger:0], waKeyPlaybackQuality,
                              [NSNumber numberWithBool:NO], waKeyCrossfade,
                              [NSNumber numberWithDouble:0.0], waKeyCrossfadeDuration,
                              [NSNumber numberWithBool:NO], waKeyCompressor,
                              [NSNumber numberWithInteger:0], waKeyDownloadQuality,
                              [NSNumber numberWithInteger:2], waKeyDownloadParallel,
                              [NSNumber numberWithBool:YES], waKeyWifiOnly,
                              [NSNumber numberWithBool:NO], waKeyDiscordRPC,
                              nil];
    [[NSUserDefaults standardUserDefaults] registerDefaults:defaults];

    [waSkin styleTableView:self.tableView grouped:YES];
    self.tableView.backgroundColor = [UIColor groupTableViewBackgroundColor];

    self.crossfadeSwitch = [self makeSwitch:@selector(crossfadeChanged:)];
    self.compressorSwitch = [self makeSwitch:@selector(compressorChanged:)];
    self.wifiSwitch = [self makeSwitch:@selector(wifiChanged:)];
    self.rpcSwitch = [self makeSwitch:@selector(rpcChanged:)];
    self.lastFMSwitch = [self makeSwitch:@selector(lastFMScrobbleChanged:)];

    self.crossfadeStepper = [[UIStepper alloc] initWithFrame:CGRectZero];
    self.crossfadeStepper.minimumValue = 0.0;
    self.crossfadeStepper.maximumValue = 12.0;
    self.crossfadeStepper.stepValue = 1.0;
    self.crossfadeStepper.autorepeat = YES;
    [self.crossfadeStepper addTarget:self action:@selector(crossfadeStep:) forControlEvents:UIControlEventValueChanged];

    self.parallelStepper = [[UIStepper alloc] initWithFrame:CGRectZero];
    self.parallelStepper.minimumValue = 1.0;
    self.parallelStepper.maximumValue = 5.0;
    self.parallelStepper.stepValue = 1.0;
    [self.parallelStepper addTarget:self action:@selector(parallelStep:) forControlEvents:UIControlEventValueChanged];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionDidChange:) name:waSessionDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionDidChange:) name:waSessionAuthDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionDidChange:) name:waLastFMDidChangeNotification object:nil];
}

- (UISwitch *)makeSwitch:(SEL)action {
    UISwitch *control = [[UISwitch alloc] initWithFrame:CGRectZero];
    [waSkin styleSwitch:control];
    [control addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    return control;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (self.navigationController) [waSkin styleNavigationBar:self.navigationController.navigationBar];
    [self syncControls];
    [self.tableView reloadData];
}

- (void)sessionDidChange:(NSNotification *)note {
    (void)note;
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:@selector(sessionDidChange:) withObject:note waitUntilDone:NO];
        return;
    }
    [self.tableView reloadData];
}

- (BOOL)hasBridge {
    Class klass = NSClassFromString(@"waRPCClient");
    return klass && [klass respondsToSelector:@selector(sharedClient)];
}

- (id)rpcClient {
    Class klass = NSClassFromString(@"waRPCClient");
    SEL selector = NSSelectorFromString(@"sharedClient");
    if (!klass || ![klass respondsToSelector:selector]) return nil;
    IMP imp = [klass methodForSelector:selector];
    if (!imp) return nil;
    id (*func)(id, SEL) = (id (*)(id, SEL))imp;
    return func(klass, selector);
}

- (NSUserDefaults *)defaults {
    return [NSUserDefaults standardUserDefaults];
}

- (void)syncControls {
    NSUserDefaults *defaults = [self defaults];
    waPlayer *player = [waPlayer shared];
    waSession *session = [waSession shared];

    waQuality quality = session.preferredQuality;
    if (quality > session.maximumQuality) quality = session.maximumQuality;
    [defaults setInteger:quality forKey:waKeyPlaybackQuality];

    self.crossfadeSwitch.on = player.crossfadeEnabled;
    self.crossfadeStepper.value = MIN(12.0, MAX(0.0, player.crossfadeDuration));
    self.compressorSwitch.on = [player compressorEnabled];
    self.wifiSwitch.on = [defaults boolForKey:waKeyWifiOnly];
    NSInteger parallel = [defaults integerForKey:waKeyDownloadParallel];
    if (parallel < 1) parallel = 2;
    self.parallelStepper.value = (double)parallel;

    id rpc = [self rpcClient];
    if (rpc) {
        BOOL on = NO;
        @try { on = [[rpc valueForKey:@"showInDiscord"] boolValue]; }
        @catch (NSException *exception) { on = [defaults boolForKey:waKeyDiscordRPC]; (void)exception; }
        self.rpcSwitch.on = on;
    }
}

- (NSArray *)allowedQualities {
    waQuality max = [waSession shared].maximumQuality;
    NSMutableArray *list = [NSMutableArray array];
    for (NSInteger quality = 0; quality <= (NSInteger)max; quality++) {
        [list addObject:[NSNumber numberWithInteger:quality]];
    }
    if (!list.count) [list addObject:[NSNumber numberWithInteger:0]];
    return list;
}

- (NSString *)qualityTitle:(waQuality)quality {
    NSString *name = [[waSession shared] qualityName:quality];
    return name.length ? name : [NSString stringWithFormat:@"Quality %d", (int)quality];
}

- (UITableViewCell *)valueCell:(NSString *)reuse {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:reuse];
        [waSkin applyValueCellFonts:cell];
    }
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleBlue;
    cell.textLabel.textColor = [waSkin primaryText];
    cell.detailTextLabel.textColor = [waSkin secondaryText];
    cell.detailTextLabel.text = nil;
    return cell;
}

- (NSInteger)accountLastFMRow {
    return [waSession shared].authenticated ? 2 : 1;
}

- (NSInteger)accountScrobbleRow {
    if (![waLastFM shared].signedIn) return NSNotFound;
    return [self accountLastFMRow] + 1;
}

- (NSInteger)accountLogoutRow {
    if (![waSession shared].authenticated) return NSNotFound;
    NSInteger row = 3;
    if ([waLastFM shared].signedIn) row += 1;
    return row;
}

- (UITableViewCell *)lastFMAccountCell {
    waLastFM *fm = [waLastFM shared];
    UITableViewCell *cell = [self valueCell:@"account.lastfm"];
    cell.textLabel.text = @"Last.fm";
    if (fm.signedIn) {
        cell.detailTextLabel.text = fm.username.length ? fm.username : @"Signed In";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        cell.detailTextLabel.text = @"Not Signed In";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return [self hasBridge] ? 6 : 5;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (section == waSettingsSectionAccount) {
        NSInteger rows = [waSession shared].authenticated ? 3 : 1;
        rows += 1;
        if ([waLastFM shared].signedIn) rows += 1;
        return rows;
    }
    if (section == waSettingsSectionPlayback) return 5;
    if (section == waSettingsSectionDownloads) return 3;
    if (section == waSettingsSectionStorage) return 1;
    if (section == waSettingsSectionDiagnostics) return 2;
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (section == waSettingsSectionAccount) return @"Account";
    if (section == waSettingsSectionPlayback) return @"Playback";
    if (section == waSettingsSectionDownloads) return @"Downloads";
    if (section == waSettingsSectionStorage) return @"Storage";
    if (section == waSettingsSectionDiagnostics) return @"Diagnostics";
    return @"Bridge";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    NSInteger section = indexPath.section;
    NSInteger row = indexPath.row;
    NSUserDefaults *defaults = [self defaults];
    waSession *session = [waSession shared];
    waPlayer *player = [waPlayer shared];

    if (section == waSettingsSectionAccount) {
        if (row == [self accountLastFMRow]) return [self lastFMAccountCell];
        if (row == [self accountScrobbleRow]) {
            UITableViewCell *cell = [self valueCell:@"account.lastfm.switch"];
            cell.textLabel.text = @"Scrobbling";
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.accessoryView = self.lastFMSwitch;
            self.lastFMSwitch.on = [waLastFM shared].scrobblingEnabled;
            return cell;
        }
        if (!session.authenticated) {
            UITableViewCell *cell = [self valueCell:@"account"];
            cell.textLabel.text = @"Account";
            cell.detailTextLabel.text = @"Not Signed In";
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }
        if (row == 0) {
            UITableViewCell *cell = [self valueCell:@"account"];
            cell.textLabel.text = @"Name";
            cell.detailTextLabel.text = session.user.name.length ? session.user.name : @"-";
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }
        if (row == 1) {
            UITableViewCell *cell = [self valueCell:@"account"];
            cell.textLabel.text = @"Manage";
            cell.detailTextLabel.text = session.user.email.length ? session.user.email : nil;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
        UITableViewCell *cell = [self valueCell:@"account"];
        cell.textLabel.text = @"Log Out";
        cell.textLabel.textColor = [waSkin destructive];
        return cell;
    }

    if (section == waSettingsSectionPlayback) {
        if (row == 0) {
            UITableViewCell *cell = [self valueCell:@"playback"];
            cell.textLabel.text = @"Quality";
            cell.detailTextLabel.text = [self qualityTitle:session.preferredQuality];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
        if (row == 1) {
            UITableViewCell *cell = [self valueCell:@"playback-switch"];
            cell.textLabel.text = @"Crossfade";
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.accessoryView = self.crossfadeSwitch;
            self.crossfadeSwitch.on = player.crossfadeEnabled;
            return cell;
        }
        if (row == 2) {
            UITableViewCell *cell = [self valueCell:@"playback-step"];
            cell.textLabel.text = @"Crossfade Time";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0fs", self.crossfadeStepper.value];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.accessoryView = self.crossfadeStepper;
            return cell;
        }
        if (row == 3) {
            UITableViewCell *cell = [self valueCell:@"playback"];
            cell.textLabel.text = @"Equalizer";
            NSString *preset = [[waPlayer shared] equalizerPresetName];
            cell.detailTextLabel.text = preset.length ? preset : nil;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
        if (row == 4) {
            UITableViewCell *cell = [self valueCell:@"playback-switch"];
            cell.textLabel.text = @"Compressor";
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.accessoryView = self.compressorSwitch;
            self.compressorSwitch.on = [player compressorEnabled];
            return cell;
        }
    }

    if (section == waSettingsSectionDownloads) {
        if (row == 0) {
            UITableViewCell *cell = [self valueCell:@"downloads"];
            cell.textLabel.text = @"Quality";
            cell.detailTextLabel.text = [self qualityTitle:(waQuality)[defaults integerForKey:waKeyDownloadQuality]];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
        if (row == 1) {
            UITableViewCell *cell = [self valueCell:@"downloads-step"];
            cell.textLabel.text = @"Parallel Downloads";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f", self.parallelStepper.value];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.accessoryView = self.parallelStepper;
            return cell;
        }
        UITableViewCell *cell = [self valueCell:@"downloads-switch"];
        cell.textLabel.text = @"Wi-Fi Only";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.accessoryView = self.wifiSwitch;
        self.wifiSwitch.on = [defaults boolForKey:waKeyWifiOnly];
        return cell;
    }

    if (section == waSettingsSectionStorage) {
        UITableViewCell *cell = [self valueCell:@"storage"];
        cell.textLabel.text = @"Storage";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    if (section == waSettingsSectionDiagnostics) {
        UITableViewCell *cell = [self valueCell:@"diag"];
        if (row == 0) {
            cell.textLabel.text = @"Logs";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.textLabel.text = @"About";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        return cell;
    }

    UITableViewCell *cell = [self valueCell:@"bridge"];
    cell.textLabel.text = @"Discord RPC";
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryView = self.rpcSwitch;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSInteger section = indexPath.section;
    NSInteger row = indexPath.row;

    if (section == waSettingsSectionAccount) {
        if (row == [self accountLastFMRow]) {
            [self lastFMAccountTapped];
            return;
        }
        if (row == [self accountScrobbleRow]) return;
        if (![waSession shared].authenticated) return;
        if (row == 1) [self showManage];
        else if (row == [self accountLogoutRow]) [self confirmLogout];
        return;
    }
    if (section == waSettingsSectionPlayback) {
        if (row == 0) [self showQualitySheet:waSettingsSheetPlayback];
        else if (row == 3) {
            [self.navigationController pushViewController:[[waEQController alloc] init] animated:YES];
        }
        return;
    }
    if (section == waSettingsSectionDownloads && row == 0) {
        [self showQualitySheet:waSettingsSheetDownload];
        return;
    }
    if (section == waSettingsSectionStorage) {
        [self.navigationController pushViewController:[[waStorageController alloc] initWithStyle:UITableViewStyleGrouped] animated:YES];
        return;
    }
    if (section == waSettingsSectionDiagnostics) {
        if (row == 0) [self.navigationController pushViewController:[[waLogsController alloc] init] animated:YES];
        else [self.navigationController pushViewController:[[waAboutController alloc] initWithStyle:UITableViewStyleGrouped] animated:YES];
    }
}

- (void)showManage {
    [self.navigationController pushViewController:[[waProfileController alloc] init] animated:YES];
}

- (void)confirmLogout {
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Log Out" message:@"Sign out of this account?" delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Log Out", nil];
    alert.tag = waSettingsAlertLogout;
    [alert show];
}

- (void)lastFMAccountTapped {
    waLastFM *fm = [waLastFM shared];
    if (!fm.signedIn) {
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Last.fm"
                                                        message:@"Sign in to scrobble what you play."
                                                       delegate:self
                                              cancelButtonTitle:@"Cancel"
                                              otherButtonTitles:@"Sign In", nil];
        alert.alertViewStyle = UIAlertViewStyleLoginAndPasswordInput;
        alert.tag = waSettingsAlertLastFMLogin;
        [alert textFieldAtIndex:0].placeholder = @"Username";
        [alert textFieldAtIndex:1].placeholder = @"Password";
        [alert show];
        return;
    }
    NSString *title = fm.username.length ? fm.username : @"Last.fm";
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:title
                                                       delegate:self
                                              cancelButtonTitle:@"Cancel"
                                         destructiveButtonTitle:@"Log Out"
                                              otherButtonTitles:nil];
    sheet.tag = waSettingsSheetLastFM;
    UIView *host = self.tabBarController.view ?: (self.navigationController.view ?: self.view);
    [sheet showInView:host];
}

- (void)lastFMScrobbleChanged:(UISwitch *)sender {
    [[waLastFM shared] setScrobblingEnabled:sender.on];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (alertView.tag == waSettingsAlertLastFMLogin) {
        if (buttonIndex == alertView.cancelButtonIndex) return;
        NSString *username = [alertView textFieldAtIndex:0].text;
        NSString *password = [alertView textFieldAtIndex:1].text;
        __weak waSettingsController *weakSelf = self;
        [[waLastFM shared] loginWithUsername:username password:password completion:^(BOOL ok, NSError *error) {
            waSettingsController *strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.tableView reloadData];
            if (ok) return;
            NSString *message = error.localizedDescription.length ? error.localizedDescription : @"Could not sign in.";
            [[[UIAlertView alloc] initWithTitle:@"Last.fm" message:message delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
        }];
        return;
    }
    if (alertView.tag != waSettingsAlertLogout) return;
    if (buttonIndex == alertView.cancelButtonIndex) return;
    [[waSession shared] logout];
    [self.tableView reloadData];
}

- (void)showQualitySheet:(NSInteger)kind {
    self.sheetKind = kind;
    self.sheetQualities = [self allowedQualities];
    NSString *title = (kind == waSettingsSheetPlayback) ? @"Playback Quality" : @"Download Quality";
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:title delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
    for (NSNumber *number in self.sheetQualities) {
        [sheet addButtonWithTitle:[self qualityTitle:(waQuality)[number integerValue]]];
    }
    NSInteger cancel = [sheet addButtonWithTitle:@"Cancel"];
    sheet.cancelButtonIndex = cancel;
    sheet.tag = (int)kind;
    UIView *host = self.tabBarController.view ?: (self.navigationController.view ?: self.view);
    [sheet showInView:host];
}

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (buttonIndex == actionSheet.cancelButtonIndex) return;
    if (actionSheet.tag == waSettingsSheetLastFM) {
        if (buttonIndex == actionSheet.destructiveButtonIndex) [[waLastFM shared] logout];
        [self.tableView reloadData];
        return;
    }
    if (buttonIndex < 0 || buttonIndex >= (NSInteger)self.sheetQualities.count) return;
    waQuality quality = (waQuality)[[self.sheetQualities objectAtIndex:buttonIndex] integerValue];
    NSUserDefaults *defaults = [self defaults];
    if (actionSheet.tag == waSettingsSheetPlayback) {
        [waSession shared].preferredQuality = quality;
        [defaults setInteger:quality forKey:waKeyPlaybackQuality];
    } else {
        [defaults setInteger:quality forKey:waKeyDownloadQuality];
    }
    [defaults synchronize];
    [self.tableView reloadData];
}

#pragma mark - Controls

- (void)crossfadeChanged:(UISwitch *)sender {
    [waPlayer shared].crossfadeEnabled = sender.on;
    [[self defaults] setBool:sender.on forKey:waKeyCrossfade];
}

- (void)crossfadeStep:(UIStepper *)sender {
    [waPlayer shared].crossfadeDuration = sender.value;
    [[self defaults] setDouble:sender.value forKey:waKeyCrossfadeDuration];
    NSIndexPath *path = [NSIndexPath indexPathForRow:2 inSection:waSettingsSectionPlayback];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:path];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0fs", sender.value];
}

- (void)compressorChanged:(UISwitch *)sender {
    [[waPlayer shared] setCompressorEnabled:sender.on];
    [[self defaults] setBool:sender.on forKey:waKeyCompressor];
}

- (void)wifiChanged:(UISwitch *)sender {
    [[self defaults] setBool:sender.on forKey:waKeyWifiOnly];
}

- (void)parallelStep:(UIStepper *)sender {
    [[self defaults] setInteger:(NSInteger)sender.value forKey:waKeyDownloadParallel];
    NSIndexPath *path = [NSIndexPath indexPathForRow:1 inSection:waSettingsSectionDownloads];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:path];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f", sender.value];
}

- (void)rpcChanged:(UISwitch *)sender {
    [[self defaults] setBool:sender.on forKey:waKeyDiscordRPC];
    id client = [self rpcClient];
    if (!client) return;
    @try { [client setValue:[NSNumber numberWithBool:sender.on] forKey:@"showInDiscord"]; }
    @catch (NSException *exception) { (void)exception; }
}

@end
