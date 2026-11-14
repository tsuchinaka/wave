#import "waLoginController.h"
#import "waSession.h"

@interface waLoginController () <UITextFieldDelegate>
@property (nonatomic, strong) UITextField *arlField;
@property (nonatomic, strong) UILabel *errorLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation waLoginController

- (id)init {
    return [self initWithGroupedStyle:YES];
}

- (id)initWithGroupedStyle:(BOOL)grouped {
    if ((self = [super initWithGroupedStyle:grouped])) {
        self.title = @"Account";
        self.emptyTitle = @"Account";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = [UIColor groupTableViewBackgroundColor];
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 320.0, 44.0)];
    self.errorLabel = [[UILabel alloc] initWithFrame:CGRectMake(12.0, 6.0, 296.0, 32.0)];
    self.errorLabel.backgroundColor = [UIColor clearColor];
    self.errorLabel.font = [UIFont systemFontOfSize:13.0];
    self.errorLabel.textColor = [UIColor redColor];
    self.errorLabel.numberOfLines = 0;
    [footer addSubview:self.errorLabel];
    self.tableView.tableFooterView = footer;
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
    return [waSession shared].authenticated ? 2 : 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if ([waSession shared].authenticated) return section == 0 ? 1 : 1;
    return section == 0 ? 1 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if ([waSession shared].authenticated) return section == 0 ? @"Signed In" : nil;
    return section == 0 ? @"Deezer ARL" : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([waSession shared].authenticated) {
        static NSString *kAccount = @"login.account";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kAccount];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:kAccount];
            cell.textLabel.font = [UIFont systemFontOfSize:17.0];
        }
        if (indexPath.section == 0) {
            cell.textLabel.text = @"User";
            cell.detailTextLabel.text = [waSession shared].user.name.length ? [waSession shared].user.name : @"-";
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            cell.textLabel.text = @"Log Out";
            cell.textLabel.textColor = [UIColor redColor];
            cell.detailTextLabel.text = nil;
            cell.accessoryType = UITableViewCellAccessoryNone;
        }
        return cell;
    }
    if (indexPath.section == 0) {
        static NSString *kField = @"login.field";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kField];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kField];
            self.arlField = [[UITextField alloc] initWithFrame:CGRectMake(12.0, 11.0, 296.0, 22.0)];
            self.arlField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            self.arlField.borderStyle = UITextBorderStyleNone;
            self.arlField.font = [UIFont systemFontOfSize:15.0];
            self.arlField.placeholder = @"Paste ARL here";
            self.arlField.autocapitalizationType = UITextAutocapitalizationTypeNone;
            self.arlField.autocorrectionType = UITextAutocorrectionTypeNo;
            self.arlField.keyboardType = UIKeyboardTypeASCIICapable;
            self.arlField.returnKeyType = UIReturnKeyGo;
            self.arlField.delegate = self;
            self.arlField.clearButtonMode = UITextFieldViewModeWhileEditing;
            [cell.contentView addSubview:self.arlField];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        return cell;
    }
    static NSString *kGo = @"login.go";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kGo];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kGo];
        cell.textLabel.font = [UIFont boldSystemFontOfSize:17.0];
        cell.textLabel.textColor = [UIColor colorWithRed:0.0 green:0.32 blue:0.60 alpha:1.0];
        cell.textLabel.textAlignment = UITextAlignmentCenter;
    }
    cell.textLabel.text = @"Log In";
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self.arlField resignFirstResponder];
    if ([waSession shared].authenticated) {
        if (indexPath.section == 1) [self logout];
        return;
    }
    if (indexPath.section == 1) [self login];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    [self login];
    return YES;
}

- (void)login {
    NSString *arl = [self.arlField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!arl.length) {
        self.errorLabel.text = @"Paste your Deezer ARL.";
        return;
    }
    self.errorLabel.text = nil;
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    [spinner startAnimating];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:spinner];
    __weak waLoginController *weakSelf = self;
    [[waSession shared] loginWithARL:arl completion:^(waUser *user, NSError *error) {
        waLoginController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.navigationItem.rightBarButtonItem = nil;
        if (error || !user) {
            strongSelf.errorLabel.text = error.localizedDescription.length ? error.localizedDescription : @"Login failed.";
            return;
        }
        [strongSelf.navigationController popViewControllerAnimated:YES];
    }];
}

- (void)logout {
    [[waSession shared] logout];
    self.arlField.text = nil;
    [self.tableView reloadData];
}

@end
