# Virtualization.framework Keyboard Event Pipeline

Reverse engineering findings for the keyboard event pipeline in Apple's
Virtualization.framework (macOS 26.2, version 259.3.3.0.0). Documents how
keyboard events flow from the macOS host to the virtual iPhone guest.

---

## Event Flow Architecture

There are two pipelines for sending keyboard events to the VM:

### Pipeline 1: _VZKeyEvent -> sendKeyEvents: (Standard Keys)

```
_VZKeyEvent(type, keyCode)
  -> _VZKeyboard.sendKeyEvents:(NSArray<_VZKeyEvent>)
    -> table lookup: keyCode -> intermediate index
    -> pack: uint64_t = (index << 32) | is_key_down
    -> std::vector<uint64_t>
    -> [if type==2] sendKeyboardEventsHIDReport:keyboardID: (switch -> IOHIDEvent -> HID reports)
    -> [fallback]   eventSender.sendKeyboardEvents:keyboardID: (VzCore C++ layer)
```

### Pipeline 2: _processHIDReports (Raw HID Reports)

```
Raw HID report bytes
  -> std::span<const unsigned char>{data_ptr, length}
  -> std::vector<std::span<...>>{begin, end, cap}
  -> VZVirtualMachine._processHIDReports:forDevice:deviceType:
    -> XpcEncoder::encode_data(span) -> xpc_data_create
    -> XPC to VMM process
```

---

## _VZKeyEvent Structure

From IDA + LLDB inspection:

```c
struct _VZKeyEvent {  // sizeof = 0x18
    uint8_t  isa[8];      // offset 0x00 -- ObjC isa pointer
    uint16_t _keyCode;    // offset 0x08 -- Apple VK code (0x00-0xB2)
    uint8_t  _pad[6];     // offset 0x0A -- padding
    int64_t  _type;       // offset 0x10 -- 0 = keyDown, 1 = keyUp
};
```

Initializer: `_VZKeyEvent(type: Int64, keyCode: UInt16)`

---

## _VZKeyboard Object Layout

From LLDB memory dump:

```
+0x00: isa
+0x08: _eventSender (weak, id<_VZHIDAdditions, _VZKeyboardEventSender>)
+0x10: _deviceIdentifier (uint32_t) -- value 1 for first keyboard
+0x18: type (int64_t) -- 0 for USB keyboard, 2 for type that tries HIDReport first
```

---

## Lookup Tables in sendKeyEvents:

Two tables indexed by Apple VK keyCode (0x00-0xB2, 179 entries x 8 bytes each):

**Table 1** (validity flags): All valid entries = `0x0000000100000000` (bit 32 set).
Invalid entries = 0.

**Table 2** (intermediate indices): Maps Apple VK codes to internal indices (0x00-0x72).

The tables are OR'd: `combined = table1[vk] | table2[vk]`. Bit 32 check validates
the entry. The lower 32 bits of combined become the intermediate index.

### Sample Table 2 Entries

| Apple VK | Key     | Table2 (Index) | HID Page | HID Usage |
|----------|---------|----------------|----------|-----------|
| 0x00     | A       | 0x00           | 7        | 0x04      |
| 0x01     | S       | 0x12           | 7        | 0x16      |
| 0x24     | Return  | 0x24           | 7        | 0x28      |
| 0x31     | Space   | 0x29           | 7        | 0x2C      |
| 0x35     | Escape  | 0x25           | 7        | 0x29      |
| 0x38     | Shift   | 0x51           | 7        | 0xE1      |
| 0x37     | Command | 0x53           | 7        | 0xE3      |

### Invalid VK Codes (both tables = 0, silently dropped)

0x48 (Volume Up), 0x49 (Volume Down), 0x4A (Mute), and many others.

---

## Packed Event Format (std::vector<uint64_t>)

Each element in the vector sent to `sendKeyboardEvents:keyboardID:`:

```
bits 63:32 = intermediate_index (from table2, lower 32 bits of combined)
bits 31:1  = 0
bit  0     = is_key_down (1 = down, 0 = up)
```

---

## sendKeyboardEventsHIDReport Switch Statement

For type-2 keyboards, the intermediate index is mapped to
`IOHIDEventCreateKeyboardEvent(page, usage)` via a large switch.

### Standard Keyboard Entries (HID Page 7)

| Index     | HID Page | HID Usage | Meaning          |
|-----------|----------|-----------|------------------|
| 0x00-0x19 | 7        | 4-29      | Letters a-z      |
| 0x1A-0x23 | 7        | 30-39     | Digits 1-0       |
| 0x24      | 7        | 40        | Return           |
| 0x25      | 7        | 41        | Escape           |
| 0x29      | 7        | 44        | Space            |
| 0x48-0x4B | 7        | 79-82     | Arrow keys       |
| 0x50-0x53 | 7        | 224-227   | L-Ctrl/Shift/Alt/Cmd |

### Consumer / System Entries (Non-Standard Pages)

