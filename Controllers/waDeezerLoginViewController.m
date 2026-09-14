#import "waDeezerLoginViewController.h"
#import "../Services/waDeezerClient.h"
#import "../Services/waTheme.h"

@interface waDeezerLoginViewController ()
@property (nonatomic, strong) UITextField *arlField;
@property (nonatomic, strong) UIButton *connectButton;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIView *contentView;
@property (nonatomic, strong) UIView *formPanel;
@property (nonatomic, strong) UIView *fieldPanel;
@property (nonatomic, strong) UILabel *eyebrowLabel;
@property (nonatomic, strong) UILabel *headingLabel;
@property (nonatomic, strong) UILabel *instructionsLabel;
@property (nonatomic, strong) UILabel *fieldLabel;
@property (nonatomic, strong) UILabel *footnoteLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIView *spinnerBackdrop;
@property (nonatomic, copy) void (^completion)(NSError *error);
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, assign, getter=isRequired) BOOL required;
@end

@implementation waDeezerLoginViewController

- (id)initWithCompletion:(void (^)(NSError *))completion {
    return [self initWithCompletion:completion required:NO];
}

- (id)initWithCompletion:(void (^)(NSError *))completion required:(BOOL)required {
    if ((self = [super init])) {
        _completion = [completion copy];
        _required = required;
        self.title = @"Deezer";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeDidChange:) name:waThemeDidChangeNotification object:nil];
    self.view.backgroundColor = [waTheme backgroundColor];
    if (!self.required) self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel:)];
    [waTheme applyLayoutCompatibilityToViewController:self];
    [waTheme applyToView:self.navigationController.navigationBar];

    self.scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.scrollView.backgroundColor = [waTheme backgroundColor];
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.showsVerticalScrollIndicator = NO;
    [self.view addSubview:self.scrollView];

    self.contentView = [[UIView alloc] initWithFrame:CGRectZero];
    self.contentView.backgroundColor = [UIColor clearColor];
    [self.scrollView addSubview:self.contentView];

    self.eyebrowLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.eyebrowLabel.text = self.required ? @"WAVE SETUP" : @"DEEZER ACCOUNT";
    self.eyebrowLabel.font = [waTheme secondaryBoldFontOfSize:11.0];
    self.eyebrowLabel.textColor = [waTheme barColor];
    self.eyebrowLabel.backgroundColor = [UIColor clearColor];
    [self.contentView addSubview:self.eyebrowLabel];

    self.headingLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.headingLabel.text = @"Connect Deezer";
    self.headingLabel.font = [waTheme extraBoldFontOfSize:28.0];
    self.headingLabel.textColor = [waTheme primaryTextColor];
    self.headingLabel.backgroundColor = [UIColor clearColor];
    [self.contentView addSubview:self.headingLabel];

    self.instructionsLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.instructionsLabel.text = self.required ? @"Connect your Deezer account to unlock Wave's library, playlists, and playback." : @"Use your Deezer ARL token to access your library and playlists.";
    self.instructionsLabel.numberOfLines = 3;
    self.instructionsLabel.font = [waTheme secondaryRegularFontOfSize:15.0];
    self.instructionsLabel.textColor = [waTheme secondaryTextColor];
    self.instructionsLabel.backgroundColor = [UIColor clearColor];
    [self.contentView addSubview:self.instructionsLabel];

    self.formPanel = [[UIView alloc] initWithFrame:CGRectZero];
    self.formPanel.backgroundColor = [waTheme surfaceColor];
    self.formPanel.layer.cornerRadius = 7.0;
    self.formPanel.layer.borderWidth = 1.0;
    self.formPanel.layer.borderColor = [waTheme separatorColor].CGColor;
    self.formPanel.layer.shadowColor = [UIColor blackColor].CGColor;
    self.formPanel.layer.shadowOpacity = 0.28;
    self.formPanel.layer.shadowRadius = 5.0;
    self.formPanel.layer.shadowOffset = CGSizeMake(0.0, 2.0);
    [self.contentView addSubview:self.formPanel];

    self.fieldLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.fieldLabel.text = @"DEEZER ARL TOKEN";
    self.fieldLabel.font = [waTheme secondaryBoldFontOfSize:11.0];
    self.fieldLabel.textColor = [waTheme secondaryTextColor];
    self.fieldLabel.backgroundColor = [UIColor clearColor];
    [self.formPanel addSubview:self.fieldLabel];

    self.fieldPanel = [[UIView alloc] initWithFrame:CGRectZero];
    self.fieldPanel.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.96];
    self.fieldPanel.layer.cornerRadius = 5.0;
    self.fieldPanel.layer.borderWidth = 1.0;
    self.fieldPanel.layer.borderColor = [UIColor colorWithWhite:0.0 alpha:0.18].CGColor;
    [self.formPanel addSubview:self.fieldPanel];

    self.arlField = [[UITextField alloc] initWithFrame:CGRectZero];
    self.arlField.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.arlField.placeholder = @"Paste your token here";
    self.arlField.borderStyle = UITextBorderStyleNone;
    self.arlField.backgroundColor = [UIColor clearColor];
    self.arlField.textColor = [UIColor blackColor];
    self.arlField.font = [waTheme secondaryRegularFontOfSize:16.0];
    self.arlField.secureTextEntry = YES;
    self.arlField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.arlField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.arlField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.arlField.returnKeyType = UIReturnKeyDone;
    self.arlField.accessibilityLabel = @"Deezer ARL token";
    [self.arlField addTarget:self action:@selector(dismissKeyboard:) forControlEvents:UIControlEventEditingDidEndOnExit];
    [self.fieldPanel addSubview:self.arlField];

    self.connectButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.connectButton setTitle:@"Connect Deezer" forState:UIControlStateNormal];
    [waTheme applySkeuomorphicStyleToButton:self.connectButton];
    self.connectButton.titleLabel.font = [waTheme boldFontOfSize:17.0];
    self.connectButton.accessibilityLabel = @"Connect Deezer account";
    [self.connectButton addTarget:self action:@selector(connect:) forControlEvents:UIControlEventTouchUpInside];
    [self.formPanel addSubview:self.connectButton];

    self.footnoteLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.footnoteLabel.text = @"Your token is used only to connect this device to Deezer.";
    self.footnoteLabel.font = [waTheme secondaryRegularFontOfSize:12.0];
    self.footnoteLabel.textColor = [waTheme secondaryTextColor];
    self.footnoteLabel.backgroundColor = [UIColor clearColor];
    self.footnoteLabel.numberOfLines = 2;
    [self.formPanel addSubview:self.footnoteLabel];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    self.spinner.hidden = YES;
    self.spinnerBackdrop = [waTheme circularBackdropForSpinner:self.spinner];
    self.spinnerBackdrop.hidden = YES;
    [self.formPanel addSubview:self.spinnerBackdrop];
    [self layoutForm];
    [waTheme applyToView:self.view];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutForm];
}

