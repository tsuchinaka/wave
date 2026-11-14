#import "waAboutController.h"

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
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? 4 : 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? nil : @"Credits";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *kID = @"about.cell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:kID];
        cell.textLabel.font = [UIFont systemFontOfSize:17.0];
        cell.detailTextLabel.textColor = [UIColor grayColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Name";
            NSString *name = [info objectForKey:@"CFBundleDisplayName"];
            if (![name isKindOfClass:[NSString class]] || !name.length) name = [info objectForKey:@"CFBundleName"];
            cell.detailTextLabel.text = ([name isKindOfClass:[NSString class]] && name.length) ? name : @"Wave";
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Version";
            NSString *version = [info objectForKey:@"CFBundleShortVersionString"];
            cell.detailTextLabel.text = [version isKindOfClass:[NSString class]] ? version : @"0.3.0";
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"Build";
            NSString *build = [info objectForKey:@"CFBundleVersion"];
            cell.detailTextLabel.text = [build isKindOfClass:[NSString class]] ? build : @"1";
        } else {
            cell.textLabel.text = @"SDK";
            cell.detailTextLabel.text = @"iOS 5.1";
        }
    } else if (indexPath.row == 0) {
        cell.textLabel.text = @"Interface";
        cell.detailTextLabel.text = @"iOS 5 Music";
    } else {
        cell.textLabel.text = @"Playback";
        cell.detailTextLabel.text = @"Deezer";
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
}

@end
