#include "VPVideoDecodeFlow.h"
#include <assert.h>
#include <dispatch/dispatch.h>
#include <stdatomic.h>
#include <stdio.h>
#include <time.h>

static void waitFor(dispatch_semaphore_t semaphore) {
    assert(dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0);
}

static void lifetimeAndControlProgress(void) {
    VPVideoDecodeFlow flow;
    assert(VPVideoDecodeFlowInit(&flow));
    pthread_mutex_t storage = PTHREAD_MUTEX_INITIALIZER;
    _Atomic bool alive = true;
    _Atomic unsigned buffers = 0;
    VPVideoDecodeFlow *f = &flow;
    pthread_mutex_t *lock = &storage;
    _Atomic bool *live = &alive;
    _Atomic unsigned *allocated = &buffers;
    dispatch_queue_t output = dispatch_queue_create("test.video.output", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_t control = dispatch_queue_create("test.video.buffer", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_t teardown = dispatch_queue_create("test.video.invalidate", DISPATCH_QUEUE_SERIAL);
    dispatch_semaphore_t blocked = dispatch_semaphore_create(0), release = dispatch_semaphore_create(0);
    dispatch_semaphore_t bufferDone = dispatch_semaphore_create(0), invalidated = dispatch_semaphore_create(0);

    dispatch_async(output, ^{
        assert(VPVideoDecodeBeginOutput(f));
        pthread_mutex_lock(lock);
        assert(atomic_load(live));
        VPVideoDecodeBeginCallback(f, 10);
        pthread_mutex_unlock(lock);
        dispatch_semaphore_signal(blocked);
        waitFor(release); // The application controls when its callback returns.
        assert(atomic_load(live)); // Invalidate must not have freed the session.
        VPVideoDecodeEndCallback(f, 2010);
        pthread_mutex_lock(lock);
        assert(atomic_load(live));
        pthread_mutex_unlock(lock);
        VPVideoDecodeEndOutput(f);
    });
    waitFor(blocked);
    dispatch_async(teardown, ^{
        assert(VPVideoDecodeBeginInvalidation(f, 100));
        pthread_mutex_lock(lock);
        assert(atomic_load(allocated) == 1);
        atomic_store(live, false);
        pthread_mutex_unlock(lock);
        VPVideoDecodeEndInvalidation(f);
        dispatch_semaphore_signal(invalidated);
    });

    // Establish that invalidation has actually closed admission, not merely
    // that its thread was submitted. Bound this wait as well as the semaphores.
    pthread_mutex_lock(&flow.mutex);
    struct timespec until;
    clock_gettime(CLOCK_REALTIME, &until);
    until.tv_sec += 3;
    while (!flow.invalidating)
        assert(pthread_cond_timedwait(&flow.changed, &flow.mutex, &until) == 0);
    pthread_mutex_unlock(&flow.mutex);
    // A new handler must immediately fall back to Apple's locked path, not
    // block the output queue behind a dinv that may need that same handler.
    assert(!VPVideoDecodeBeginOutput(&flow));

    dispatch_async(control, ^{
        pthread_mutex_lock(lock);
        assert(atomic_load(live));
        atomic_fetch_add(allocated, 1);
        pthread_mutex_unlock(lock);
        dispatch_semaphore_signal(bufferDone);
    });
    waitFor(bufferDone); // Dbuf must pass while both output and invalidate wait.
    assert(dispatch_semaphore_wait(invalidated, DISPATCH_TIME_NOW) != 0);
    dispatch_semaphore_signal(release);
    waitFor(invalidated);
    assert(!VPVideoDecodeBeginOutput(&flow));
    assert(!VPVideoDecodeBeginInvalidation(&flow, 2200));
    assert(!atomic_load(&alive));
    dispatch_sync(output, ^{});
    dispatch_sync(control, ^{});
    dispatch_sync(teardown, ^{});
    VPVideoDecodeFlowDestroy(&flow);
    pthread_mutex_destroy(&storage);
    dispatch_release(output); dispatch_release(control); dispatch_release(teardown);
    dispatch_release(blocked); dispatch_release(release); dispatch_release(bufferDone); dispatch_release(invalidated);
}

static void timeoutAccounting(void) {
    VPVideoDecodeFlow flow, other;
    assert(VPVideoDecodeFlowInit(&flow));
    assert(VPVideoDecodeFlowInit(&other));
    const uint64_t ms = 1000000, budget = 1100 * ms;
    assert(VPVideoDecodeRemaining(budget, 0, 1100 * ms, 0, 0) == 0);

    VPVideoDecodeBeginCallback(&flow, 100 * ms);
    uint64_t before = VPVideoDecodeCallbackTime(&flow, 200 * ms);
    VPVideoDecodeBeginCallback(&flow, 500 * ms); // Overlap is counted only once.
    VPVideoDecodeEndCallback(&flow, 1200 * ms);
    VPVideoDecodeEndCallback(&flow, 2100 * ms);
    uint64_t after = VPVideoDecodeCallbackTime(&flow, 2200 * ms);
    assert(after == 2000 * ms);
    assert(VPVideoDecodeRemaining(budget, 200 * ms, 2200 * ms, before, after) == 1000 * ms);
    assert(VPVideoDecodeRemaining(budget, 200 * ms, 3200 * ms, before, after) == 0);
    assert(VPVideoDecodeCallbackTime(&other, 2200 * ms) == 0); // UUID isolation.

    VPVideoDecodeBeginCallback(&flow, 2300 * ms);
    VPVideoDecodeStopClock(&flow, 2400 * ms); // Client death/removal ends extensions.
    assert(VPVideoDecodeCallbackTime(&flow, 9000 * ms) == 2100 * ms);
    VPVideoDecodeEndCallback(&flow, 10000 * ms);
    assert(VPVideoDecodeCallbackTime(&flow, 10001 * ms) == 2100 * ms);
    assert(VPVideoDecodeRemaining(budget, 2200 * ms, 3400 * ms, after, 2100 * ms) == 0);
    VPVideoDecodeFlowDestroy(&flow);
    VPVideoDecodeFlowDestroy(&other);
}

int main(void) {
    timeoutAccounting();
    for (unsigned pass = 0; pass < 100; pass++) lifetimeAndControlProgress();
    puts("VideoDecodeFlowTests: callback budget, UUID isolation, cancellation and 100 concurrent teardown cycles passed");
    return 0;
}