- (void)layoutForm {
    if (!self.scrollView || !self.contentView) return;
    CGFloat width = self.view.bounds.size.width;
    CGFloat margin = 20.0;
    CGFloat contentWidth = MAX(0.0, width - margin * 2.0);
    CGFloat y = 18.0;
    self.scrollView.frame = self.view.bounds;
    self.contentView.frame = CGRectMake(0.0, 0.0, width, 400.0);

    self.eyebrowLabel.frame = CGRectMake(margin, y, contentWidth, 16.0);
    y += 22.0;
    self.headingLabel.frame = CGRectMake(margin, y, contentWidth, 36.0);
    y += 44.0;
    self.instructionsLabel.frame = CGRectMake(margin, y, contentWidth, 50.0);
    y += 68.0;

    self.formPanel.frame = CGRectMake(margin, y, contentWidth, 174.0);
    CGFloat panelMargin = 14.0;
    self.fieldLabel.frame = CGRectMake(panelMargin, 13.0, contentWidth - panelMargin * 2.0, 16.0);
    self.fieldPanel.frame = CGRectMake(panelMargin, 35.0, contentWidth - panelMargin * 2.0, 46.0);
    self.arlField.frame = CGRectInset(self.fieldPanel.bounds, 12.0, 0.0);
    self.connectButton.frame = CGRectMake(panelMargin, 91.0, contentWidth - panelMargin * 2.0, 44.0);
    self.footnoteLabel.frame = CGRectMake(panelMargin, 143.0, contentWidth - panelMargin * 2.0, 28.0);
    self.spinnerBackdrop.center = CGPointMake(CGRectGetMidX(self.connectButton.frame), CGRectGetMidY(self.connectButton.frame));
    [self.formPanel bringSubviewToFront:self.spinnerBackdrop];
    self.scrollView.contentSize = CGSizeMake(width, CGRectGetMaxY(self.formPanel.frame) + 22.0);
}

- (void)themeDidChange:(NSNotification *)notification {
    (void)notification;
    self.view.backgroundColor = [waTheme backgroundColor];
    self.scrollView.backgroundColor = [waTheme backgroundColor];
    self.formPanel.backgroundColor = [waTheme surfaceColor];
    self.formPanel.layer.borderColor = [waTheme separatorColor].CGColor;
    self.eyebrowLabel.textColor = [waTheme barColor];
    self.headingLabel.textColor = [waTheme primaryTextColor];
    self.instructionsLabel.textColor = [waTheme secondaryTextColor];
    self.fieldLabel.textColor = [waTheme secondaryTextColor];
    self.footnoteLabel.textColor = [waTheme secondaryTextColor];
    [waTheme applySkeuomorphicStyleToButton:self.connectButton];
    [waTheme applyToView:self.navigationController.navigationBar];
}

- (void)dismissKeyboard:(id)sender {
    (void)sender;
    [self.arlField resignFirstResponder];
}

- (void)keyboardWillShow:(NSNotification *)notification {
    if (!self.arlField.isFirstResponder || !self.connectButton) return;
    CGRect keyboardFrame = [self.view convertRect:[notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue] fromView:nil];
    CGRect buttonFrame = [self.view convertRect:self.connectButton.bounds fromView:self.connectButton];
    CGFloat overlap = CGRectGetMaxY(buttonFrame) - CGRectGetMinY(keyboardFrame) + 12.0;
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
        [[[UIAlertView alloc] initWithTitle:@"Deezer" message:@"Enter an ARL token to continue." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
        return;
    }
    self.finished = YES;
    [self.arlField resignFirstResponder];
    self.navigationItem.leftBarButtonItem.enabled = NO;
    self.connectButton.enabled = NO;
    [self.connectButton setTitle:@"Connecting…" forState:UIControlStateNormal];
    self.arlField.enabled = NO;
    self.spinner.hidden = NO;
    self.spinnerBackdrop.hidden = NO;
    [self.formPanel bringSubviewToFront:self.spinnerBackdrop];
    [self.spinner startAnimating];
    [[waDeezerClient sharedClient] setARL:arl completion:^(NSError *error) {
        [self.spinner stopAnimating];
        self.spinner.hidden = YES;
        self.spinnerBackdrop.hidden = YES;
        self.connectButton.enabled = YES;
        [self.connectButton setTitle:@"Connect Deezer" forState:UIControlStateNormal];
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
