#import "waEQController.h"
#import "waActions.h"
#import "waPlayer.h"
#import "waRootController.h"
#import "waAudioCore.h"
#import <math.h>

#define WA_EQ_MIN -12.0f
#define WA_EQ_MAX 12.0f

static NSString *waGainText(float db) {
    if (fabsf(db) < 0.05f) return @"0.0";
    return [NSString stringWithFormat:@"%+.1f", db];
}

static NSString *waEQBandLabel(NSUInteger band) {
    static NSString *labels[WA_EQ_BANDS] = {@"31", @"62", @"125", @"250", @"500", @"1k", @"2k", @"4k", @"8k", @"16k"};
    return band < WA_EQ_BANDS ? labels[band] : @"";
}

@interface waEQGraphView : UIView {
    float _gains[WA_EQ_BANDS];
}
- (void)setGains:(const float *)gains;
@end

@implementation waEQGraphView

- (void)setGains:(const float *)gains {
    if (gains) memcpy(_gains, gains, sizeof(_gains));
    [self setNeedsDisplay];
}

- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor whiteColor];
        self.layer.cornerRadius = 8.0;
        self.clipsToBounds = YES;
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    (void)rect;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect bounds = self.bounds;
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    CGFloat mid = height / 2.0;

    [[UIColor colorWithWhite:0.92 alpha:1.0] setStroke];
    CGContextSetLineWidth(ctx, 1.0);
    CGFloat dashes[] = {2.0, 2.0};
    CGContextSetLineDash(ctx, 0.0, dashes, 2);
    for (int mark = -12; mark <= 12; mark += 6) {
        CGFloat y = mid - (CGFloat)mark / WA_EQ_MAX * (mid - 6.0);
        CGContextMoveToPoint(ctx, 0.0, y);
        CGContextAddLineToPoint(ctx, width, y);
    }
    CGContextStrokePath(ctx);
    CGContextSetLineDash(ctx, 0.0, NULL, 0);

    CGContextSetLineWidth(ctx, 2.0);
    [[UIColor colorWithRed:0.0 green:0.45 blue:0.85 alpha:1.0] setStroke];
    waEQCoeff coeffs[WA_EQ_BANDS];
    float preGain = waEQBuild(_gains, 44100.0f, coeffs);
    float preDB = 20.0f * log10f(preGain > 0.0f ? preGain : 1.0f);
    CGContextBeginPath(ctx);
    int steps = (int)width;
    for (int step = 0; step <= steps; step++) {
        double fraction = steps ? (double)step / (double)steps : 0.0;
        float freq = 20.0f * powf(1000.0f, (float)fraction);
        float db = waEQMagnitudeDB(coeffs, 44100.0f, freq) + preDB;
        if (db > WA_EQ_MAX) db = WA_EQ_MAX;
        if (db < WA_EQ_MIN) db = WA_EQ_MIN;
        CGFloat y = mid - (CGFloat)db / WA_EQ_MAX * (mid - 6.0);
        if (step == 0) CGContextMoveToPoint(ctx, 0.0, y);
        else CGContextAddLineToPoint(ctx, (CGFloat)step, y);
    }
    CGContextStrokePath(ctx);
}

@end

