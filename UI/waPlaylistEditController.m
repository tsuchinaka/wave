#import "waPlaylistEditController.h"
#import "waSession.h"

@interface waPlaylistEditController () <UITextFieldDelegate, UIAlertViewDelegate>
@property (nonatomic, strong) waTrack *track;
@property (nonatomic, strong) NSArray *playlists;
@property (nonatomic, strong) UITextField *nameField;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation waPlaylistEditController

- (id)initWithTrack:(waTrack *)track {
    if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
        _track = track;
        _playlists = [NSArray array];
        self.title = @"Playlists";
    }
    return self;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return orientation != UIInterfaceOrientationPortraitUpsideDown;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = [UIColor groupTableViewBackgroundColor];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                           target:self
                                                                                           action:@selector(close)];
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 320.0, 54.0)];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.nameField = [[UITextField alloc] initWithFrame:CGRectMake(12.0, 11.0, 268.0, 31.0)];
    self.nameField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.nameField.borderStyle = UITextBorderStyleRoundedRect;
    self.nameField.placeholder = @"New Playlist Name";
    self.nameField.font = [UIFont systemFontOfSize:17.0];
    self.nameField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.nameField.returnKeyType = UIReturnKeyDone;
    self.nameField.delegate = self;
    [header addSubview:self.nameField];
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    self.spinner.hidesWhenStopped = YES;
    self.spinner.frame = CGRectMake(288.0, 16.0, 20.0, 20.0);
    self.spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [header addSubview:self.spinner];
    self.tableView.tableHeaderView = header;
    [self reload];
}

- (void)close {
    [self dismissModalViewControllerAnimated:YES];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    [self createPlaylist];
    return YES;
}

- (void)reload {
    [self.spinner startAnimating];
    __weak waPlaylistEditController *weakSelf = self;
    [[waSession shared] userPlaylistsWithCompletion:^(NSArray *playlists, NSError *error) {
        waPlaylistEditController *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.spinner stopAnimating];
        if (error) return;
        NSMutableArray *clean = [NSMutableArray array];
        for (id obj in playlists) if ([obj isKindOfClass:[waPlaylist class]]) [clean addObject:obj];
        strongSelf.playlists = clean;
        [strongSelf.tableView reloadData];
    }];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return (NSInteger)self.playlists.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *kID = @"playlist.pick";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kID];
        cell.textLabel.font = [UIFont boldSystemFontOfSize:16.0];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:13.0];
        cell.detailTextLabel.textColor = [UIColor grayColor];
    }
    waPlaylist *playlist = [self.playlists objectAtIndex:(NSUInteger)indexPath.row];
    cell.textLabel.text = playlist.title;
    cell.detailTextLabel.text = playlist.trackCount > 0 ? [NSString stringWithFormat:@"%ld songs", (long)playlist.trackCount] : @"Playlist";
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    waPlaylist *playlist = [self.playlists objectAtIndex:(NSUInteger)indexPath.row];
    if (self.track) {
        [self.spinner startAnimating];
        __weak waPlaylistEditController *weakSelf = self;
        [[waSession shared] addTrack:self.track toPlaylist:playlist completion:^(BOOL ok, NSError *error) {
            [weakSelf.spinner stopAnimating];
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:ok ? @"Added" : @"Playlist"
                                                            message:ok ? @"Song added." : error.localizedDescription
                                                           delegate:nil
                                                  cancelButtonTitle:@"OK"
                                                  otherButtonTitles:nil];
            [alert show];
            if (ok) [weakSelf dismissModalViewControllerAnimated:YES];
        }];
    }
}

- (void)createPlaylist {
    NSString *name = [self.nameField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!name.length) return;
    [self.nameField resignFirstResponder];
    [self.spinner startAnimating];
    __weak waPlaylistEditController *weakSelf = self;
    [[waSession shared] createPlaylistNamed:name completion:^(waPlaylist *playlist, NSError *error) {
        waPlaylistEditController *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (error || !playlist) {
            [strongSelf.spinner stopAnimating];
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Playlist"
                                                            message:error.localizedDescription
                                                           delegate:nil
                                                  cancelButtonTitle:@"OK"
                                                  otherButtonTitles:nil];
            [alert show];
            return;
        }
        if (strongSelf.track) {
            [[waSession shared] addTrack:strongSelf.track toPlaylist:playlist completion:^(BOOL ok, NSError *addError) {
                (void)ok; (void)addError;
                [strongSelf.spinner stopAnimating];
                [strongSelf dismissModalViewControllerAnimated:YES];
            }];
        } else {
            [strongSelf.spinner stopAnimating];
            [strongSelf reload];
        }
    }];
}

@end
