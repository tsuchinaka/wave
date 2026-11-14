#import "waProfileController.h"
#import "waSession.h"
#import "waLoginController.h"

@interface waProfileController () <UIAlertViewDelegate>
@end

@implementation waProfileController

- (id)init {
    return [self initWithGroupedStyle:YES];
}

- (id)initWithGroupedStyle:(BOOL)grouped {
    if ((self = [super initWithGroupedStyle:grouped])) {
        self.title = @"Profile";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = [UIColor groupTableViewBackgroundColor];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return orientation != UIInterfaceOrientationPortraitUpsideDown;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return [waSession shared].authenticated ? 3 : 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (![waSession shared].authenticated) return 1;
    if (section == 0) return 2;
    if (section == 1) return 1;
    return 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *kValue = @"profile.value";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kValue];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:kValue];
        cell.textLabel.font = [UIFont systemFontOfSize:17.0];
    }
    waUser *user = [waSession shared].user;
    if (![waSession shared].authenticated) {
        cell.textLabel.text = @"Sign In";
        cell.detailTextLabel.text = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Name";
            cell.detailTextLabel.text = user.name.length ? user.name : @"-";
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            cell.textLabel.text = @"Country";
            cell.detailTextLabel.text = user.country.length ? user.country : @"-";
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
    } else if (indexPath.section == 1) {
        cell.textLabel.text = @"Account";
        cell.detailTextLabel.text = @"Deezer";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        cell.textLabel.text = @"Log Out";
        cell.textLabel.textColor = [UIColor redColor];
        cell.detailTextLabel.text = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (![waSession shared].authenticated) {
        [self.navigationController pushViewController:[[waLoginController alloc] init] animated:YES];
        return;
    }
    if (indexPath.section == 2) {
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Log Out"
                                                        message:userDisplayName()
                                                       delegate:self
                                              cancelButtonTitle:@"Cancel"
                                              otherButtonTitles:@"Log Out", nil];
        [alert show];
    }
}

static NSString *userDisplayName(void) {
    NSString *name = [waSession shared].user.name;
    return name.length ? name : @"Log out?";
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    (void)alertView;
    if (buttonIndex == 1) {
        [[waSession shared] logout];
        [self.tableView reloadData];
    }
}

@end
