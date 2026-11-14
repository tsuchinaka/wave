#import "waLogsController.h"

@interface waLogsController ()
@property (nonatomic, strong) UITextView *textView;
@end

@implementation waLogsController

- (id)init {
    if ((self = [super init])) self.title = @"Logs";
    return self;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return orientation != UIInterfaceOrientationPortraitUpsideDown;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    self.textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    self.textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.textView.editable = NO;
    self.textView.font = [UIFont fontWithName:@"Courier" size:12.0] ? [UIFont fontWithName:@"Courier" size:12.0] : [UIFont systemFontOfSize:13.0];
    [self.view addSubview:self.textView];

    UIBarButtonItem *copyItem = [[UIBarButtonItem alloc] initWithTitle:@"Copy" style:UIBarButtonItemStyleBordered target:self action:@selector(copyLog)];
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:NULL];
    UIBarButtonItem *clearItem = [[UIBarButtonItem alloc] initWithTitle:@"Clear" style:UIBarButtonItemStyleBordered target:self action:@selector(clearLog)];
    self.toolbarItems = [NSArray arrayWithObjects:copyItem, flex, clearItem, nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setToolbarHidden:NO animated:animated];
    [self reloadLog];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.navigationController setToolbarHidden:YES animated:animated];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.textView.frame = self.view.bounds;
}

- (NSString *)logPath {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (!paths.count) return nil;
    return [[paths objectAtIndex:0] stringByAppendingPathComponent:@"wave.log"];
}

- (void)reloadLog {
    __weak waLogsController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *path = [weakSelf logPath];
        NSString *text = path.length ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.textView.text = text.length ? text : @"(empty)";
            if (weakSelf.textView.text.length) {
                [weakSelf.textView scrollRangeToVisible:NSMakeRange(weakSelf.textView.text.length, 0)];
            }
        });
    });
}

- (void)copyLog {
    [UIPasteboard generalPasteboard].string = self.textView.text ? self.textView.text : @"";
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Copied" message:nil delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
    [alert show];
}

- (void)clearLog {
    NSString *path = [self logPath];
    if (path.length) [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    self.textView.text = @"(empty)";
}

@end
