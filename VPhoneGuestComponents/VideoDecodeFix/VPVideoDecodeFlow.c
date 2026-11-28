#include "VPVideoDecodeFlow.h"

#include <assert.h>
#include <string.h>

static uint64_t elapsed(uint64_t start, uint64_t end) {
    return end >= start ? end - start : 0;
}

static uint64_t sum(uint64_t left, uint64_t right) {
    return UINT64_MAX - left >= right ? left + right : UINT64_MAX;
}

bool VPVideoDecodeFlowInit(VPVideoDecodeFlow *flow) {
    memset(flow, 0, sizeof(*flow));
    if (pthread_mutex_init(&flow->mutex, NULL)) return false;
    if (pthread_cond_init(&flow->changed, NULL)) {
        pthread_mutex_destroy(&flow->mutex);
        return false;
    }
    return true;
}

void VPVideoDecodeFlowDestroy(VPVideoDecodeFlow *flow) {
    assert(!flow->outputs && !flow->callbacks && !flow->invalidating);
    pthread_cond_destroy(&flow->changed);
    pthread_mutex_destroy(&flow->mutex);
}

bool VPVideoDecodeBeginOutput(VPVideoDecodeFlow *flow) {
    pthread_mutex_lock(&flow->mutex);
    bool admitted = !flow->invalidating && !flow->invalidated;
    if (admitted) flow->outputs++;
    pthread_mutex_unlock(&flow->mutex);
    return admitted;
}

void VPVideoDecodeEndOutput(VPVideoDecodeFlow *flow) {
    pthread_mutex_lock(&flow->mutex);
    assert(flow->outputs);
    if (--flow->outputs == 0) pthread_cond_broadcast(&flow->changed);
    pthread_mutex_unlock(&flow->mutex);
}

static void stopClock(VPVideoDecodeFlow *flow, uint64_t now) {
    if (!flow->clockStopped && flow->callbacks)
        flow->callbackNanoseconds = sum(flow->callbackNanoseconds, elapsed(flow->callbackStart, now));
    flow->clockStopped = true;
}

bool VPVideoDecodeBeginInvalidation(VPVideoDecodeFlow *flow, uint64_t now) {
    pthread_mutex_lock(&flow->mutex);
    while (flow->invalidating) pthread_cond_wait(&flow->changed, &flow->mutex);
    if (flow->invalidated) {
        pthread_mutex_unlock(&flow->mutex);
        return false;
    }
    flow->invalidating = true;
    stopClock(flow, now);
    pthread_cond_broadcast(&flow->changed);
    while (flow->outputs) pthread_cond_wait(&flow->changed, &flow->mutex);
    pthread_mutex_unlock(&flow->mutex);
    return true;
}

void VPVideoDecodeEndInvalidation(VPVideoDecodeFlow *flow) {
    pthread_mutex_lock(&flow->mutex);
    assert(flow->invalidating && !flow->outputs);
    flow->invalidated = true;
    flow->invalidating = false;
    pthread_cond_broadcast(&flow->changed);
    pthread_mutex_unlock(&flow->mutex);
}

void VPVideoDecodeStopClock(VPVideoDecodeFlow *flow, uint64_t now) {
    pthread_mutex_lock(&flow->mutex);
    stopClock(flow, now);
    pthread_mutex_unlock(&flow->mutex);
}

void VPVideoDecodeBeginCallback(VPVideoDecodeFlow *flow, uint64_t now) {
    pthread_mutex_lock(&flow->mutex);
    if (flow->callbacks++ == 0) flow->callbackStart = now;
    pthread_mutex_unlock(&flow->mutex);
}

void VPVideoDecodeEndCallback(VPVideoDecodeFlow *flow, uint64_t now) {
    pthread_mutex_lock(&flow->mutex);
    assert(flow->callbacks);
    if (--flow->callbacks == 0 && !flow->clockStopped)
        flow->callbackNanoseconds = sum(flow->callbackNanoseconds, elapsed(flow->callbackStart, now));
    pthread_mutex_unlock(&flow->mutex);
}

uint64_t VPVideoDecodeCallbackTime(VPVideoDecodeFlow *flow, uint64_t now) {
    pthread_mutex_lock(&flow->mutex);
    uint64_t time = flow->callbackNanoseconds;
    if (flow->callbacks && !flow->clockStopped)
        time = sum(time, elapsed(flow->callbackStart, now));
    pthread_mutex_unlock(&flow->mutex);
    return time;
}

uint64_t VPVideoDecodeRemaining(uint64_t budget, uint64_t started, uint64_t now,
                               uint64_t callbacksAtStart, uint64_t callbacksNow) {
    uint64_t wall = elapsed(started, now);
    uint64_t paused = elapsed(callbacksAtStart, callbacksNow);
    uint64_t charged = wall > paused ? wall - paused : 0;
    return charged < budget ? budget - charged : 0;
}
