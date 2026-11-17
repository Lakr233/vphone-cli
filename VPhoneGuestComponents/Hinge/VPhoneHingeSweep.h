#pragma once
#include <stdbool.h>
#include <stdint.h>

typedef enum {
    VPhoneHingeProfileContinuous = 0,
    VPhoneHingeProfileFade = 1,
} VPhoneHingeProfile;

typedef struct {
    uint64_t generation;
    uint64_t startedAt;
    double millisecondsPerTick;
    double startAngle;
    double targetAngle;
    double durationMs;
    double previousElapsedMs;
    double previousAngle;
    int32_t profile;
    bool active;
    bool sampled;
} VPhoneHingeSweep;

typedef struct {
    double angle;
    double velocity;
    int32_t phase;
} VPhoneHingeSweepSample;

void VPhoneHingeSweepBegin(VPhoneHingeSweep *sweep, uint64_t now, double millisecondsPerTick,
                         double startAngle, double targetAngle, double durationMs, int32_t profile);
void VPhoneHingeSweepCancel(VPhoneHingeSweep *sweep);
bool VPhoneHingeSweepRead(VPhoneHingeSweep *sweep, uint64_t generation, uint64_t now,
                        VPhoneHingeSweepSample *sample);
