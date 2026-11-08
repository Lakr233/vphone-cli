#import <Foundation/Foundation.h>
#import "../Native/Include/VphonedNative.h"
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>

static void waitFor(dispatch_semaphore_t done, const char *phase) {
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) != 0) {
        fprintf(stderr, "%s exceeded the test deadline\n", phase);
        exit(EXIT_FAILURE);
    }
}

static void expectState(NSDictionary *report, NSString *expected, const char *phase) {
    NSString *state = report[@"thread"][@"capture_state"];
    if (![state isEqualToString:expected]) {
        fprintf(stderr, "%s: expected %s, got %s\n", phase, expected.UTF8String, state.UTF8String ?: "missing state");
        exit(EXIT_FAILURE);
    }
}

int main(void) {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            fprintf(stderr, "display layout admission test exceeded its total deadline\n");
            exit(EXIT_FAILURE);
        });
        dispatch_queue_t requests = dispatch_queue_create("vphone.test.layout-admission", DISPATCH_QUEUE_SERIAL);
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block NSDictionary *first, *second;
        dispatch_async(requests, ^{
            @autoreleasepool {
                first = vp_display_layout();
                second = vp_display_layout();
                dispatch_semaphore_signal(done);
            }
        });

        // Main deliberately cannot execute either queued observation. The
        // first timeout must retain admission until its cancellation drains.
        waitFor(done, "initial background requests");
        expectState(first, @"cancelled_before_start", "first observation");
        expectState(second, @"busy", "second observation while cancellation is queued");

        // FIFO ordering runs the queued cancellation before this sentinel.
        // Block main again to test recovered admission without invoking any
        // FrontBoard or CoreAnimation discovery call.
        dispatch_async(dispatch_get_main_queue(), ^{
            @autoreleasepool {
                dispatch_semaphore_t recovered = dispatch_semaphore_create(0);
                __block NSDictionary *third, *fourth;
                dispatch_async(requests, ^{
                    @autoreleasepool {
                        third = vp_display_layout();
                        fourth = vp_display_layout();
                        dispatch_semaphore_signal(recovered);
                    }
                });
                waitFor(recovered, "requests after draining cancellation");
                expectState(third, @"cancelled_before_start", "admission after cancellation drains");
                expectState(fourth, @"busy", "recovered admission is released exactly once");
                dispatch_async(dispatch_get_main_queue(), ^{
                    // The recovered request's queued cancellation has drained.
                    puts("display layout admission: queued cancellation stays admitted and drains exactly once");
                    exit(EXIT_SUCCESS);
                });
            }
        });
    }
    dispatch_main();
}