@interface waEQController ()
@property (nonatomic, strong) waEQGraphView *graph;
@property (nonatomic, strong) UIButton *presetButton;
@property (nonatomic, strong) UILabel *gainLabel;
@property (nonatomic, strong) UISlider *gainSlider;
@property (nonatomic, strong) UILabel *gainValueLabel;
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
    return orientation == UIInterfaceOrientationPortrait;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor groupTableViewBackgroundColor];
    self.presetNames = [[waPlayer shared] equalizerPresets];
    self.sliders = [NSMutableArray array];
    self.valueLabels = [NSMutableArray array];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Reset"
                                                                              style:UIBarButtonItemStyleBordered
                                                                             target:self
                                                                             action:@selector(reset)];

    self.graph = [[waEQGraphView alloc] initWithFrame:CGRectZero];
    [self.view addSubview:self.graph];

    self.presetButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
    self.presetButton.titleLabel.font = [UIFont boldSystemFontOfSize:15.0];
    [self.presetButton addTarget:self action:@selector(showPresets) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.presetButton];

    self.gainLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.gainLabel.backgroundColor = [UIColor clearColor];
    self.gainLabel.font = [UIFont boldSystemFontOfSize:12.0];
    self.gainLabel.textColor = [UIColor colorWithWhite:0.30 alpha:1.0];
    self.gainLabel.text = @"Gain";
    [self.view addSubview:self.gainLabel];

    self.gainSlider = [[UISlider alloc] initWithFrame:CGRectZero];
    self.gainSlider.minimumValue = WA_EQ_MIN;
    self.gainSlider.maximumValue = WA_EQ_MAX;
    [self.gainSlider addTarget:self action:@selector(gainChanged:) forControlEvents:UIControlEventValueChanged];
    [self.gainSlider addTarget:self action:@selector(gainSettled:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
    [self.view addSubview:self.gainSlider];

    self.gainValueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.gainValueLabel.backgroundColor = [UIColor clearColor];
    self.gainValueLabel.font = [UIFont boldSystemFontOfSize:12.0];
    self.gainValueLabel.textColor = [UIColor colorWithWhite:0.30 alpha:1.0];
    self.gainValueLabel.textAlignment = UITextAlignmentRight;
    [self.view addSubview:self.gainValueLabel];

    for (NSUInteger band = 0; band < WA_EQ_BANDS; band++) {
        UILabel *value = [[UILabel alloc] initWithFrame:CGRectZero];
        value.backgroundColor = [UIColor clearColor];
        value.font = [UIFont systemFontOfSize:9.0];
        value.textColor = [UIColor grayColor];
        value.textAlignment = UITextAlignmentCenter;
        value.adjustsFontSizeToFitWidth = YES;
        [self.valueLabels addObject:value];
        [self.view addSubview:value];

        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(0.0, 0.0, 23.0, 150.0)];
        slider.minimumValue = WA_EQ_MIN;
        slider.maximumValue = WA_EQ_MAX;
        slider.tag = (NSInteger)band;
        slider.transform = CGAffineTransformMakeRotation((CGFloat)(-M_PI_2));
        [slider addTarget:self action:@selector(bandChanged:) forControlEvents:UIControlEventValueChanged];
        [slider addTarget:self action:@selector(bandSettled:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
        [self.sliders addObject:slider];
        [self.view addSubview:slider];

        UILabel *name = [[UILabel alloc] initWithFrame:CGRectZero];
        name.backgroundColor = [UIColor clearColor];
        name.font = [UIFont boldSystemFontOfSize:10.0];
        name.textAlignment = UITextAlignmentCenter;
        name.text = waEQBandLabel(band);
        name.tag = 100 + (NSInteger)band;
        [self.view addSubview:name];
    }
    [self readGains];
    [self syncPresetButton];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = CGRectGetWidth(self.view.bounds);
    CGFloat height = CGRectGetHeight(self.view.bounds);
    self.graph.frame = CGRectMake(8.0, 8.0, width - 16.0, 96.0);
    self.presetButton.frame = CGRectMake(8.0, 112.0, 104.0, 32.0);
    self.gainLabel.frame = CGRectMake(122.0, 112.0, 34.0, 32.0);
    self.gainValueLabel.frame = CGRectMake(width - 58.0, 112.0, 50.0, 32.0);
    CGFloat gainLeft = 158.0;
    CGFloat gainRight = width - 62.0;
    if (gainRight < gainLeft + 40.0) gainRight = gainLeft + 40.0;
    self.gainSlider.frame = CGRectMake(gainLeft, 116.0, gainRight - gainLeft, 23.0);

    CGFloat top = 156.0;
    CGFloat bottom = height - [[waRootController shared] miniPlayerHeight] - 8.0;
    CGFloat slot = width / (CGFloat)WA_EQ_BANDS;
    CGFloat track = bottom - top - 34.0;
    for (NSUInteger band = 0; band < WA_EQ_BANDS; band++) {
        CGFloat center = slot * ((CGFloat)band + 0.5);
        UILabel *value = [self.valueLabels objectAtIndex:band];
        UISlider *slider = [self.sliders objectAtIndex:band];
        UILabel *name = (UILabel *)[self.view viewWithTag:100 + (NSInteger)band];
        value.frame = CGRectMake(center - slot / 2.0, top, slot, 12.0);
        slider.bounds = CGRectMake(0.0, 0.0, track, 23.0);
        slider.center = CGPointMake(center, top + 16.0 + track / 2.0);
        name.frame = CGRectMake(center - slot / 2.0, bottom - 16.0, slot, 14.0);
    }
}

- (void)readGains {
    float gains[WA_EQ_BANDS];
    for (NSUInteger band = 0; band < WA_EQ_BANDS; band++) {
        float gain = [[waPlayer shared] gainForBand:band];
        gains[band] = gain;
        UISlider *slider = [self.sliders objectAtIndex:band];
        slider.value = gain;
        UILabel *value = [self.valueLabels objectAtIndex:band];
        value.text = [NSString stringWithFormat:@"%+.0f", gain];
    }
    [self.graph setGains:gains];
    float preamp = [[waPlayer shared] preampDB];
    self.gainSlider.value = preamp;
    self.gainValueLabel.text = waGainText(preamp);
}

- (void)syncPresetButton {
    NSString *name = [[waPlayer shared] equalizerPresetName];
    [self.presetButton setTitle:name.length ? name : @"Flat" forState:UIControlStateNormal];
}

- (void)showPresets {
    __weak waEQController *weakSelf = self;
    NSMutableArray *actions = [NSMutableArray array];
    for (NSString *name in self.presetNames) {
        [actions addObject:[waAction actionWithTitle:name destructive:NO handler:^{
            waEQController *strongSelf = weakSelf;
            if (!strongSelf) return;
            [[waPlayer shared] applyPresetNamed:name];
            [strongSelf readGains];
            [strongSelf syncPresetButton];
        }]];
    }
    [waActions showInView:self.view title:@"Preset" actions:actions];
}

- (void)gainChanged:(UISlider *)slider {
    self.gainValueLabel.text = waGainText(slider.value);
}

// Half-dB steps, committed once the finger lifts, same as the bands.
- (void)gainSettled:(UISlider *)slider {
    float snapped = roundf(slider.value * 2.0f) / 2.0f;
    slider.value = snapped;
    self.gainValueLabel.text = waGainText(snapped);
    [[waPlayer shared] setPreampDB:snapped];
}

- (void)bandChanged:(UISlider *)slider {
    NSUInteger band = (NSUInteger)slider.tag;
    float snapped = roundf(slider.value);
    UILabel *value = [self.valueLabels objectAtIndex:band];
    value.text = [NSString stringWithFormat:@"%+.0f", snapped];
    float gains[WA_EQ_BANDS];
    for (NSUInteger i = 0; i < WA_EQ_BANDS; i++) {
        UISlider *bandSlider = [self.sliders objectAtIndex:i];
        gains[i] = roundf(bandSlider.value);
    }
    [self.graph setGains:gains];
}

// The audio path and the defaults are touched once the finger lifts. Driving
// them on every pixel of the drag would rewrite the filter coefficients and
// the plist dozens of times a second.
- (void)bandSettled:(UISlider *)slider {
    NSUInteger band = (NSUInteger)slider.tag;
    float snapped = roundf(slider.value);
    slider.value = snapped;
    [[waPlayer shared] setGain:snapped forBand:band];
    [self syncPresetButton];
}

- (void)reset {
    [[waPlayer shared] applyPresetNamed:@"Flat"];
    [[waPlayer shared] setPreampDB:0.0f];
    [self readGains];
    [self syncPresetButton];
}

@end
