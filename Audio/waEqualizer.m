#import "waEqualizer.h"
#import <libkern/OSAtomic.h>
#import <math.h>
#import <sched.h>

static const double waEQFrequencies[WA_EQ_BANDS] = { 110.0, 250.0, 1000.0, 4000.0, 12000.0 };

// RBJ cookbook biquads. Peaks use Q=1 (alpha = sinW/2). Shelves use the RBJ
// shelf alpha: the low shelf with S=0.9 (gentle) so a bass boost spreads
// 60-300 Hz — where small drivers and ears actually live — instead of piling
// below ~100 Hz and leaving a sucked-out low-mid floor; high shelf keeps S=1.
static void waEQComputeBand(waEQBand *band, int index, double sampleRate, float gainDB) {
    double A = pow(10.0, gainDB / 40.0);
    double w0 = 2.0 * M_PI * waEQFrequencies[index] / sampleRate;
    double cosW = cos(w0);
    double sinW = sin(w0);
    double b0, b1, b2, a0, a1, a2;
    double alpha;
    if (index == 0 || index == WA_EQ_BANDS - 1) {
        double shelfS = index == 0 ? 0.9 : 1.0;
        alpha = sinW / 2.0 * sqrt((A + 1.0 / A) * (1.0 / shelfS - 1.0) + 2.0);
    } else {
        alpha = sinW / 2.0; // peaking, Q = 1
    }
    if (index == 0) {
        // Lowshelf.
        double sqrtA = sqrt(A);
        b0 = A * ((A + 1.0) - (A - 1.0) * cosW + 2.0 * sqrtA * alpha);
        b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cosW);
        b2 = A * ((A + 1.0) - (A - 1.0) * cosW - 2.0 * sqrtA * alpha);
        a0 = (A + 1.0) + (A - 1.0) * cosW + 2.0 * sqrtA * alpha;
        a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cosW);
        a2 = (A + 1.0) + (A - 1.0) * cosW - 2.0 * sqrtA * alpha;
    } else if (index == WA_EQ_BANDS - 1) {
        // Highshelf.
        double sqrtA = sqrt(A);
        b0 = A * ((A + 1.0) + (A - 1.0) * cosW + 2.0 * sqrtA * alpha);
        b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cosW);
        b2 = A * ((A + 1.0) + (A - 1.0) * cosW - 2.0 * sqrtA * alpha);
        a0 = (A + 1.0) - (A - 1.0) * cosW + 2.0 * sqrtA * alpha;
        a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cosW);
        a2 = (A + 1.0) - (A - 1.0) * cosW - 2.0 * sqrtA * alpha;
    } else {
        // Peaking, Q = 1.
        b0 = 1.0 + alpha * A;
        b1 = -2.0 * cosW;
        b2 = 1.0 - alpha * A;
        a0 = 1.0 + alpha / A;
        a1 = -2.0 * cosW;
        a2 = 1.0 - alpha / A;
    }
    band->b0 = (float)(b0 / a0);
    band->b1 = (float)(b1 / a0);
    band->b2 = (float)(b2 / a0);
    band->a1 = (float)(a1 / a0);
    band->a2 = (float)(a2 / a0);
}

void waEQInit(waEqualizer *eq, double sampleRate) {
    if (!eq) return;
    eq->sampleRate = sampleRate > 0.0 ? sampleRate : 44100.0;
    for (int i = 0; i < WA_EQ_BANDS; i++) {
        eq->gains[i] = 0.0f;
        waEQComputeBand(&eq->bands[i], i, eq->sampleRate, 0.0f);
        eq->bands[i].z1[0] = eq->bands[i].z1[1] = 0.0;
        eq->bands[i].z2[0] = eq->bands[i].z2[1] = 0.0;
    }
    eq->coefficientsDirty = 0;
    eq->bypass = 1;
    // Publish initial immutable coeff/state blocks for the lock-free path.
    waEQCoeffBlock *coeffs = malloc(sizeof(waEQCoeffBlock));
    waEQStateBlock *state = malloc(sizeof(waEQStateBlock));
    if (coeffs) {
        for (int i = 0; i < WA_EQ_BANDS; i++) {
            coeffs->coeffs[i].b0 = eq->bands[i].b0;
            coeffs->coeffs[i].b1 = eq->bands[i].b1;
            coeffs->coeffs[i].b2 = eq->bands[i].b2;
            coeffs->coeffs[i].a1 = eq->bands[i].a1;
            coeffs->coeffs[i].a2 = eq->bands[i].a2;
            coeffs->gains[i] = 0.0f;
        }
        coeffs->outputTrim = 1.0f;
        coeffs->bypass = 1;
    }
    if (state) {
        for (int i = 0; i < WA_EQ_BANDS; i++)
            for (int ch = 0; ch < 2; ch++) state->z1[i][ch] = state->z2[i][ch] = 0.0;
    }
    OSMemoryBarrier();
    eq->coeffBlock = coeffs;
    eq->stateBlock = state;
    eq->resetPending = 0;
    eq->activeReaders = 0;
    OSMemoryBarrier();
}

