// VPVirtIOSoundRing.h — the rings between the HAL I/O thread and virtio.
//
// The output ring has three byte counters, each with one writer:
//
//     completed <= submitted <= written
//
// The real-time I/O thread appends mixed frames, and the silence queued
// ahead of them, and advances `written`; nothing else appends. The stream's
// serial queue hands `[submitted, written)` to the device and advances
// `submitted`, and advances `completed` when the device returns the bytes.
// Only `[written, completed + capacity)` may be overwritten: the kernel reads
// a submitted region from the caller's pages until it completes, so the
// space is not free before then.

#ifndef VPVirtIOSoundRing_h
#define VPVirtIOSoundRing_h

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct {
    uint8_t *bytes;
    uint32_t capacity;
    uint32_t period;
    _Atomic uint64_t written;
    _Atomic uint64_t completed;
    uint64_t submitted;
} VPVirtIOSoundRing;

/// Allocate a page-aligned, zeroed ring. False when allocation fails or the
/// capacity is not a whole number of periods.
bool VPVirtIOSoundRingInit(VPVirtIOSoundRing *ring, uint32_t capacity, uint32_t period);
void VPVirtIOSoundRingDestroy(VPVirtIOSoundRing *ring);

/// Rewind every counter to zero. Only while nothing is in flight and the I/O
/// thread is not writing: when the device stream is about to be set up again.
void VPVirtIOSoundRingReset(VPVirtIOSoundRing *ring);

/// Append `length` bytes, all or none. Real-time safe. False, and nothing
/// written, when the free space is short: the device fell behind and these
/// frames are dropped rather than overwriting bytes still in flight.
bool VPVirtIOSoundRingWrite(VPVirtIOSoundRing *ring, const void *source, uint32_t length);

/// Append `length` zero bytes, all or none, as `VPVirtIOSoundRingWrite`
/// does. Real-time safe.
bool VPVirtIOSoundRingWriteSilence(VPVirtIOSoundRing *ring, uint32_t length);

/// Bytes appended and not yet returned by the device: in flight plus
/// pending. For the writer, the I/O thread.
uint64_t VPVirtIOSoundRingQueued(const VPVirtIOSoundRing *ring);

/// The next region to submit, contiguous in memory. Normally a whole period
/// or nothing; with `partial`, whatever is pending (used when the stream
/// stops, so its tail is not left behind). A region never crosses the end
/// of the buffer, so a pending range that wraps takes two calls.
bool VPVirtIOSoundRingNextSubmission(
    const VPVirtIOSoundRing *ring,
    bool partial,
    uint32_t *offset,
    uint32_t *length);

void VPVirtIOSoundRingDidSubmit(VPVirtIOSoundRing *ring, uint32_t length);
void VPVirtIOSoundRingDidComplete(VPVirtIOSoundRing *ring, uint32_t length);

/// Bytes handed to the device and not yet returned.
uint64_t VPVirtIOSoundRingInFlight(const VPVirtIOSoundRing *ring);

// MARK: - Input ring
//
// The same three counters, turned around:
//
//     consumed <= filled <= submitted
//
// The stream's serial queue hands whole period slots to the device and
// advances `submitted`, and advances `filled` when the device returns one
// full of captured frames. The real-time I/O thread copies frames out and
// advances `consumed`. Only `[submitted, consumed + capacity)` may be handed
// out: the device writes a submitted slot until it completes, and the I/O
// thread has not read a filled one yet.

typedef struct {
    uint8_t *bytes;
    uint32_t capacity;
    uint32_t period;
    _Atomic uint64_t consumed;
    _Atomic uint64_t filled;
    uint64_t submitted;
} VPVirtIOSoundInputRing;

/// Allocate a page-aligned, zeroed ring. False when allocation fails or the
/// capacity is not a whole number of periods.
bool VPVirtIOSoundInputRingInit(VPVirtIOSoundInputRing *ring, uint32_t capacity, uint32_t period);
void VPVirtIOSoundInputRingDestroy(VPVirtIOSoundInputRing *ring);

/// Rewind every counter to zero. Only while nothing is in flight and the I/O
/// thread is not reading.
void VPVirtIOSoundInputRingReset(VPVirtIOSoundInputRing *ring);

/// The next period slot to hand the device. Slots are whole periods and the
/// capacity is a whole number of them, so a slot never crosses the end of
/// the buffer. False when no period is free: the I/O thread fell behind.
bool VPVirtIOSoundInputRingNextSubmission(const VPVirtIOSoundInputRing *ring, uint32_t *offset);

void VPVirtIOSoundInputRingDidSubmit(VPVirtIOSoundInputRing *ring);
/// The device returns slots in the order it was handed them, each one a
/// period of frames.
void VPVirtIOSoundInputRingDidComplete(VPVirtIOSoundInputRing *ring);

/// Bytes handed to the device and not yet returned.
uint64_t VPVirtIOSoundInputRingInFlight(const VPVirtIOSoundInputRing *ring);

/// Captured bytes the I/O thread has not read yet.
uint64_t VPVirtIOSoundInputRingAvailable(const VPVirtIOSoundInputRing *ring);

/// Copy out the oldest `length` bytes, all or none. Real-time safe. False,
/// and nothing consumed, when fewer are available.
bool VPVirtIOSoundInputRingRead(VPVirtIOSoundInputRing *ring, void *destination, uint32_t length);

/// Drop the oldest `length` bytes unread, all or none. Real-time safe; the
/// I/O thread's side of the ring, like a read.
bool VPVirtIOSoundInputRingSkip(VPVirtIOSoundInputRing *ring, uint64_t length);

// MARK: - Input reader
//
// The device returns captured frames a period at a time and the HAL reads
// them a few milliseconds at a time, each on its own clock. Read straight
// through, the ring would run empty just before every period lands and any
// period that lands late would be a gap. So reads are served only once
// `leadBytes` have been captured, which keeps about that much between the
// host's capture and the guest's read, and a read that finds too little
// waits for the lead again. When the HAL reads slower than the host
// captures, what is buffered grows; past `maximumBacklogBytes` the oldest
// frames are dropped back to the lead, so the delay stays bounded.

typedef struct {
    VPVirtIOSoundInputRing *ring;
    uint32_t bytesPerFrame;
    uint32_t leadBytes;
    uint32_t maximumBacklogBytes;
    /// Set when the stream starts: the next read drops what the last run left.
    _Atomic bool restart;
    /// The I/O thread's own.
    bool primed;
    /// Since the last start: frames served from the ring, frames served as
    /// silence, and bytes dropped to bound the backlog.
    _Atomic uint64_t servedFrames;
    _Atomic uint64_t silentFrames;
    _Atomic uint64_t skippedBytes;
} VPVirtIOSoundInputReader;

/// Fill `destination` with `frames` captured frames, or with silence when
/// the ring cannot serve them. Real-time safe.
void VPVirtIOSoundInputReaderRead(VPVirtIOSoundInputReader *reader, void *destination, uint32_t frames);

#endif /* VPVirtIOSoundRing_h */
