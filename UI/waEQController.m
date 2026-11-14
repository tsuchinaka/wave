#import "waEQController.h"
#import "waPlayer.h"

static NSString *waEQBandName(NSUInteger band) {
    if (band == 0) return @"60 Hz";
    if (band == 1) return @"230 Hz";
    if (band == 2) return @"910 Hz";
    if (band == 3) return @"3.6 kHz";
    return @"14 kHz";
}

@interface waEQController ()
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UISegmentedControl *presetControl;
@property (nonatomic, strong) NSMutableArray *sliders;
@property (nonatomic, strong) NSMutableArray *valueLabels;
@property (nonatomic, copy) NSArray *presetNames;
@end

@implementation waEQController

- (id)init {
    if ((self = [super init])) self.title = @"Equalizer";
    return self;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return orientation != UIInterfaceOrientationPortraitUpsideDown;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor groupTableViewBackgroundColor];
    self.presetNames = [NSArray arrayWithObjects:@"Flat", @"Bass Booster", @"Rock", @"Pop", @"Vocal", @"Treble", nil];
    self.sliders = [NSMutableArray array];
    self.valueLabels = [NSMutableArray array];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Reset"
                                                                              style:UIBarButtonItemStyleBordered
                                                                             target:self
                                                                             action:@selector(reset)];

    self.scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:self.scrollView];

    NSArray *segments = [NSArray arrayWithObjects:@"Flat", @"Bass", @"Rock", @"Pop", @"Vocal", @"Treble", nil];
    self.presetControl = [[UISegmentedControl alloc] initWithItems:segments];
    self.presetControl.segmentedControlStyle = UISegmentedControlStyleBar;
    [self.presetControl addTarget:self action:@selector(presetChanged:) forControlEvents:UIControlEventValueChanged];
    [self.scrollView addSubview:self.presetControl];

    for (NSUInteger band = 0; band < 5; band++) {
        UILabel *name = [[UILabel alloc] initWithFrame:CGRectZero];
        name.backgroundColor = [UIColor clearColor];
        name.font = [UIFont boldSystemFontOfSize:16.0];
        name.text = waEQBandName(band);
        name.tag = 100 + (NSInteger)band;
        [self.scrollView addSubview:name];

        UILabel *value = [[UILabel alloc] initWithFrame:CGRectZero];
        value.backgroundColor = [UIColor clearColor];
        value.font = [UIFont systemFontOfSize:13.0];
        value.textColor = [UIColor grayColor];
        value.textAlignment = UITextAlignmentRight;
        [self.valueLabels addObject:value];
        [self.scrollView addSubview:value];

        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectZero];
        slider.minimumValue = -12.0f;
        slider.maximumValue = 12.0f;
        slider.tag = (NSInteger)band;
        slider.value = [[waPlayer shared] gainForBand:band];
        [slider addTarget:self action:@selector(bandChanged:) forControlEvents:UIControlEventValueChanged];
        [self.sliders addObject:slider];
        [self.scrollView addSubview:slider];
    }
    [self syncPreset];
    [self syncValues];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = CGRectGetWidth(self.view.bounds);
    self.presetControl.frame = CGRectMake(10.0, 10.0, w - 20.0, 30.0);
    CGFloat y = 52.0;
    for (NSUInteger band = 0; band < 5; band++) {
        UILabel *name = (UILabel *)[self.scrollView viewWithTag:100 + (NSInteger)band];
        UILabel *value = [self.valueLabels objectAtIndex:band];
        UISlider *slider = [self.sliders objectAtIndex:band];
        name.frame = CGRectMake(12.0, y, 90.0, 22.0);
        value.frame = CGRectMake(w - 80.0, y, 68.0, 22.0);
        y += 24.0;
        // Horizontal slider row: speaker glyph space left/right is not needed here.
        slider.frame = CGRectMake(12.0, y, w - 24.0, 23.0);
        y += 34.0;
    }
    self.scrollView.contentSize = CGSizeMake(w, y + 10.0);
}

- (void)syncPreset {
    NSString *current = [[waPlayer shared] equalizerPresetName];
    NSUInteger index = [self.presetNames indexOfObject:current];
    if (index == NSNotFound) index = 0;
    self.presetControl.selectedSegmentIndex = (NSInteger)index;
}

- (void)syncValues {
    for (NSUInteger band = 0; band < 5; band++) {
        float gain = [[waPlayer shared] gainForBand:band];
        UISlider *slider = [self.sliders objectAtIndex:band];
        slider.value = gain;
        UILabel *value = [self.valueLabels objectAtIndex:band];
        value.text = [NSString stringWithFormat:@"%+.0f dB", gain];
    }
}

- (void)presetChanged:(UISegmentedControl *)control {
    if (control.selectedSegmentIndex < 0 || control.selectedSegmentIndex >= (NSInteger)self.presetNames.count) return;
    [[waPlayer shared] applyPresetNamed:[self.presetNames objectAtIndex:(NSUInteger)control.selectedSegmentIndex]];
    [self syncValues];
}

- (void)bandChanged:(UISlider *)slider {
    [[waPlayer shared] setGain:slider.value forBand:(NSUInteger)slider.tag];
    UILabel *value = [self.valueLabels objectAtIndex:(NSUInteger)slider.tag];
    value.text = [NSString stringWithFormat:@"%+.0f dB", slider.value];
}

- (void)reset {
    [[waPlayer shared] applyPresetNamed:@"Flat"];
    [self syncPreset];
    [self syncValues];
}

@end