| Index | HID Page | HID Usage | Meaning                   |
|-------|----------|-----------|---------------------------|
| 0x6E  | **12**   | 671       | **Consumer Volume Down**  |
| 0x6F  | **12**   | 674       | **Consumer Volume Up**    |
| 0x70  | **12**   | 207       | **Consumer Play/Pause**   |
| 0x71  | **12**   | 545       | **Consumer Snapshot**     |
| 0x72  | **1**    | 155       | **Generic Desktop Wake**  |

**Home/Menu (Consumer page 0x0C, usage 0x40) has NO intermediate index.** It cannot
be sent through Pipeline 1 at all.

---

## _processHIDReports Parameter Format

From IDA decompilation of
`VZVirtualMachine._processHIDReports:forDevice:deviceType:` at 0x2301b2310.

The `void *` parameter is a **pointer to std::vector<std::span<const unsigned char>>**:

```
Level 3 (outermost): std::vector (24 bytes, passed by pointer)
  +0x00: __begin_    (pointer to span array)
  +0x08: __end_      (pointer past last span)
  +0x10: __end_cap_  (capacity pointer)

Level 2: std::span (16 bytes per element in the array)
  +0x00: data_ptr    (const unsigned char *)
  +0x08: length      (size_t)

Level 1 (innermost): raw HID report bytes
```

The function iterates spans in the vector:

```c
begin = *vec;           // vec->__begin_
end   = *(vec + 1);     // vec->__end_
for (span = begin; span != end; span += 16) {
    data_ptr = *(uint64_t*)span;
    length   = *(uint64_t*)(span + 8);
    encoder.encode_data(data_ptr, length);  // -> xpc_data_create
}
```

**deviceType**: 0 = keyboard, 1 = pointing device

**device**: device identifier (uint32_t, matches `_VZKeyboard._deviceIdentifier`)

---

## Crash Analysis: Why Raw Bytes Crashed

Passing raw `[0x40, 0x00]` as the `void*` parameter:

1. Function reads bytes as vector struct: begin = 0x0040 (first 8 bytes), end = garbage
2. Dereferences begin as span pointer -> reads from address ~0x0040
3. Gets garbage data_ptr (0x700420e) and garbage length (0x300000020 = 12GB)
4. `xpc_data_create(0x700420e, 0x300000020)` -> EXC_BAD_ACCESS in memcpy

The three-level indirection (vector -> span -> bytes) must be constructed correctly
or the framework will dereference invalid pointers.

---

## Swift Implementation Notes

### Accessing _VZKeyboard

```swift
// Get keyboards array
let arr = Dynamic(vm)._keyboards.asObject as? NSArray
let keyboard = arr?.object(at: 0) as AnyObject

// _deviceIdentifier is an ivar, not a property -- use KVC
(keyboard as? NSObject)?.value(forKey: "_deviceIdentifier") as? UInt32
```

### Constructing std::vector<uint64_t> for sendKeyboardEvents

```swift
let data = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
data.pointee = (index << 32) | (isKeyDown ? 1 : 0)
var vec = (data, data.advanced(by: 1), data.advanced(by: 1))
withUnsafeMutablePointer(to: &vec) { vecPtr in
    Dynamic(vm).sendKeyboardEvents(UnsafeMutableRawPointer(vecPtr), keyboardID: deviceId)
}
```

### Constructing vector<span<unsigned char>> for _processHIDReports

```swift
let reportPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: N)
// fill report bytes...

let spanPtr = UnsafeMutablePointer<Int>.allocate(capacity: 2)
spanPtr[0] = Int(bitPattern: reportPtr)  // data pointer
spanPtr[1] = N                           // length

let vecPtr = UnsafeMutablePointer<Int>.allocate(capacity: 3)
vecPtr[0] = Int(bitPattern: UnsafeRawPointer(spanPtr))                   // begin
vecPtr[1] = Int(bitPattern: UnsafeRawPointer(spanPtr).advanced(by: 16))  // end
vecPtr[2] = vecPtr[1]                                                    // cap

Dynamic(vm)._processHIDReports(UnsafeRawPointer(vecPtr), forDevice: deviceId, deviceType: 0)
```

---

## Source Files

- Class dumps: `/Users/qaq/Documents/GitHub/super-tart-vphone-private/Virtualization_26.2-class-dump/`
- IDA database: dyld_shared_cache_arm64e with Virtualization.framework

### Key Functions Analyzed

| Function | Address |
|----------|---------|
| `-[_VZKeyboard sendKeyEvents:]` | 0x2301b2f54 |
| `-[_VZKeyboard sendKeyboardEventsHIDReport:keyboardID:]` | 0x2301b3230 |
| `-[VZVirtualMachine(_VZHIDAdditions) _processHIDReports:forDevice:deviceType:]` | 0x2301b2310 |
| `-[VZVirtualMachineView _sendKeyEventsToVirtualMachine:]` | -- |
| `-[_VZHIDEventMonitor getHIDReportsFromHIDEvent:]` | 0x2301b2af0 |
