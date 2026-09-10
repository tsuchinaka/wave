#import "waListViewController.h"
#import "../Models/waMediaItem.h"

@interface waListViewController (SearchPrivate)
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, copy) NSString *query;
@property (nonatomic, strong) NSArray *sections;
@property (nonatomic, strong) NSArray *allSections;
@property (nonatomic, strong) NSArray *offlineItems;
@property (nonatomic, strong) NSArray *hasMore;
@property (nonatomic, strong) NSArray *displaySections;
@property (nonatomic, assign) NSInteger selectedFilter;
@property (nonatomic, assign) NSUInteger searchGeneration;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
- (void)setLoading:(BOOL)loading;
- (void)rebuildDisplaySections;
- (NSArray *)rankedSearchItems:(NSArray *)items query:(NSString *)query type:(NSInteger)type;
- (BOOL)hasResults;
@end
