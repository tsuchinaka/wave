#import "waEQViewController.h"
#import "../Models/waPreferences.h"
#import "../Services/waTheme.h"
#import "../Audio/waAudioEngine.h"
#import "../Audio/waEqualizer.h"
#import "../Views/waActions.h"
#import "../Views/waAction.h"

@interface waEQViewController ()
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) NSMutableArray *sliders;
@property (nonatomic, strong) NSMutableArray *valueLabels;
@property (nonatomic, strong) UIButton *presetButton;
@property (nonatomic, strong) UISwitch *compSwitch;
@property (nonatomic, strong) UISlider *compSlider;
@property (nonatomic, strong) UILabel *compValueLabel;
@end

@implementation waEQViewController

+ (NSDictionary *)presets {
    return @{
        @"Flat": @[@0, @0, @0, @0, @0],
        @"Rock": @[@6, @2, @-3, @2, @5],
        @"Pop": @[@0, @3, @5, @3, @1],
        @"Jazz": @[@3, @1, @0, @2, @4],
        @"Classical": @[@4, @2, @0, @2, @4],
        @"Bass Booster": @[@6, @3, @0, @0, @0]
    };
}

+ (NSArray *)presetNames {
    return @[@"Flat", @"Rock", @"Pop", @"Jazz", @"Classical", @"Bass Booster"];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.title = @"Equalizer";
    [waTheme applyToView:self.view];
    self.view.backgroundColor = [waTheme backgroundColor];

    self.sliders = [NSMutableArray array];
    self.valueLabels = [NSMutableArray array];
    NSArray *gains = [waPreferences sharedPreferences].equalizerGains;

    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scrollView.backgroundColor = [UIColor clearColor];
    [self.view addSubview:scrollView];
    self.scrollView = scrollView;
    UIView *content = scrollView;

    CGFloat y = 8.0;
    for (int band = 0; band < WA_EQ_BANDS; band++) {
        double frequency = waEQFrequencyForBand(band);
        NSString *bandTitle = frequency >= 1000.0 ? [NSString stringWithFormat:@"%.0f kHz", frequency / 1000.0] : [NSString stringWithFormat:@"%.0f Hz", frequency];

        UILabel *nameLabel = [[UILabel alloc] initWithFrame:CGRectMake(16.0, y, 110.0, 22.0)];
        nameLabel.text = bandTitle;
        nameLabel.font = [waTheme mediumFontOfSize:15.0];
        nameLabel.textColor = [waTheme primaryTextColor];
        nameLabel.backgroundColor = [UIColor clearColor];
        nameLabel.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
        [content addSubview:nameLabel];

        UILabel *valueLabel = [[UILabel alloc] initWithFrame:CGRectMake(self.view.bounds.size.width - 86.0, y, 70.0, 22.0)];
        valueLabel.textAlignment = NSTextAlignmentRight;
        valueLabel.font = [waTheme secondaryRegularFontOfSize:13.0];
        valueLabel.textColor = [waTheme secondaryTextColor];
        valueLabel.backgroundColor = [UIColor clearColor];
        valueLabel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
        [content addSubview:valueLabel];
        [self.valueLabels addObject:valueLabel];

        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(16.0, y + 20.0, self.view.bounds.size.width - 32.0, 28.0)];
        slider.minimumValue = -WA_EQ_MAX_GAIN_DB;
        slider.maximumValue = WA_EQ_MAX_GAIN_DB;
        slider.value = [[gains objectAtIndex:band] floatValue];
        slider.tag = band;
        slider.continuous = YES;
        slider.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
        [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        [slider addTarget:self action:@selector(sliderDragEnded:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        [waTheme applyToView:slider];
        [content addSubview:slider];
        [self.sliders addObject:slider];

        [self updateValueLabelForBand:band];
        y += 52.0;
    }

    UIButton *presetButton = [UIButton buttonWithType:UIButtonTypeCustom];
    presetButton.frame = CGRectMake(16.0, y + 4.0, self.view.bounds.size.width - 32.0, 40.0);
    presetButton.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
    [waTheme applySkeuomorphicStyleToButton:presetButton];
    presetButton.titleLabel.font = [waTheme boldFontOfSize:17.0];
    [presetButton addTarget:self action:@selector(showPresets) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:presetButton];
    self.presetButton = presetButton;
    [self updatePresetButton];
    y += 56.0;

    // Compressor section: On/Off + single Strength slider.
    UILabel *compTitle = [[UILabel alloc] initWithFrame:CGRectMake(16.0, y, self.view.bounds.size.width - 32.0, 22.0)];
    compTitle.text = @"Compressor";
    compTitle.font = [waTheme mediumFontOfSize:15.0];
    compTitle.textColor = [waTheme primaryTextColor];
    compTitle.backgroundColor = [UIColor clearColor];
    compTitle.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
    [content addSubview:compTitle];
    y += 24.0;

    UILabel *enableLabel = [[UILabel alloc] initWithFrame:CGRectMake(16.0, y, 200.0, 31.0)];
    enableLabel.text = @"Limit loud peaks";
    enableLabel.font = [waTheme secondaryRegularFontOfSize:13.0];
    enableLabel.textColor = [waTheme secondaryTextColor];
    enableLabel.backgroundColor = [UIColor clearColor];
    enableLabel.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
    [content addSubview:enableLabel];

    UISwitch *compSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(self.view.bounds.size.width - 16.0 - 79.0, y, 79.0, 27.0)];
    compSwitch.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    compSwitch.on = [waPreferences sharedPreferences].compressorEnabled;
    [compSwitch addTarget:self action:@selector(compEnabledChanged:) forControlEvents:UIControlEventValueChanged];
    [content addSubview:compSwitch];
    self.compSwitch = compSwitch;
    y += 37.0;

    UILabel *strengthLabel = [[UILabel alloc] initWithFrame:CGRectMake(16.0, y, 110.0, 22.0)];
    strengthLabel.text = @"Strength";
    strengthLabel.font = [waTheme mediumFontOfSize:15.0];
    strengthLabel.textColor = [waTheme primaryTextColor];
    strengthLabel.backgroundColor = [UIColor clearColor];
    strengthLabel.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
    [content addSubview:strengthLabel];

    UILabel *compValueLabel = [[UILabel alloc] initWithFrame:CGRectMake(self.view.bounds.size.width - 86.0, y, 70.0, 22.0)];
    compValueLabel.textAlignment = NSTextAlignmentRight;
    compValueLabel.font = [waTheme secondaryRegularFontOfSize:13.0];
    compValueLabel.textColor = [waTheme secondaryTextColor];
    compValueLabel.backgroundColor = [UIColor clearColor];
    compValueLabel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    [content addSubview:compValueLabel];
    self.compValueLabel = compValueLabel;

    UISlider *compSlider = [[UISlider alloc] initWithFrame:CGRectMake(16.0, y + 20.0, self.view.bounds.size.width - 32.0, 28.0)];
    compSlider.minimumValue = 0.0f;
    compSlider.maximumValue = 100.0f;
    compSlider.value = [waPreferences sharedPreferences].compressorStrength;
    compSlider.continuous = YES;
    compSlider.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
    [compSlider addTarget:self action:@selector(compStrengthChanged:) forControlEvents:UIControlEventValueChanged];
    [compSlider addTarget:self action:@selector(compStrengthDragEnded:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [waTheme applyToView:compSlider];
    [content addSubview:compSlider];
    self.compSlider = compSlider;
    [self updateCompValueLabel];
    y += 56.0;

    scrollView.contentSize = CGSizeMake(self.view.bounds.size.width, y);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [waTheme applyToView:self.view];
    self.view.backgroundColor = [waTheme backgroundColor];
    [waTheme applySkeuomorphicStyleToButton:self.presetButton];
    for (UISlider *slider in self.sliders) {
        slider.minimumTrackTintColor = [waTheme barColor];
        slider.maximumTrackTintColor = [UIColor colorWithWhite:1.0 alpha:0.45];
        slider.thumbTintColor = [waTheme isModernSystem] ? nil : [waTheme barColor];
    }
    self.compSlider.minimumTrackTintColor = [waTheme barColor];
    self.compSlider.maximumTrackTintColor = [UIColor colorWithWhite:1.0 alpha:0.45];
    self.compSlider.thumbTintColor = [waTheme isModernSystem] ? nil : [waTheme barColor];
}

- (NSString *)stringForGain:(float)gain {
    return [NSString stringWithFormat:@"%+.0f dB", gain];
}

- (void)updateValueLabelForBand:(NSInteger)band {
    UISlider *slider = [self.sliders objectAtIndex:band];
    ((UILabel *)[self.valueLabels objectAtIndex:band]).text = [self stringForGain:slider.value];
}

- (void)updatePresetButton {
    NSString *preset = [waPreferences sharedPreferences].equalizerPreset;
    [self.presetButton setTitle:[NSString stringWithFormat:@"Preset: %@", preset] forState:UIControlStateNormal];
}

- (void)sliderChanged:(UISlider *)slider {
    // Live DSP update only: the gains publish is lock-free and cheap, but
    // persisting to NSUserDefaults on every tick of a continuous slider
    // turned each drag into dozens of plist writes.
    [self updateValueLabelForBand:slider.tag];
    float gains[WA_EQ_BANDS];
    for (int band = 0; band < WA_EQ_BANDS; band++) gains[band] = ((UISlider *)[self.sliders objectAtIndex:band]).value;
    [[waAudioEngine sharedEngine] setEqualizerGains:gains];
}

- (void)sliderDragEnded:(UISlider *)slider {
    (void)slider;
    NSMutableArray *stored = [NSMutableArray arrayWithCapacity:WA_EQ_BANDS];
    for (int band = 0; band < WA_EQ_BANDS; band++) [stored addObject:@(((UISlider *)[self.sliders objectAtIndex:band]).value)];
    waPreferences *preferences = [waPreferences sharedPreferences];
    preferences.equalizerGains = stored;
    preferences.equalizerPreset = @"Custom";
    [self updatePresetButton];
}

- (void)updateCompValueLabel {
    self.compValueLabel.text = [NSString stringWithFormat:@"%.0f", self.compSlider.value];
}

- (void)compEnabledChanged:(UISwitch *)sender {
    [[waAudioEngine sharedEngine] setCompressorEnabled:sender.on];
    [waPreferences sharedPreferences].compressorEnabled = sender.on;
}

- (void)compStrengthChanged:(UISlider *)slider {
    [self updateCompValueLabel];
    [[waAudioEngine sharedEngine] setCompressorStrength:slider.value];
}

- (void)compStrengthDragEnded:(UISlider *)slider {
    [waPreferences sharedPreferences].compressorStrength = slider.value;
}
- (void)applyGainsMarkingPreset:(NSString *)preset {
    float gains[WA_EQ_BANDS];
    NSMutableArray *stored = [NSMutableArray arrayWithCapacity:WA_EQ_BANDS];
    for (int band = 0; band < WA_EQ_BANDS; band++) {
        gains[band] = ((UISlider *)[self.sliders objectAtIndex:band]).value;
        [stored addObject:@(gains[band])];
    }
    [[waAudioEngine sharedEngine] setEqualizerGains:gains];
    waPreferences *preferences = [waPreferences sharedPreferences];
    preferences.equalizerGains = stored;
    preferences.equalizerPreset = preset ?: @"Custom";
    [self updatePresetButton];
}

- (void)showPresets {
    __weak waEQViewController *weakSelf = self;
    NSMutableArray *actions = [NSMutableArray array];
    for (NSString *name in [[self class] presetNames]) {
        NSArray *presetGains = [[[self class] presets] objectForKey:name];
        [actions addObject:[waAction actionWithIdentifier:[@"eq.preset." stringByAppendingString:name] title:name handler:^(id object) {
            (void)object;
            waEQViewController *controller = weakSelf;
            if (!controller) return;
            for (int band = 0; band < WA_EQ_BANDS; band++) {
                ((UISlider *)[controller.sliders objectAtIndex:band]).value = [[presetGains objectAtIndex:band] floatValue];
                [controller updateValueLabelForBand:band];
            }
            [controller applyGainsMarkingPreset:name];
        }]];
    }
    [[waActions sharedActions] presentTitle:@"Equalizer Preset" actions:actions object:nil fromViewController:self];
}

@end
