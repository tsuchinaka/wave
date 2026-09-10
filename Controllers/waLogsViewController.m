#import "waLogsViewController.h"
#import "../Services/waDebugLog.h"
#import "../Services/waTheme.h"

@interface waLogsViewController ()
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, assign) BOOL reloadScheduled;
- (void)flushedReload;
@end

@implementation waLogsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Logs";
    self.view.backgroundColor = [waTheme backgroundColor];

    self.textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    self.textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.textView.editable = NO;
    self.textView.font = [waTheme secondaryRegularFontOfSize:12.0];
    self.textView.textColor = [UIColor colorWithWhite:0.12 alpha:1.0];
    self.textView.backgroundColor = [waTheme backgroundColor];
    self.textView.alwaysBounceVertical = YES;
    [self.view addSubview:self.textView];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemTrash target:self action:@selector(clearLogs)];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(logDidChange:) name:waDebugLogDidChangeNotification object:nil];
    [self reloadText];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.view.backgroundColor = [waTheme backgroundColor];
    self.textView.backgroundColor = [waTheme backgroundColor];
    [self reloadText];
}

- (void)reloadText {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray *entries = [[waDebugLog sharedLog] entries];
        NSString *joined = [entries componentsJoinedByString:@"\n"];
        dispatch_async(dispatch_get_main_queue(), ^{
            waLogsViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.textView.text = joined;
            if (strongSelf.textView.text.length) [strongSelf.textView scrollRangeToVisible:NSMakeRange(strongSelf.textView.text.length, 0)];
        });
    });
}

- (void)flushedReload {
    self.reloadScheduled = NO;
    if (self.view.window) [self reloadText];
}

- (void)logDidChange:(NSNotification *)notification {
    (void)notification;
    if (!self.view.window) return;
    if (self.reloadScheduled) return;
    self.reloadScheduled = YES;
    [self performSelector:@selector(flushedReload) withObject:nil afterDelay:0.3];
}

- (void)clearLogs {
    [[waDebugLog sharedLog] clear];
}

- (void)dealloc {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(flushedReload) object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
