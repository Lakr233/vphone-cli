#ifndef VP_VIDEO_DECODE_FLOW_H
#define VP_VIDEO_DECODE_FLOW_H

#include <stdbool.h>
#include <stdint.h>
#include <pthread.h>

// One instance per PV decoder UUID. Buffer allocation continues to use Apple's
// storage lock. This gate protects the session pointers while an output handler
// temporarily lends that lock to buffer allocation during the XPC callback.
typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t changed;
    unsigned outputs;
    unsigned callbacks;
    bool invalidating;
    bool invalidated;
    bool clockStopped;
    uint64_t callbackStart;
    uint64_t callbackNanoseconds;
} VPVideoDecodeFlow;

bool VPVideoDecodeFlowInit(VPVideoDecodeFlow *flow);
void VPVideoDecodeFlowDestroy(VPVideoDecodeFlow *flow);
bool VPVideoDecodeBeginOutput(VPVideoDecodeFlow *flow);
void VPVideoDecodeEndOutput(VPVideoDecodeFlow *flow);

// During invalidation new outputs use Apple's original locked path instead of
// waiting behind this gate: the host may need those handlers to finish dinv.
// Dbuf handlers never enter the gate and can unblock an admitted output.
// Returns false when another caller has already invalidated the decoder.
bool VPVideoDecodeBeginInvalidation(VPVideoDecodeFlow *flow, uint64_t now);
void VPVideoDecodeEndInvalidation(VPVideoDecodeFlow *flow);
void VPVideoDecodeStopClock(VPVideoDecodeFlow *flow, uint64_t now);

void VPVideoDecodeBeginCallback(VPVideoDecodeFlow *flow, uint64_t now);
void VPVideoDecodeEndCallback(VPVideoDecodeFlow *flow, uint64_t now);
uint64_t VPVideoDecodeCallbackTime(VPVideoDecodeFlow *flow, uint64_t now);

// Preserve the original host-response budget, excluding only the union of this
// decoder's XPC callback intervals. No fabricated semaphore signal or reply.
uint64_t VPVideoDecodeRemaining(uint64_t budget, uint64_t started, uint64_t now,
                               uint64_t callbacksAtStart, uint64_t callbacksNow);

#endif
