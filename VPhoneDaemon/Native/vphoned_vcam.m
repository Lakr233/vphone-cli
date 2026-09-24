/*
 * vphoned_vcam — vsock 1338 -> shared mmap frame publisher.
 *
 * Wire protocol (matches host VPhoneCameraServer.swift):
 *   uint32 LE  total_payload_length
 *   uint32 LE  header_json_length
 *   bytes      JSON header { w, h, bpr, fmt, ts }
 *   bytes      raw pixel data (width*height aligned by bpr)
 *
 * On each successful receive, the frame is written into the shm file
 * with a seq-counter discipline and a notify_post() fires so any
 * libvcamcaptured-mapped reader can pick it up immediately.
 */

#import "vphoned_vcam.h"

#include <errno.h>
#include <fcntl.h>
#include <notify.h>
#include <pthread.h>
#include <pwd.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/vsock.h>
#include <unistd.h>

static pthread_once_t s_start_once = PTHREAD_ONCE_INIT;
static uint8_t       *s_shm_base   = NULL;
static int            s_notify_token = -1;

__attribute__((format(printf, 1, 2)))
static void vvc_logf(const char *fmt, ...) {
  FILE *fp = fopen(VPHONE_VCAM_DAEMON_LOG_PATH, "a");
  va_list ap;
  va_start(ap, fmt);
  if (!fp) {
    char message[1024];
    vsnprintf(message, sizeof(message), fmt, ap);
    NSLog(@"%s", message);
  } else {
    vfprintf(fp, fmt, ap);
    fputc('\n', fp);
    fclose(fp);
  }
  va_end(ap);
}

static int open_shm(void) {
  /* Wait for mobile's home before creating its media directory. */
  struct passwd *mobile_user = getpwnam("mobile");
  struct stat mobile_home;
  if (!mobile_user || stat("/var/mobile", &mobile_home) < 0 ||
      !S_ISDIR(mobile_home.st_mode) || mobile_home.st_uid != mobile_user->pw_uid) {
    vvc_logf("vphoned_vcam: mobile home is not ready");
    return -1;
  }
  NSString *directory = [NSString stringWithUTF8String:VPHONE_VCAM_DIRECTORY];
  NSError *error = nil;
  if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
                                withIntermediateDirectories:YES
                                                 attributes:@{NSFilePosixPermissions: @0755}
                                                      error:&error]) {
    vvc_logf("vphoned_vcam: create(%s) failed: %s", directory.UTF8String,
             error.localizedDescription.UTF8String);
    return -1;
  }
  int directory_fd = open(VPHONE_VCAM_DIRECTORY, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
  if (directory_fd < 0) {
    vvc_logf("vphoned_vcam: open directory failed: %s", strerror(errno));
    return -1;
  }
  if (fchown(directory_fd, mobile_user->pw_uid, mobile_user->pw_gid) < 0) {
    vvc_logf("vphoned_vcam: chown directory failed: %s", strerror(errno));
    close(directory_fd);
    return -1;
  }
  if (fchmod(directory_fd, 0755) < 0) {
    vvc_logf("vphoned_vcam: chmod directory failed: %s", strerror(errno));
    close(directory_fd);
    return -1;
  }
  close(directory_fd);
  /* Truncate to total size each fresh open so a stale half-written file
   * from a previous boot doesn't confuse readers. */
  int fd = open(VPHONE_VCAM_SHM_PATH, O_RDWR | O_CREAT, 0644);
  if (fd < 0) {
    vvc_logf("vphoned_vcam: open(%s) failed: %s",
          VPHONE_VCAM_SHM_PATH,
          strerror(errno));
    return -1;
  }
  if (ftruncate(fd, VPHONE_VCAM_SHM_TOTAL_SIZE) < 0) {
    vvc_logf("vphoned_vcam: ftruncate failed: %s", strerror(errno));
    close(fd);
    return -1;
  }
  /* Make sure other processes can map this file read-only. */
  fchmod(fd, 0644);
  void *base = mmap(
      NULL,
      VPHONE_VCAM_SHM_TOTAL_SIZE,
      PROT_READ | PROT_WRITE,
      MAP_SHARED,
      fd,
      0);
  close(fd);
  if (base == MAP_FAILED) {
    vvc_logf("vphoned_vcam: mmap failed: %s", strerror(errno));
    return -1;
  }
  /* Zero the header on first init so seq starts at 0. */
  memset(base, 0, VPHONE_VCAM_SHM_HEADER_SIZE);
  s_shm_base = (uint8_t *)base;
  return 0;
}

