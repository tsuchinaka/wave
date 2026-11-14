#import "waDiscographyController.h"
#import "waDetailController.h"
#import "waSession.h"
#import "waPlayer.h"
#import "../Skin/waCell.h"

@interface waDiscographyController ()
@property (nonatomic, strong) waArtist *artist;
@property (nonatomic, strong) NSArray *sectionTitles;
@property (nonatomic, strong) NSArray *sectionAlbums;
@end

@implementation waDiscographyController

- (id)initWithArtist:(waArtist *)artist {
    if ((self = [super initWithGroupedStyle:YES])) {
        _artist = artist;
        self.title = @"Discography";
        self.emptyTitle = @"Discography";
        self.emptyMessage = @"No albums.";
        _sectionTitles = [NSArray array];
        _sectionAlbums = [NSArray array];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = [UIColor groupTableViewBackgroundColor];
    [self reload];
}

- (NSString *)albumYear:(waAlbum *)album {
    if (album.releaseDate.length >= 4) return [album.releaseDate substringToIndex:4];
    return @"";
}

- (NSString *)sectionKeyForAlbum:(waAlbum *)album {
    NSString *type = album.recordType.length ? album.recordType : @"album";
    if ([type isEqualToString:@"ep"]) return @"ep";
    if ([type isEqualToString:@"single"]) return @"single";
    if ([type isEqualToString:@"compile"]) return @"compile";
    return @"album";
}

- (NSString *)titleForKey:(NSString *)key {
    if ([key isEqualToString:@"ep"]) return @"EPs";
    if ([key isEqualToString:@"single"]) return @"Singles";
    if ([key isEqualToString:@"compile"]) return @"Compilations";
    return @"Albums";
}

- (NSArray *)sortedAlbums:(NSArray *)albums {
    return [albums sortedArrayUsingComparator:^NSComparisonResult(waAlbum *a, waAlbum *b) {
        NSString *da = a.releaseDate.length ? a.releaseDate : @"";
        NSString *db = b.releaseDate.length ? b.releaseDate : @"";
        NSComparisonResult order = [db compare:da];
        if (order != NSOrderedSame) return order;
        NSString *ta = a.title.length ? a.title : @"";
        NSString *tb = b.title.length ? b.title : @"";
        return [ta localizedCaseInsensitiveCompare:tb];
    }];
}

- (void)reload {
    [self setLoading:YES];
    __weak waDiscographyController *weakSelf = self;
    [[waSession shared] artistAlbums:self.artist.identifier completion:^(NSArray *albums, NSError *error) {
        waDiscographyController *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf setLoading:NO];
        if (error && !albums.count) {
            [strongSelf showError:error retry:@selector(reload)];
            return;
        }
        NSArray *keys = [NSArray arrayWithObjects:@"album", @"ep", @"single", @"compile", nil];
        NSMutableDictionary *groups = [NSMutableDictionary dictionary];
        for (NSString *key in keys) groups[key] = [NSMutableArray array];
        for (id obj in albums) {
            if (![obj isKindOfClass:[waAlbum class]]) continue;
            NSString *key = [strongSelf sectionKeyForAlbum:obj];
            NSMutableArray *list = groups[key];
            if (!list) {
                list = [NSMutableArray array];
                groups[key] = list;
            }
            [list addObject:obj];
        }
        NSMutableArray *titles = [NSMutableArray array];
        NSMutableArray *sections = [NSMutableArray array];
        for (NSString *key in keys) {
            NSArray *list = [strongSelf sortedAlbums:groups[key]];
            if (!list.count) continue;
            [titles addObject:[strongSelf titleForKey:key]];
            [sections addObject:list];
        }
        strongSelf.sectionTitles = titles;
        strongSelf.sectionAlbums = sections;
        strongSelf.tableView.backgroundView = nil;
        [strongSelf.tableView reloadData];
        if (!titles.count) [strongSelf showEmpty:@"Discography" message:@"No albums."];
    }];
}

- (waAlbum *)albumAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section < 0 || indexPath.section >= (NSInteger)self.sectionAlbums.count) return nil;
    NSArray *list = [self.sectionAlbums objectAtIndex:(NSUInteger)indexPath.section];
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)list.count) return nil;
    return [list objectAtIndex:(NSUInteger)indexPath.row];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return (NSInteger)self.sectionTitles.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (section < 0 || section >= (NSInteger)self.sectionTitles.count) return nil;
    NSArray *list = [self.sectionAlbums objectAtIndex:(NSUInteger)section];
    return [NSString stringWithFormat:@"%@ · %ld", [self.sectionTitles objectAtIndex:(NSUInteger)section], (long)list.count];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (section < 0 || section >= (NSInteger)self.sectionAlbums.count) return 0;
    return (NSInteger)[[self.sectionAlbums objectAtIndex:(NSUInteger)section] count];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; (void)indexPath;
    return 58.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    waAlbum *album = [self albumAtIndexPath:indexPath];
    waCell *cell = [waCell cellForTable:tableView subtitle:YES];
    [cell setItem:album];
    NSMutableArray *bits = [NSMutableArray array];
    NSString *year = [self albumYear:album];
    if (year.length) [bits addObject:year];
    if (album.version.length) [bits addObject:album.version];
    else if (album.recordType.length && ![album.recordType isEqualToString:@"album"]) [bits addObject:[album.recordType uppercaseString]];
    if (album.trackCount > 0) [bits addObject:[NSString stringWithFormat:@"%ld songs", (long)album.trackCount]];
    if (bits.count) cell.detailTextLabel.text = [bits componentsJoinedByString:@" · "];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    [cell setNeedsLayout];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    waAlbum *album = [self albumAtIndexPath:indexPath];
    if (!album) return;
    [self.navigationController pushViewController:[[waDetailController alloc] initWithAlbum:album] animated:YES];
}

@end
