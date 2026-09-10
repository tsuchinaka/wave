#import "waCompressor.h"
#import <libkern/OSAtomic.h>
#import <math.h>

static float waCompThresholdForStrength(float strength) {
    // Strength 0 -> -3dB (0.708), 100 -> -18dB (0.126). UI clamps 0..100.
    float db = -3.0f - (strength / 100.0f) * 15.0f;
    return powf(10.0f, db / 20.0f);
}

static void waCompFillParams(waCompParamBlock *block, double sampleRate, BOOL enabled, float strength) {
    if (strength < 0.0f) strength = 0.0f;
    if (strength > 100.0f) strength = 100.0f;
    block->thresholdLinear = waCompThresholdForStrength(strength);
    if (sampleRate <= 0.0) sampleRate = 44100.0;
    // attack ~2ms, release ~120ms -> per-sample one-pole smoothing coeffs.
    block->attackCoeff = expf(-1.0f / (float)(0.002 * sampleRate));
    block->releaseCoeff = expf(-1.0f / (float)(0.120 * sampleRate));
    block->bypass = (!enabled || strength < 0.5f) ? 1 : 0;
}

void waCompInit(waCompressor *comp, double sampleRate) {
    if (!comp) return;
    comp->sampleRate = sampleRate > 0.0 ? sampleRate : 44100.0;
    comp->enabled = YES;
    comp->strength = 60.0f;
    waCompParamBlock *params = malloc(sizeof(waCompParamBlock));
    waCompStateBlock *state = malloc(sizeof(waCompStateBlock));
    if (params) waCompFillParams(params, comp->sampleRate, YES, 60.0f);
    if (state) { state->envelope = 0.0f; state->gain = 1.0f; }
    OSMemoryBarrier();
    comp->paramBlock = params;
    comp->stateBlock = state;
    comp->resetPending = 0;
    OSMemoryBarrier();
}

static void waCompPublishParams(waCompressor *comp) {
    waCompParamBlock *block = malloc(sizeof(waCompParamBlock));
    if (!block) return;
    waCompFillParams(block, comp->sampleRate, comp->enabled, comp->strength);
    OSMemoryBarrier();
    void *old = NULL;
    do {
        old = comp->paramBlock;
        OSMemoryBarrier();
    } while (!OSAtomicCompareAndSwapPtr(old, block, &comp->paramBlock));
    OSMemoryBarrier();
    // Old blocks leak (tiny, bounded by UI edits) to avoid freeing memory
    // the render thread may still be reading. Same policy as waEqualizer.
}

void waCompSetEnabled(waCompressor *comp, BOOL enabled) {
    if (!comp) return;
    BOOL next = enabled ? YES : NO;
    if (comp->enabled == next) return;
    comp->enabled = next;
    waCompPublishParams(comp);
}

void waCompSetStrength(waCompressor *comp, float strength) {
    if (!comp) return;
    if (strength < 0.0f) strength = 0.0f;
    if (strength > 100.0f) strength = 100.0f;
    if (comp->strength == strength) return;
    comp->strength = strength;
    waCompPublishParams(comp);
}

void waCompReset(waCompressor *comp) {
    if (!comp) return;
    // No allocation: render adopts the reset and zeroes its own state
    // (only the render thread writes state). Fixes per-track/per-seek leak.
    OSMemoryBarrier();
    comp->resetPending = 1;
    OSMemoryBarrier();
}

void waCompProcess(waCompressor *comp, SInt16 *samples, UInt32 frames) {
    if (!comp || !samples || frames == 0) return;
    OSMemoryBarrier();
    waCompParamBlock *params = (waCompParamBlock *)comp->paramBlock;
    waCompStateBlock *state = (waCompStateBlock *)comp->stateBlock;
    OSMemoryBarrier();
    if (!params || !state || params->bypass) return;
    // Adopt a pending reset on the render thread (only writer of state).
    OSMemoryBarrier();
    if (comp->resetPending) {
        state->envelope = 0.0f;
        state->gain = 1.0f;
        OSMemoryBarrier();
        comp->resetPending = 0;
        OSMemoryBarrier();
    }
    float threshold = params->thresholdLinear;
    float attack = params->attackCoeff;
    float release = params->releaseCoeff;
    float envelope = state->envelope;
    float gain = state->gain;
    for (UInt32 frame = 0; frame < frames; frame++) {
        float l = (float)samples[frame * 2] / 32768.0f;
        float r = (float)samples[frame * 2 + 1] / 32768.0f;
        float peak = fabsf(l) > fabsf(r) ? fabsf(l) : fabsf(r);
        // Stereo-linked peak envelope: fast attack, slow release.
        if (peak > envelope) envelope = attack * envelope + (1.0f - attack) * peak;
        else envelope = release * envelope + (1.0f - release) * peak;
        // Infinite-ratio target gain above threshold, smoothed with the
        // same attack/release so limiting has no clicks.
        float target = 1.0f;
        if (envelope > threshold && envelope > 1e-6f) target = threshold / envelope;
        if (target < gain) gain = attack * gain + (1.0f - attack) * target;
        else gain = release * gain + (1.0f - release) * target;
        float gl = l * gain;
        float gr = r * gain;
        // Denormal guard before storing back.
        if (gl < 1e-30f && gl > -1e-30f) gl = 0.0f;
        if (gr < 1e-30f && gr > -1e-30f) gr = 0.0f;
        SInt32 ol = (SInt32)(gl * 32768.0f);
        SInt32 orr = (SInt32)(gr * 32768.0f);
        if (ol > 32767) ol = 32767;
        else if (ol < -32768) ol = -32768;
        if (orr > 32767) orr = 32767;
        else if (orr < -32768) orr = -32768;
        samples[frame * 2] = (SInt16)ol;
        samples[frame * 2 + 1] = (SInt16)orr;
    }
    if (envelope < 1e-30f) envelope = 0.0f;
    if (gain != gain || gain < 0.0f) gain = 1.0f; // NaN guard, never lock silent
    if (gain > 1.0f) gain = 1.0f;
    state->envelope = envelope;
    state->gain = gain;
}