void waEQDeinit(waEqualizer *eq) {
    if (!eq) return;
    // The mixer disposes its AudioQueue before calling this, so no render
    // callback can still hold either block.
    free((void *)eq->coeffBlock);
    free((void *)eq->stateBlock);
    eq->coeffBlock = NULL;
    eq->stateBlock = NULL;
    eq->activeReaders = 0;
}

static NSObject *waEQLock(void) {
    static NSObject *lock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [[NSObject alloc] init]; });
    return lock;
}

// Composite magnitude peak over 20 Hz..20 kHz (64 log points), evaluated on
// the UI thread from the just-computed biquads. Trimming by exactly this
// peak guarantees no steady-state tone can clip because of the EQ, whatever
// the sliders say — the tilt is preserved 1:1, only absolute level moves.
// (The old max-slider-gain heuristic under-guessed stacked boosts and
// over-guessed lonely ones: Bass Booster burned, lonely shelves went quiet.)
static double waEQCompositePeak(waEQBand *bands, double sampleRate) {
    if (!bands || !(sampleRate > 0.0)) return 1.0;
    double peak = 1.0;
    for (int k = 0; k < 64; k++) {
        double freq = 20.0 * pow(1000.0, (double)k / 63.0);
        double w = 2.0 * M_PI * freq / sampleRate;
        double c1 = cos(w), s1 = sin(w);
        double c2 = c1 * c1 - s1 * s1, s2 = 2.0 * c1 * s1;
        double power = 1.0;
        for (int i = 0; i < WA_EQ_BANDS; i++) {
            double nr = bands[i].b0 + bands[i].b1 * c1 + bands[i].b2 * c2;
            double ni = -(bands[i].b1 * s1 + bands[i].b2 * s2);
            double dr = 1.0 + bands[i].a1 * c1 + bands[i].a2 * c2;
            double di = -(bands[i].a1 * s1 + bands[i].a2 * s2);
            double den = dr * dr + di * di;
            if (!(den > 1e-12)) return 4.0; // unreachable for RBJ: safe attenuate
            power *= (nr * nr + ni * ni) / den;
            if (!(power < 1e8)) return 4.0;
        }
        double mag = sqrt(power);
        if (mag > peak) peak = mag;
    }
    return peak;
}

void waEQSetGains(waEqualizer *eq, const float *gains) {
    if (!eq || !gains) return;
    // Serialize concurrent UI setters; render never takes this lock.
    @synchronized(waEQLock()) {
        float clamped[WA_EQ_BANDS];
        int allZero = 1;
        int unchanged = 1;
        for (int i = 0; i < WA_EQ_BANDS; i++) {
            float c = gains[i];
            if (c > WA_EQ_MAX_GAIN_DB) c = WA_EQ_MAX_GAIN_DB;
            if (c < -WA_EQ_MAX_GAIN_DB) c = -WA_EQ_MAX_GAIN_DB;
            clamped[i] = c;
            if (c != eq->gains[i]) unchanged = 0;
            if (c > 0.01f || c < -0.01f) allZero = 0;
        }
        // Called every track with the same prefs: skip the malloc/publish
        // when nothing changed.
        if (unchanged && ((allZero != 0) == (eq->bypass != 0))) return;
        for (int i = 0; i < WA_EQ_BANDS; i++) eq->gains[i] = clamped[i];
        eq->bypass = allZero;
        eq->coefficientsDirty = 0;
        // Precompute coeffs on the UI thread (pow/cos/sin/sqrt off render).
        waEQCoeffBlock *block = malloc(sizeof(waEQCoeffBlock));
        if (!block) return;
        waEQBand tmps[WA_EQ_BANDS];
        for (int i = 0; i < WA_EQ_BANDS; i++) waEQComputeBand(&tmps[i], i, eq->sampleRate, clamped[i]);
        for (int i = 0; i < WA_EQ_BANDS; i++) {
            block->coeffs[i].b0 = tmps[i].b0;
            block->coeffs[i].b1 = tmps[i].b1;
            block->coeffs[i].b2 = tmps[i].b2;
            block->coeffs[i].a1 = tmps[i].a1;
            block->coeffs[i].a2 = tmps[i].a2;
            block->gains[i] = clamped[i];
        }
        // Auto-gain: trim by the true composite peak plus 0.5 dB safety.
        // Cuts-only (peak <= 1) need no trim. Transients above the
        // steady-state peak are the limiter's job downstream.
        float trim = 1.0f;
        double peakMag = waEQCompositePeak(tmps, eq->sampleRate);
        if (peakMag > 1.0) {
            trim = (float)(pow(10.0, -0.5 / 20.0) / peakMag);
            if (!(trim >= 0.01f)) trim = 0.01f;
            if (trim > 1.0f) trim = 1.0f;
        }
        block->outputTrim = trim;
        block->bypass = allZero;
        OSMemoryBarrier();
        // Atomic publish. The render-side reader count makes it safe to
        // reclaim the old immutable block after the swap.
        void *old = NULL;
        do {
            old = eq->coeffBlock;
            OSMemoryBarrier();
        } while (!OSAtomicCompareAndSwapPtrBarrier(old, block, &eq->coeffBlock));
        OSMemoryBarrier();
        while (OSAtomicAdd32Barrier(0, &eq->activeReaders) != 0) sched_yield();
        free(old);
    }
}

