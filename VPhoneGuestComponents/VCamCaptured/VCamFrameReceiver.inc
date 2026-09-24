// MARK: - shared-frame reader

// The latest frame copied out of the vphoned-published shm. Mutated only
// from the reader callback thread; readers (AVF stream production, next
// stage) take the lock for the brief duration of a copy.
// (struct vcc_latest_frame_s is forward-declared above as vcc_latest_frame_t
//  for use by the viewfinder injection code.)

vcc_latest_frame_t vcc_latest_frame = {
    .lock = PTHREAD_MUTEX_INITIALIZER,
};

static const uint8_t *vcc_shm_base = NULL;
static uint64_t vcc_last_seq_seen = 0;
static uint64_t vcc_frames_received = 0;
static uint8_t *vcc_staging_pixels = NULL;
static size_t vcc_staging_capacity = 0;

static int vcc_shm_map(void) {
  int fd = open(VPHONE_VCAM_SHM_PATH, O_RDONLY);
  if (fd < 0) {
    vcc_log(@"  shm open(%s) failed: %s", VPHONE_VCAM_SHM_PATH, strerror(errno));
    return -1;
  }
  struct stat st;
  if (fstat(fd, &st) < 0 || st.st_size < (off_t)VPHONE_VCAM_SHM_TOTAL_SIZE) {
    vcc_log(@"  shm fstat failed or undersized");
    close(fd);
    return -1;
  }
  void *base = mmap(NULL, VPHONE_VCAM_SHM_TOTAL_SIZE, PROT_READ,
                    MAP_SHARED, fd, 0);
  close(fd);
  if (base == MAP_FAILED) {
    vcc_log(@"  shm mmap failed: %s", strerror(errno));
    return -1;
  }
  vcc_shm_base = (const uint8_t *)base;
  vcc_log(@"  shm mapped %s -> %p", VPHONE_VCAM_SHM_PATH, vcc_shm_base);
  return 0;
}

// Read the latest frame with seq-stability discipline. Returns 1 on a
// fresh frame, 0 if seq hasn't advanced since last call or a read tore.
static int vcc_shm_read_latest(void) {
  if (!vcc_shm_base && vcc_shm_map() < 0) return 0;
  const vphone_vcam_shm_header_t *hdr = (const vphone_vcam_shm_header_t *)vcc_shm_base;

  uint64_t seq_a = atomic_load_explicit(
      (const _Atomic uint64_t *)&hdr->seq, memory_order_acquire);
  if (seq_a == vcc_last_seq_seen) return 0;
  if (seq_a & 1ull) return 0;  // writer in progress

  uint32_t w   = hdr->width;
  uint32_t h   = hdr->height;
  uint32_t bpr = hdr->bytes_per_row;
  uint32_t fmt = hdr->pixel_format;
  uint64_t idx = hdr->frame_index;
  uint32_t pix_len = hdr->pixels_length;

  if (pix_len == 0 || pix_len > VPHONE_VCAM_SHM_MAX_PIXELS) return 0;
  if (w == 0 || h == 0 || bpr == 0 || pix_len < (size_t)bpr * h) return 0;

  if (vcc_staging_capacity < pix_len) {
    uint8_t *larger = (uint8_t *)realloc(vcc_staging_pixels, pix_len);
    if (!larger) return 0;
    vcc_staging_pixels = larger;
    vcc_staging_capacity = pix_len;
  }
  memcpy(vcc_staging_pixels, vcc_shm_base + VPHONE_VCAM_SHM_HEADER_SIZE, pix_len);

  // Re-check seq after copy. If it advanced past our snapshot+1 we may
  // have torn — but the writer always sets even seq AFTER pixel write,
  // so seeing the same even seq means our copy was clean.
  uint64_t seq_b = atomic_load_explicit(
      (const _Atomic uint64_t *)&hdr->seq, memory_order_acquire);
  if (seq_b != seq_a) return 0;

  pthread_mutex_lock(&vcc_latest_frame.lock);
  uint8_t *old_pixels = vcc_latest_frame.pixels;
  size_t old_capacity = vcc_latest_frame.pixels_capacity;
  vcc_latest_frame.pixels = vcc_staging_pixels;
  vcc_latest_frame.pixels_capacity = vcc_staging_capacity;
  vcc_latest_frame.pixels_length = pix_len;
  vcc_latest_frame.width = w;
  vcc_latest_frame.height = h;
  vcc_latest_frame.bytes_per_row = bpr;
  vcc_staging_pixels = old_pixels;
  vcc_staging_capacity = old_capacity;
  pthread_mutex_unlock(&vcc_latest_frame.lock);

  vcc_last_seq_seen = seq_a;
  vcc_frames_received++;
  if ((vcc_frames_received & 29) == 1) {
    vcc_log(@"  shm frame #%llu (idx=%llu) w=%u h=%u bpr=%u fmt=0x%08x",
            (unsigned long long)vcc_frames_received,
            (unsigned long long)idx, w, h, bpr, fmt);
  }
  return 1;
}

static void vcc_start_frame_receiver(void) {
  // Subscribe before mapping: cameracaptured may start before vphoned has
  // created the file. The first frame notification retries the map.
  int token = -1;
  dispatch_queue_t q = dispatch_queue_create("com.vphone.vcam.frames", DISPATCH_QUEUE_SERIAL);
  uint32_t status = notify_register_dispatch(
      VPHONE_VCAM_NOTIFY_NAME, &token, q,
      ^(__unused int t) {
        @autoreleasepool {
          (void)vcc_shm_read_latest();
        }
      });
  if (status != NOTIFY_STATUS_OK) {
    vcc_log(@"  notify_register_dispatch(%s) failed: %u",
            VPHONE_VCAM_NOTIFY_NAME, status);
    return;
  }
  vcc_log(@"  subscribed to %s (token=%d)", VPHONE_VCAM_NOTIFY_NAME, token);
  dispatch_async(q, ^{ @autoreleasepool { (void)vcc_shm_read_latest(); } });
}