static ssize_t read_full(int fd, void *buf, size_t n) {
  uint8_t *p = (uint8_t *)buf;
  size_t got = 0;
  while (got < n) {
    ssize_t r = read(fd, p + got, n - got);
    if (r > 0) { got += (size_t)r; continue; }
    if (r == 0) return 0;
    if (errno == EINTR) continue;
    return -1;
  }
  return (ssize_t)got;
}

static void publish_frame(uint32_t w,
                          uint32_t h,
                          uint32_t bpr,
                          uint32_t fmt,
                          uint64_t ts_ns,
                          const uint8_t *pixels,
                          size_t pixel_len) {
  if (!s_shm_base) return;
  if (pixel_len > VPHONE_VCAM_SHM_MAX_PIXELS) {
    vvc_logf("vphoned_vcam: frame too large: %zu", pixel_len);
    return;
  }
  vphone_vcam_shm_header_t *hdr = (vphone_vcam_shm_header_t *)s_shm_base;
  uint8_t *dst = s_shm_base + VPHONE_VCAM_SHM_HEADER_SIZE;

  uint64_t prev_seq = atomic_load_explicit(
      (_Atomic uint64_t *)&hdr->seq, memory_order_acquire);
  /* Mark write in progress (odd seq). */
  uint64_t writing_seq = (prev_seq | 1ull) + 2ull;
  atomic_store_explicit(
      (_Atomic uint64_t *)&hdr->seq,
      writing_seq,
      memory_order_release);

  hdr->width = w;
  hdr->height = h;
  hdr->bytes_per_row = bpr;
  hdr->pixel_format = fmt;
  hdr->timestamp_ns = ts_ns;
  hdr->frame_index += 1;
  hdr->pixels_length = (uint32_t)pixel_len;
  memcpy(dst, pixels, pixel_len);

  /* Mark write done (even seq). */
  atomic_store_explicit(
      (_Atomic uint64_t *)&hdr->seq,
      writing_seq + 1ull,
      memory_order_release);

  if (s_notify_token >= 0) {
    notify_post(VPHONE_VCAM_NOTIFY_NAME);
  }
}

