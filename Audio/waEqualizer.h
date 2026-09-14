#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

// 5-band master EQ: lowshelf 110Hz (S=0.9), peaks 250/1k/4k, highshelf 12k.
// Plain-C state for the realtime path: the UI thread precomputes immutable
// coeff blocks at set time; render only atomically loads the block pointer.
#define WA_EQ_BANDS 5
#define WA_EQ_MAX_GAIN_DB 12.0f

typedef struct {
    float b0, b1, b2, a1, a2; // normalized (a0 = 1), float: NEON-friendly on ARMv7 VFP
    float z1[2], z2[2];       // per-channel state (TDF-II)
} waEQBand;

// Immutable coeffs published by the UI thread (atomic pointer swap).
typedef struct {
    float b0, b1, b2, a1, a2;
} waEQCoeff;

typedef struct {
    waEQCoeff coeffs[WA_EQ_BANDS];
    float gains[WA_EQ_BANDS];
    float outputTrim; // linear post-gain (<= 1): -max(0, peak +gain), anti-clip
    int bypass;
} waEQCoeffBlock;

// Zeroed filter state published by reset (atomic pointer swap).
typedef struct {
    float z1[WA_EQ_BANDS][2];
    float z2[WA_EQ_BANDS][2];
} waEQStateBlock;

// Reset policy: the render thread zeroes its own state when resetPending is
// observed. Only the render thread writes state, so no allocation is needed
// (a swap would leak a block per track change / seek).

typedef struct {
    double sampleRate;
    float gains[WA_EQ_BANDS]; // dB, written by UI thread
    waEQBand bands[WA_EQ_BANDS]; // legacy, unused by render (see coeffBlock)
    int coefficientsDirty;
    int bypass; // all gains ~0: skip processing
    void * volatile coeffBlock; // atomic waEQCoeffBlock*
    void * volatile stateBlock; // atomic waEQStateBlock*
    volatile int32_t resetPending; // render zeroes state when set
    volatile int32_t activeReaders; // render calls currently holding coeffBlock
} waEqualizer;

void waEQInit(waEqualizer *eq, double sampleRate);
void waEQDeinit(waEqualizer *eq);
void waEQSetGains(waEqualizer *eq, const float *gains);
void waEQReset(waEqualizer *eq); // clear state (call on track change / seek)
void waEQProcess(waEqualizer *eq, SInt16 *samples, UInt32 frames); // interleaved stereo
double waEQFrequencyForBand(int band);
