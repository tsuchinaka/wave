#import "waDeezerLoginViewController.h"
#import "../Services/waDeezerClient.h"
#import "../Services/waTheme.h"

@interface waDeezerLoginViewController ()
@property (nonatomic, strong) UITextField *arlField;
@property (nonatomic, strong) UIButton *connectButton;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIView *spinnerBackdrop;
@property (nonatomic, copy) void (^completion)(NSError *error);
@property (nonatomic, assign) BOOL finished;
@end

@implementation waDeezerLoginViewController

- (id)initWithCompletion:(void (^)(NSError *))completion {
    if ((self = [super init])) {
        _completion = [completion copy];
        self.title = @"Deezer Login";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
    self.view.backgroundColor = [waTheme backgroundColor];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel:)];

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(20.0, 34.0, self.view.bounds.size.width - 40.0, 32.0)];
    titleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    titleLabel.text = @"Connect your Deezer account";
    titleLabel.textAlignment = NSTextAlignmentCenter;
    [waTheme applyPrimaryTextStyleToLabel:titleLabel];
    titleLabel.font = [waTheme boldFontOfSize:22.0];
    [self.view addSubview:titleLabel];

    UILabel *instructions = [[UILabel alloc] initWithFrame:CGRectMake(25.0, 78.0, self.view.bounds.size.width - 50.0, 66.0)];
    instructions.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    instructions.text = @"Paste your Deezer ARL token below. Wave requires an ARL to access your Deezer library.";
    instructions.textAlignment = NSTextAlignmentCenter;
    instructions.numberOfLines = 3;
    [waTheme applySecondaryTextStyleToLabel:instructions];
    instructions.font = [waTheme secondaryRegularFontOfSize:14.0];
    [self.view addSubview:instructions];

    self.arlField = [[UITextField alloc] initWithFrame:CGRectMake(20.0, 164.0, self.view.bounds.size.width - 40.0, 44.0)];
    self.arlField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.arlField.placeholder = @"Deezer ARL token";
    self.arlField.borderStyle = UITextBorderStyleRoundedRect;
    self.arlField.backgroundColor = [UIColor whiteColor];
    self.arlField.textColor = [UIColor blackColor];
    self.arlField.secureTextEntry = YES;
    self.arlField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.arlField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.arlField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.arlField.returnKeyType = UIReturnKeyDone;
    [self.arlField addTarget:self action:@selector(dismissKeyboard:) forControlEvents:UIControlEventEditingDidEndOnExit];
    [self.view addSubview:self.arlField];

    self.connectButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.connectButton.frame = CGRectMake(20.0, 224.0, self.view.bounds.size.width - 40.0, 44.0);
    self.connectButton.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.connectButton setTitle:@"Connect Deezer" forState:UIControlStateNormal];
    [waTheme applySkeuomorphicStyleToButton:self.connectButton];
    self.connectButton.titleLabel.font = [waTheme boldFontOfSize:17.0];
    [self.connectButton addTarget:self action:@selector(connect:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.connectButton];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    self.spinner.center = CGPointMake(self.view.bounds.size.width / 2.0, 294.0);
    self.spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    self.spinner.hidden = YES;
    self.spinnerBackdrop = [waTheme circularBackdropForSpinner:self.spinner];
    self.spinnerBackdrop.hidden = YES;
    [self.view addSubview:self.spinnerBackdrop];
    [self.view bringSubviewToFront:self.spinnerBackdrop];
    [waTheme applyToView:self.view];
}

- (void)dismissKeyboard:(id)sender {
    (void)sender;
    [self.arlField resignFirstResponder];
}

- (void)keyboardWillShow:(NSNotification *)notification {
    if (!self.arlField.isFirstResponder || !self.connectButton) return;
    CGRect keyboardFrame = [self.view convertRect:[notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue] fromView:nil];
    CGFloat overlap = CGRectGetMaxY(self.connectButton.frame) - CGRectGetMinY(keyboardFrame) + 12.0;
    CGFloat shift = overlap > 0.0 ? -MIN(overlap, 140.0) : 0.0;
    NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationCurve curve = [notification.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue];
    [UIView beginAnimations:nil context:NULL];
    [UIView setAnimationDuration:duration];
    [UIView setAnimationCurve:curve];
    self.view.transform = CGAffineTransformMakeTranslation(0.0, shift);
    [UIView commitAnimations];
}

- (void)keyboardWillHide:(NSNotification *)notification {
    NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationCurve curve = [notification.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue];
    [UIView beginAnimations:nil context:NULL];
    [UIView setAnimationDuration:duration];
    [UIView setAnimationCurve:curve];
    self.view.transform = CGAffineTransformIdentity;
    [UIView commitAnimations];
}

- (void)connect:(id)sender {
    (void)sender;
    NSString *arl = [self.arlField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!arl.length) {
        [[[UIAlertView alloc] initWithTitle:@"Deezer Login" message:@"An ARL token is required." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
        return;
    }
    self.finished = YES;
    self.navigationItem.leftBarButtonItem.enabled = NO;
    self.connectButton.enabled = NO;
    self.arlField.enabled = NO;
    self.spinner.hidden = NO;
    self.spinnerBackdrop.hidden = NO;
    [self.view bringSubviewToFront:self.spinnerBackdrop];
    [self.spinner startAnimating];
    [[waDeezerClient sharedClient] setARL:arl completion:^(NSError *error) {
        [self.spinner stopAnimating];
        self.spinner.hidden = YES;
        self.spinnerBackdrop.hidden = YES;
        self.connectButton.enabled = YES;
        self.arlField.enabled = YES;
        if (error) {
            self.finished = NO;
            self.navigationItem.leftBarButtonItem.enabled = YES;
            if (self.completion) self.completion(error);
            return;
        }
        if (self.completion) self.completion(nil);
        [self dismissViewControllerAnimated:YES completion:nil];
    }];
}

- (void)cancel:(id)sender {
    (void)sender;
    if (self.finished) return;
    if (self.completion) self.completion([NSError errorWithDomain:@"com.bytebox.wave.deezer" code:NSUserCancelledError userInfo:nil]);
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