static void handle_client(int fd) {
  vvc_logf("vphoned_vcam: client connected fd=%d", fd);
  uint64_t frames = 0;
  for (;;) {
    uint32_t total_len = 0, header_len = 0;
    if (read_full(fd, &total_len, 4) <= 0) break;
    if (read_full(fd, &header_len, 4) <= 0) break;
    if (total_len < 4 || header_len > total_len - 4 ||
        total_len > VPHONE_VCAM_SHM_MAX_PIXELS + 4096) {
      vvc_logf("vphoned_vcam: framing error total=%u header=%u",
            total_len,
            header_len);
      break;
    }
    uint8_t *header_buf = (uint8_t *)malloc(header_len);
    if (!header_buf) break;
    if (read_full(fd, header_buf, header_len) <= 0) {
      free(header_buf);
      break;
    }
    size_t pixel_len = (size_t)total_len - 4 - header_len;
    uint8_t *pixel_buf = (uint8_t *)malloc(pixel_len);
    if (!pixel_buf) { free(header_buf); break; }
    if (read_full(fd, pixel_buf, pixel_len) <= 0) {
      free(header_buf);
      free(pixel_buf);
      break;
    }
    NSData *hd = [NSData dataWithBytesNoCopy:header_buf
                                       length:header_len
                                 freeWhenDone:NO];
    NSError *jerr = nil;
    NSDictionary *hdict = [NSJSONSerialization JSONObjectWithData:hd
                                                          options:0
                                                            error:&jerr];
    uint32_t w   = (uint32_t)[hdict[@"w"]   unsignedIntValue];
    uint32_t h   = (uint32_t)[hdict[@"h"]   unsignedIntValue];
    uint32_t bpr = (uint32_t)[hdict[@"bpr"] unsignedIntValue];
    uint32_t fmt = (uint32_t)[hdict[@"fmt"] unsignedIntValue];
    uint64_t ts  = (uint64_t)[hdict[@"ts"]  unsignedLongLongValue];
    free(header_buf);

    if (!hdict || jerr || w == 0 || h == 0 || bpr == 0 ||
        pixel_len < (size_t)bpr * h) {
      vvc_logf("vphoned_vcam: invalid frame w=%u h=%u bpr=%u pixel_len=%zu jerr=%s",
               w,
               h,
               bpr,
               pixel_len,
               jerr ? jerr.localizedDescription.UTF8String : "(none)");
      free(pixel_buf);
      break;
    }
    publish_frame(w, h, bpr, fmt, ts, pixel_buf, pixel_len);
    free(pixel_buf);

    frames++;
    if ((frames & 29) == 1) {
      vvc_logf("vphoned_vcam: published frame #%llu w=%u h=%u bpr=%u",
            (unsigned long long)frames,
            w,
            h,
            bpr);
    }
  }
  vvc_logf("vphoned_vcam: client disconnected (%llu frames)",
        (unsigned long long)frames);
  close(fd);
}

static void *listener_thread(__unused void *unused) {
  while (open_shm() < 0) sleep(3);

  /* Register the notify name so notify_post() actually delivers. */
  if (notify_register_check(VPHONE_VCAM_NOTIFY_NAME,
                            &s_notify_token) != NOTIFY_STATUS_OK) {
    s_notify_token = -1;
  }

  int srv = socket(AF_VSOCK, SOCK_STREAM, 0);
  if (srv < 0) {
    vvc_logf("vphoned_vcam: socket(AF_VSOCK) failed: %s", strerror(errno));
    return NULL;
  }
  int one = 1;
  setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

  struct sockaddr_vm addr = {
      .svm_len    = sizeof(addr),
      .svm_family = AF_VSOCK,
      .svm_port   = VPHONED_VCAM_VSOCK_PORT,
      .svm_cid    = VMADDR_CID_ANY,
  };
  if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    vvc_logf("vphoned_vcam: bind(%d) failed: %s",
          VPHONED_VCAM_VSOCK_PORT,
          strerror(errno));
    close(srv);
    return NULL;
  }
  if (listen(srv, 2) < 0) {
    vvc_logf("vphoned_vcam: listen failed: %s", strerror(errno));
    close(srv);
    return NULL;
  }
  vvc_logf("vphoned_vcam: listening on vsock %d, shm=%s",
        VPHONED_VCAM_VSOCK_PORT,
        VPHONE_VCAM_SHM_PATH);

  for (;;) {
    int fd = accept(srv, NULL, NULL);
    if (fd < 0) {
      if (errno == EINTR) continue;
      vvc_logf("vphoned_vcam: accept failed: %s", strerror(errno));
      sleep(1);
      continue;
    }
    @autoreleasepool {
      handle_client(fd);
    }
  }
}

static void start_listener_once(void) {
  pthread_t thr;
  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
  int rc = pthread_create(&thr, &attr, listener_thread, NULL);
  pthread_attr_destroy(&attr);
  if (rc != 0) {
    vvc_logf("vphoned_vcam: pthread_create failed: %d", rc);
  }
}

void vp_vcam_start(void) {
  vvc_logf("vphoned_vcam: vp_vcam_start called (pid=%d)", getpid());
  pthread_once(&s_start_once, start_listener_once);
}
