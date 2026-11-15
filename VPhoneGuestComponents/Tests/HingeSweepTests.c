#include "../Hinge/VPhoneHingeSweep.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

static void near(double actual, double expected) {
    assert(fabs(actual - expected) < 0.000001);
}

static void delayedCallbacks(void) {
    VPhoneHingeSweep sweep = {0};
    VPhoneHingeSweepSample sample;
    VPhoneHingeSweepBegin(&sweep, 1000, 1, 0, 100, 600, VPhoneHingeProfileContinuous);
    uint64_t generation = sweep.generation;
    assert(VPhoneHingeSweepRead(&sweep, generation, 1300, &sample));
    near(sample.angle, 50);
    near(sample.velocity, 50 / 0.3);
    assert(sample.phase == 1);
    assert(VPhoneHingeSweepRead(&sweep, generation, 1900, &sample));
    near(sample.angle, 100);
    near(sample.velocity, 50 / 0.6);
    assert(sample.phase == 3 && !sweep.active);
    assert(!VPhoneHingeSweepRead(&sweep, generation, 2000, &sample));

    VPhoneHingeSweepBegin(&sweep, 1000, 1, 0, 100, 600, VPhoneHingeProfileContinuous);
    assert(VPhoneHingeSweepRead(&sweep, sweep.generation, 1900, &sample));
    near(sample.angle, 100);
    near(sample.velocity, 100 / 0.9);
    assert(sample.phase == 3);
}

static void sampleIntervals(void) {
    VPhoneHingeSweep sweep = {0};
    VPhoneHingeSweepSample sample;
    VPhoneHingeSweepBegin(&sweep, 1000, 1, 0, 100, 600, VPhoneHingeProfileContinuous);
    uint64_t generation = sweep.generation;
    assert(!VPhoneHingeSweepRead(&sweep, generation, 999, &sample));
    assert(!VPhoneHingeSweepRead(&sweep, generation, 1000, &sample));
    assert(VPhoneHingeSweepRead(&sweep, generation, 1100, &sample));
    double firstAngle = sample.angle;
    assert(!VPhoneHingeSweepRead(&sweep, generation, 1100, &sample));
    assert(VPhoneHingeSweepRead(&sweep, generation, 1400, &sample));
    near(sample.angle, 100 * 20.0 / 27.0);
    near(sample.velocity, (sample.angle - firstAngle) / 0.3);
    assert(sample.phase == 2);

    // A large clock origin must be subtracted before converting ticks to double.
    uint64_t origin = UINT64_C(1) << 60;
    VPhoneHingeSweepBegin(&sweep, origin, 0.25, 0, 100, 600, VPhoneHingeProfileContinuous);
    assert(VPhoneHingeSweepRead(&sweep, sweep.generation, origin + 1200, &sample));
    near(sample.angle, 50);
}

static void fadeAndCancellation(void) {
    VPhoneHingeSweep sweep = {0};
    VPhoneHingeSweepSample sample;
    VPhoneHingeSweepBegin(&sweep, 1000, 1, 0, 100, 600, VPhoneHingeProfileFade);
    uint64_t generation = sweep.generation;
    assert(VPhoneHingeSweepRead(&sweep, generation, 1030, &sample));
    near(sample.angle, 0);
    assert(sample.phase == 1);
    assert(VPhoneHingeSweepRead(&sweep, generation, 1300, &sample));
    near(sample.angle, 50);
    assert(VPhoneHingeSweepRead(&sweep, generation, 1570, &sample));
    near(sample.angle, 100);
    assert(sample.phase == 2);
    assert(VPhoneHingeSweepRead(&sweep, generation, 1600, &sample));
    near(sample.angle, 100);
    assert(sample.phase == 3);

    VPhoneHingeSweepBegin(&sweep, 2000, 1, 0, 100, 600, VPhoneHingeProfileContinuous);
    generation = sweep.generation;
    assert(VPhoneHingeSweepRead(&sweep, generation, 2300, &sample));
    VPhoneHingeSweepBegin(&sweep, 2300, 1, sample.angle, 0, 800, VPhoneHingeProfileContinuous);
    assert(!VPhoneHingeSweepRead(&sweep, generation, 2400, &sample));
    assert(VPhoneHingeSweepRead(&sweep, sweep.generation, 2700, &sample));
    near(sample.angle, 25);
    near(sample.velocity, -25 / 0.4);
    assert(sample.phase == 1);
    generation = sweep.generation;
    VPhoneHingeSweepCancel(&sweep);
    assert(!VPhoneHingeSweepRead(&sweep, generation, 3100, &sample));
    near(sweep.previousAngle, 25);
}

int main(void) {
    delayedCallbacks();
    sampleIntervals();
    fadeAndCancellation();
    puts("Hinge sweep timing tests passed");
    return 0;
}