void waEQReset(waEqualizer *eq) {
    if (!eq) return;
    // No allocation here: render adopts the reset and zeroes its own state
    // (only the render thread writes state). Fixes the per-call leak.
    OSMemoryBarrier();
    eq->resetPending = 1;
    OSMemoryBarrier();
}

void waEQProcess(waEqualizer *eq, SInt16 *samples, UInt32 frames) {
    if (!eq || !samples || frames == 0) return;
    OSAtomicAdd32Barrier(1, &eq->activeReaders);
    OSMemoryBarrier();
    waEQCoeffBlock *coeffs = (waEQCoeffBlock *)eq->coeffBlock;
    waEQStateBlock *state = (waEQStateBlock *)eq->stateBlock;
    OSMemoryBarrier();
    if (!coeffs || !state || coeffs->bypass) {
        OSAtomicAdd32Barrier(-1, &eq->activeReaders);
        return;
    }
    float trim = coeffs->outputTrim;
    if (!(trim > 0.0f) || trim > 1.0f) trim = 1.0f;
    // Adopt a pending reset on the render thread (only writer of state).
    OSMemoryBarrier();
    if (eq->resetPending) {
        for (int i = 0; i < WA_EQ_BANDS; i++)
            for (int ch = 0; ch < 2; ch++) state->z1[i][ch] = state->z2[i][ch] = 0.0;
        OSMemoryBarrier();
        eq->resetPending = 0;
        OSMemoryBarrier();
    }
    for (UInt32 frame = 0; frame < frames; frame++) {
        for (int ch = 0; ch < 2; ch++) {
            float x = (float)samples[frame * 2 + ch];
            for (int i = 0; i < WA_EQ_BANDS; i++) {
                float y = coeffs->coeffs[i].b0 * x + state->z1[i][ch];
                state->z1[i][ch] = coeffs->coeffs[i].b1 * x - coeffs->coeffs[i].a1 * y + state->z2[i][ch];
                state->z2[i][ch] = coeffs->coeffs[i].b2 * x - coeffs->coeffs[i].a2 * y;
                x = y;
            }
            x *= trim;
            // Denormal guard: flush tiny output to zero before clamping.
            if (x < 1e-30f && x > -1e-30f) x = 0.0f;
            if (x > 32767.0f) x = 32767.0f;
            else if (x < -32768.0f) x = -32768.0f;
            samples[frame * 2 + ch] = (SInt16)x;
        }
    }
    // Denormal guard: flush tiny filter state to zero after each buffer.
    for (int i = 0; i < WA_EQ_BANDS; i++) {
        for (int ch = 0; ch < 2; ch++) {
            if (fabsf(state->z1[i][ch]) < 1e-30f) state->z1[i][ch] = 0.0f;
            if (fabsf(state->z2[i][ch]) < 1e-30f) state->z2[i][ch] = 0.0f;
        }
    }
    OSAtomicAdd32Barrier(-1, &eq->activeReaders);
}

double waEQFrequencyForBand(int band) {
    if (band < 0 || band >= WA_EQ_BANDS) return 0.0;
    return waEQFrequencies[band];
}
