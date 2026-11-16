#import "waResultsController.h"
#import "waSession.h"
#import "waPlayer.h"
#import "waRootController.h"
#import "waDetailController.h"
#import "waRowActions.h"
#import "../Skin/waCell.h"

@interface waResultsController ()
@property (nonatomic, copy) NSString *query;
@property (nonatomic, assign) waSearchKind kind;
@property (nonatomic, strong) NSMutableArray *items;
@property (nonatomic, assign) NSUInteger total;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, assign) NSUInteger generation;
@end

@implementation waResultsController

- (id)initWithQuery:(NSString *)query kind:(waSearchKind)kind title:(NSString *)title {
    if ((self = [super initWithGroupedStyle:YES])) {
        _query = [query copy];
        _kind = kind;
        _items = [NSMutableArray array];
        self.title = title.length ? title : @"Results";
        self.emptyTitle = @"No Results";
        self.emptyMessage = @"Nothing matched.";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = [UIColor groupTableViewBackgroundColor];
    [self loadPage];
}

- (void)loadPage {
    if (self.loading || !self.query.length) return;
    if (self.total && self.items.count >= self.total) return;
    self.loading = YES;
    NSUInteger generation = ++self.generation;
    __weak waResultsController *weakSelf = self;
    [[waSession shared] search:self.query kind:self.kind index:self.items.count completion:^(NSArray *items, NSUInteger total, NSError *error) {
        waResultsController *strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf.generation) return;
        strongSelf.loading = NO;
        if (error && !strongSelf.items.count) {
            [strongSelf showError:error retry:@selector(loadPage)];
            return;
        }
        strongSelf.total = total;
        for (id item in items) {
            if ([item isKindOfClass:[waItem class]]) [strongSelf.items addObject:item];
        }
        strongSelf.tableView.backgroundView = nil;
        if (!strongSelf.items.count) {
            [strongSelf showEmpty:strongSelf.emptyTitle message:strongSelf.emptyMessage];
            return;
        }
        [strongSelf.tableView reloadData];
    }];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (!self.items.count || self.loading) return;
    CGFloat offset = scrollView.contentOffset.y + CGRectGetHeight(scrollView.bounds);
    if (offset >= scrollView.contentSize.height - 240.0) [self loadPage];
}

#pragma mark - table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)section;
    return (NSInteger)self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)self.items.count) return [waCell cellForTable:tableView];
    waItem *item = [self.items objectAtIndex:(NSUInteger)indexPath.row];
    waCell *cell = [waCell cellForTable:tableView subtitle:YES];
    if ([item isKindOfClass:[waTrack class]]) [cell setTrack:(waTrack *)item showAlbum:YES];
    else [cell setItem:item];
    cell.indexText = nil;
    cell.accessoryType = [item isKindOfClass:[waTrack class]] ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (NSDictionary *)contextMenuForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)self.items.count) return nil;
    waItem *item = [self.items objectAtIndex:(NSUInteger)indexPath.row];
    NSArray *tracks = [item isKindOfClass:[waTrack class]] ? self.items : nil;
    return [waRowActions menuForItem:item tracks:tracks presenter:self];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)self.items.count) return;
    waItem *item = [self.items objectAtIndex:(NSUInteger)indexPath.row];
    if ([item isKindOfClass:[waTrack class]]) {
        [[waPlayer shared] playTracks:self.items startAt:(NSUInteger)indexPath.row context:self.title];
        [[waRootController shared] showPlayer];
        return;
    }
    if ([item isKindOfClass:[waAlbum class]]) {
        [self.navigationController pushViewController:[[waDetailController alloc] initWithAlbum:(waAlbum *)item] animated:YES];
    } else if ([item isKindOfClass:[waArtist class]]) {
        [self.navigationController pushViewController:[[waDetailController alloc] initWithArtist:(waArtist *)item] animated:YES];
    } else if ([item isKindOfClass:[waPlaylist class]]) {
        [self.navigationController pushViewController:[[waDetailController alloc] initWithPlaylist:(waPlaylist *)item] animated:YES];
    }
}

@end
