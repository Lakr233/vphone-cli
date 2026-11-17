#include "VPhoneHingeSweep.h"
#include <math.h>

// Continuous folds use smoothstep; fade folds dwell at each end of a cosine ease.
static double VPhoneHingeProgress(double t, int32_t profile) {
    if (profile == VPhoneHingeProfileFade) {
        if (t < 0.1)
            return 0;
        if (t > 0.9)
            return 1;
        return (1 - cos(3.14159265358979323846 * (t - 0.1) / 0.8)) / 2;
    }
    return t * t * (3 - 2 * t);
}

void VPhoneHingeSweepBegin(VPhoneHingeSweep *sweep, uint64_t now, double millisecondsPerTick,
                         double startAngle, double targetAngle, double durationMs, int32_t profile) {
    *sweep = (VPhoneHingeSweep){
        .generation = sweep->generation + 1,
        .startedAt = now,
        .millisecondsPerTick = millisecondsPerTick,
        .startAngle = startAngle,
        .targetAngle = targetAngle,
        .durationMs = durationMs,
        .previousAngle = startAngle,
        .profile = profile,
        .active = true,
    };
}

void VPhoneHingeSweepCancel(VPhoneHingeSweep *sweep) {
    sweep->active = false;
    sweep->generation++;
}

bool VPhoneHingeSweepRead(VPhoneHingeSweep *sweep, uint64_t generation, uint64_t now,
                        VPhoneHingeSweepSample *sample) {
    if (!sweep->active || generation != sweep->generation || now <= sweep->startedAt)
        return false;
    double elapsed = (double)(now - sweep->startedAt) * sweep->millisecondsPerTick;
    if (elapsed <= sweep->previousElapsedMs)
        return false;
    bool finished = elapsed >= sweep->durationMs;
    double angle = finished ? sweep->targetAngle : sweep->startAngle +
        (sweep->targetAngle - sweep->startAngle) * VPhoneHingeProgress(elapsed / sweep->durationMs, sweep->profile);
    *sample = (VPhoneHingeSweepSample){
        .angle = angle,
        .velocity = (angle - sweep->previousAngle) / ((elapsed - sweep->previousElapsedMs) / 1000.0),
        .phase = finished ? 3 : sweep->sampled ? 2 : 1,
    };
    sweep->previousAngle = angle;
    sweep->previousElapsedMs = elapsed;
    sweep->sampled = true;
    sweep->active = !finished;
    return true;
}
