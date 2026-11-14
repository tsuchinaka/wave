#import "waQueueController.h"
#import "waPlayer.h"
#import "../Skin/waCell.h"

@interface waQueueController ()
@property (nonatomic, strong) NSArray *tracks;
@end

@implementation waQueueController

- (id)init {
    return [self initWithStyle:UITableViewStylePlain];
}

- (id)initWithStyle:(UITableViewStyle)style {
    if ((self = [super initWithStyle:style])) {
        self.title = @"Queue";
        _tracks = [NSArray array];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = [UIColor whiteColor];
    self.tableView.rowHeight = 44.0;
    self.navigationItem.rightBarButtonItem = self.editButtonItem;
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:NULL];
    UIBarButtonItem *clear = [[UIBarButtonItem alloc] initWithTitle:@"Clear Queue" style:UIBarButtonItemStyleBordered target:self action:@selector(confirmClear)];
    self.toolbarItems = [NSArray arrayWithObjects:flex, clear, flex, nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(queueDidChange:) name:waPlayerQueueDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(trackDidChange:) name:waPlayerTrackDidChangeNotification object:nil];
    [self reloadQueue];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return orientation != UIInterfaceOrientationPortraitUpsideDown;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setToolbarHidden:NO animated:animated];
    [self reloadQueue];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.navigationController setToolbarHidden:YES animated:animated];
}

- (void)queueDidChange:(NSNotification *)note {
    (void)note;
    [self reloadQueue];
}

- (void)trackDidChange:(NSNotification *)note {
    (void)note;
    [self.tableView reloadData];
}

- (void)reloadQueue {
    self.tracks = [waPlayer shared].queue ? [waPlayer shared].queue : [NSArray array];
    [self.tableView reloadData];
}

- (void)confirmClear {
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Clear Queue"
                                                    message:@"Remove all songs?"
                                                   delegate:self
                                          cancelButtonTitle:@"Cancel"
                                          otherButtonTitles:@"Clear", nil];
    alert.tag = 1;
    [alert show];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (alertView.tag == 1 && buttonIndex == 1) {
        [[waPlayer shared] clearQueue];
        [self reloadQueue];
    }
}

#pragma mark - table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return [waPlayer shared].currentTrack ? 1 : 0;
    return (NSInteger)self.tracks.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return [waPlayer shared].currentTrack ? @"Now Playing" : nil;
    return self.tracks.count ? @"Up Next" : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    waCell *cell = [waCell cellForTable:tableView subtitle:YES];
    waTrack *track = nil;
    if (indexPath.section == 0) track = [waPlayer shared].currentTrack;
    else if (indexPath.row >= 0 && indexPath.row < (NSInteger)self.tracks.count) track = [self.tracks objectAtIndex:(NSUInteger)indexPath.row];
    if ([track isKindOfClass:[waTrack class]]) {
        [cell setTrack:track showAlbum:YES];
        if (indexPath.section == 1 && (NSUInteger)indexPath.row == [waPlayer shared].index) {
            cell.accessoryType = UITableViewCellAccessoryCheckmark;
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1) return;
    [[waPlayer shared] jumpToIndex:(NSUInteger)indexPath.row];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    return indexPath.section == 1;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (style != UITableViewCellEditingStyleDelete) return;
    [[waPlayer shared] removeAtIndex:(NSUInteger)indexPath.row];
    self.tracks = [waPlayer shared].queue ? [waPlayer shared].queue : [NSArray array];
    [tableView deleteRowsAtIndexPaths:[NSArray arrayWithObject:indexPath] withRowAnimation:UITableViewRowAnimationFade];
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 1 && tableView.editing;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)source toIndexPath:(NSIndexPath *)destination {
    if (source.section != 1 || destination.section != 1) return;
    [[waPlayer shared] moveFrom:(NSUInteger)source.row to:(NSUInteger)destination.row];
    self.tracks = [waPlayer shared].queue ? [waPlayer shared].queue : [NSArray array];
}

@end
