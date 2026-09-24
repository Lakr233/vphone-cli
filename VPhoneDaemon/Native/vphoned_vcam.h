/*
 * vphoned_vcam — receive virtual-camera frames over vsock and publish
 * them into a shared-memory file that libvcamcaptured (inside
 * cameracaptured) maps for read access.
 *
 * vphoned runs as root and has AF_VSOCK access; the cameracaptured
 * sandbox does not, so libvcamcaptured can't open its own vsock socket.
 * Putting the listener here is the cleanest workaround.
 */

#ifndef VPHONED_VCAM_H
#define VPHONED_VCAM_H

#import <Foundation/Foundation.h>
#include "../../VPhoneGuestComponents/VCamCaptured/VCamFrameProtocol.h"

#ifdef __cplusplus
extern "C" {
#endif

#ifndef VPHONED_VCAM_VSOCK_PORT
#define VPHONED_VCAM_VSOCK_PORT 1338
#endif

/* Starts the listener on a background thread. Idempotent. */
void vp_vcam_start(void);

#ifdef __cplusplus
}
#endif

#endif /* VPHONED_VCAM_H */
