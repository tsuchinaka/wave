#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

// Simple stereo-linked peak limiter: sits after the EQ, before the int16
// clip. Fixed fast attack (~2ms) + medium release (~120ms), infinite ratio.
// The UI thread publishes immutable param blocks; render only atomically
// loads the block pointer (same lock-free pattern as waEqualizer).
typedef struct {
    float thresholdLinear; // peak level where limiting starts (0..1)
    float attackCoeff;     // envelope attack smoothing (per sample)
    float releaseCoeff;    // envelope release smoothing (per sample)
    int bypass;            // enabled == NO or strength ~0: skip processing
} waCompParamBlock;

typedef struct {
    float envelope; // stereo-linked peak envelope (0..~4)
    float gain;     // smoothed limiter gain (0..1)
} waCompStateBlock;

typedef struct {
    double sampleRate;
    BOOL enabled;     // written by UI thread
    float strength;   // 0..100, written by UI thread
    void * volatile paramBlock; // atomic waCompParamBlock*
    void * volatile stateBlock; // atomic waCompStateBlock*
    volatile int32_t resetPending; // render zeroes state when set (no alloc per track)
    volatile int32_t activeReaders; // render calls currently holding paramBlock
} waCompressor;

void waCompInit(waCompressor *comp, double sampleRate);
void waCompDeinit(waCompressor *comp);
void waCompSetEnabled(waCompressor *comp, BOOL enabled);
void waCompSetStrength(waCompressor *comp, float strength); // 0..100
void waCompReset(waCompressor *comp); // clear envelope/gain (track change/seek)
void waCompProcess(waCompressor *comp, SInt16 *samples, UInt32 frames); // interleaved stereo
