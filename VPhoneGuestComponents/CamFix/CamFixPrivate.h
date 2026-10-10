// Private interface shared by libcamfix's compilation units. Nothing here
// is dylib API: every declaration is hidden, so the export table stays the
// same as when libcamfix was one file.

#ifndef CAMFIX_PRIVATE_H
#define CAMFIX_PRIVATE_H

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <IOSurface/IOSurfaceRef.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include "VCamFrameProtocol.h"
#include "vcam_dataplane.h"

#define CFX_HIDDEN __attribute__((visibility("hidden")))

#define VCAM_UID @"vphone:vcam:0"

// MARK: - support (CamFixSupport.m)

CFX_HIDDEN void cfxlog(NSString *fmt, ...);
CFX_HIDDEN NSDictionary *cfx_overrides(void);
CFX_HIDDEN BOOL cfx_session_is_for_vcam(AVCaptureSession *session);
CFX_HIDDEN BOOL cfx_output_is_for_vcam(id self);

// MARK: - frame source (Frame/CamFixFrameSource.m)

CFX_HIDDEN CMSampleBufferRef cfx_build_cmsb(void);
CFX_HIDDEN CMSampleBufferRef cfx_build_oriented_cmsb(uint32_t fmt_out, uint32_t preset_w,
                                                     uint32_t preset_h, int angle, double zoom,
                                                     int extra_turns, BOOL mirror,
                                                     uint32_t *outW, uint32_t *outH);
CFX_HIDDEN BOOL cfx_shm_frame_size(uint32_t *w, uint32_t *h);
CFX_HIDDEN CGImageRef cfx_build_cgimage_from_shm(void) CF_RETURNS_RETAINED;
CFX_HIDDEN NSData *cfx_jpeg_from_cgimage(CGImageRef img);
CFX_HIDDEN IOSurfaceRef cfx_build_iosurface_from_shm(uint32_t *outW, uint32_t *outH) CF_RETURNS_RETAINED;

// MARK: - device (Device/)

CFX_HIDDEN void cfx_install_setActiveFormat_hook(void);
CFX_HIDDEN void cfx_install_front_camera_alias(void);
CFX_HIDDEN void cfx_install_exposure_hooks(void);
CFX_HIDDEN void cfx_stamp_exif(CMSampleBufferRef sb, double meanLuma);

// MARK: - photos (Photo/)

CFX_HIDDEN id cfx_build_avcapturephoto_with_request(
    IOSurfaceRef surf,
    uint32_t w,
    uint32_t h,
    id captureRequest);
CFX_HIDDEN NSData *cfx_stamp_photo(id photo);
CFX_HIDDEN void cfx_install_photo_representation_hooks(void);
CFX_HIDDEN void cfx_install_capturePhoto_hook(void);
CFX_HIDDEN void cfx_install_moment_capture_hooks(void);
CFX_HIDDEN void cfx_install_capturerequest_stubs(void);

// MARK: - preview (Preview/)

CFX_HIDDEN BOOL cfx_preview_has_layers(void);
CFX_HIDDEN void cfx_preview_start_timer(void);
CFX_HIDDEN void cfx_install_preview_layer_hooks(void);
CFX_HIDDEN void cfx_start_scan_timer(void);
CFX_HIDDEN CMSampleBufferRef cfx_tap_fetch_fresh(void) CF_RETURNS_RETAINED;
CFX_HIDDEN void cfx_tap_clear(void);
CFX_HIDDEN BOOL cfx_graph_is_delivering(void);
CFX_HIDDEN void cfx_install_remote_queue_tap(void);

// MARK: - sessions (Session/)

CFX_HIDDEN void cfx_track_vcam_session(id session);
CFX_HIDDEN void cfx_deliver_video_frames_once(void);
CFX_HIDDEN void cfx_install_session_guards(void);
CFX_HIDDEN void cfx_install_input_diagnostics(void);
CFX_HIDDEN void cfx_install_session_state_lies(void);
CFX_HIDDEN void cfx_install_asset_writer_settings(void);
CFX_HIDDEN BOOL cfx_output_frame_size(id out, uint32_t *w, uint32_t *h);

#endif
