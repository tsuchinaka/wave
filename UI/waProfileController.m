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
    if (section == 0) return 5;
    if (section == 1) return 2;
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (![waSession shared].authenticated) return nil;
    if (section == 0) return @"Deezer Account";
    if (section == 1) return @"Playback";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *kValue = @"profile.value";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kValue];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:kValue];
        cell.textLabel.font = [UIFont systemFontOfSize:17.0];
    }
    cell.textLabel.textColor = [UIColor blackColor];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.detailTextLabel.text = nil;

    waSession *session = [waSession shared];
    waUser *user = session.user;
    if (!session.authenticated) {
        cell.textLabel.text = @"Sign In";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
        return cell;
    }
    if (indexPath.section == 0) {
        NSArray *labels = @[@"Username", @"Email", @"Country", @"User ID", @"Joined"];
        NSString *values[5] = {
            user.name.length ? user.name : @"-",
            user.email.length ? user.email : @"-",
            user.country.length ? user.country : @"-",
            user.identifier.length ? user.identifier : @"-",
            user.joined.length ? user.joined : @"-"
        };
        cell.textLabel.text = [labels objectAtIndex:indexPath.row];
        cell.detailTextLabel.text = values[indexPath.row];
        return cell;
    }
    if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Plan";
            cell.detailTextLabel.text = user.offerName.length ? user.offerName : @"-";
        } else {
            cell.textLabel.text = @"Max Quality";
            cell.detailTextLabel.text = [session qualityName:session.maximumQuality];
        }
        return cell;
    }
    cell.textLabel.text = @"Log Out";
    cell.textLabel.textColor = [UIColor redColor];
    cell.selectionStyle = UITableViewCellSelectionStyleBlue;
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
