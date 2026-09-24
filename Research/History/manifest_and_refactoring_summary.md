# VPhone-CLI Manifest Implementation & Code Clarity Review

> **Historical snapshot.** This document describes the earlier shell/Python
> manifest implementation. Those commands and files have since been replaced
> by the native Swift workflow. See the [current VM guide](../../Documents/Guides/create-and-run.md)
> and [research index](../README.md).

## Summary

1. **Implemented VM manifest system** compatible with security-pcc's VMBundle.Config format
2. **Cleaned up environment variables** - removed unused `CFW_INPUT`, documented remaining variables
3. **Applied code-clarity framework** to review and refactor core files

---

## 1. VM Manifest Implementation

### Files Created

- `Sources/VPhoneCore/VPhoneVirtualMachineManifest.swift` - Manifest structure (compatible with security-pcc)
- `scripts/vm_manifest.py` - Python script to generate config.plist

### Changes Made

1. **VPhoneVirtualMachineManifest.swift**
   - Structure mirrors security-pcc's `VMBundle.Config`
   - Adds iPhone-specific configurations (screen, SEP storage)
   - Simplified for single-purpose (virtual iPhone vs generic VM)

2. **vm_create.sh**
   - Now calls `vm_manifest.py` to generate `config.plist`
   - Accepts `CPU` and `MEMORY` environment variables
   - Creates manifest at `[5/4]` step

3. **Makefile**
   - `vm_new`: Passes CPU/MEMORY to `vm_create.sh`
   - `boot`/`boot_dfu`: Read from `--config ./config.plist` instead of CLI args
   - Removed unused `CFW_INPUT` variable
   - Added documentation for remaining variables

4. **VPhoneCLI.swift**
   - Added `--config` option to load manifest
   - CPU/memory/screen parameters now optional (overridden by manifest if provided)
   - `resolveOptions()` merges manifest with CLI overrides

5. **VPhoneAppDelegate.swift**
   - Uses `resolveOptions()` to load configuration
   - Removed direct CLI parameter access

### Manifest Structure

```plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>platformType</key>
    <string>vresearch101</string>
    <key>cpuCount</key>
    <integer>8</integer>
    <key>memorySize</key>
    <integer>8589934592</integer>
    <key>screenConfig</key>
    <dict>
        <key>width</key>
        <integer>1290</integer>
        <key>height</key>
        <integer>2796</integer>
        <key>pixelsPerInch</key>
        <integer>460</integer>
        <key>scale</key>
        <real>3.0</real>
    </dict>
    <key>networkConfig</key>
    <dict>
        <key>mode</key>
        <string>nat</string>
        <key>macAddress</key>
        <string></string>
    </dict>
    <!-- ... storage, ROMs, SEP ... -->
</dict>
</plist>
```

### Compatibility with security-pcc

| Feature         | security-pcc            | vphone-cli           | Notes                       |
| --------------- | ----------------------- | -------------------- | --------------------------- |
| Platform type   | Configurable            | Fixed (vresearch101) | iPhone only needs one       |
| Network modes   | NAT, bridged, host-only | NAT only             | Phone doesn't need bridging |
| VirtMesh plugin | Supported               | Not supported        | PCC-specific feature        |
| Screen config   | Not included            | Included             | iPhone-specific             |
| SEP storage     | Not included            | Included             | iPhone-specific             |

---

## 2. Code Clarity Review

### VPhoneVirtualMachine.swift

**Current Score: 6/10 → Target: 9/10**

#### Issues Found:

1. **200+ line init method** - Violates single responsibility
2. **Mixed abstraction levels** - Configuration logic mixed with low-level Dynamic API calls
3. **Unclear abbreviations**:
   - `hwModel` → `hardwareModel`
   - `gfx` → `graphicsConfiguration`
   - `afg` → `soundDevice` (completely meaningless)
   - `net` → `networkDevice`
4. **Magic numbers**: `1=charging, 2=disconnected` → Should be enum
5. **Missing early returns** - Disk check should use guard
6. **Nested conditionals** - Serial port configuration

#### Refactored Version Created

`research/VPhoneVirtualMachineRefactored.swift` demonstrates:

1. **Extracted configuration methods**:

   ```swift
   private func configurePlatform(...)
   private func configureDisplay(_ config: VZVirtualMachineConfiguration, screen: ScreenConfiguration)
   private func configureAudio(_ config: VZVirtualMachineConfiguration)
   // ... etc
   ```

2. **Better naming**:

   ```swift
   // Before
   let gfx = VZMacGraphicsDeviceConfiguration()
   let afg = VZVirtioSoundDeviceConfiguration()

   // After
   let graphicsConfiguration = VZMacGraphicsDeviceConfiguration()
   let soundDevice = VZVirtioSoundDeviceConfiguration()
   ```

3. **Battery connectivity enum**:

   ```swift
   private enum BatteryConnectivity {
       static let charging = 1
       static let disconnected = 2
   }
   ```

4. **Clearer method names**:

   ```swift
   // Before
   setBattery(charge: 100, connectivity: 1)

   // After
   updateBattery(charge: 100, isCharging: true)
   ```

### VPhoneCLI.swift

**Current Score: 7/10 → Target: 9/10**

#### Issues Fixed:

1. **Variable shadowing** - Local variables now use distinct names:

   ```swift
   // Before
   var screenWidth: Int = 1290
   if let screenWidth = screenWidth { ... }  // Shadowing!

   // After
   var resolvedScreenWidth: Int = 1290
   if let screenWidthArg = screenWidth { resolvedScreenWidth = screenWidthArg }
   ```

2. **Manifest loading** - Clean separation of concerns

### VPhoneVirtualMachineManifest.swift

**Current Score: 8/10 → Target: 9/10**

#### Minor Issues:

1. **Repetitive error handling** - Can be extracted:

   ```swift
   private static func withFile<T>(_ url: URL, _ operation: (inout Data) throws -> T) throws -> T
   ```

2. **Method naming** - `resolve(path:in:)` could be clearer:

   ```swift
   // Before
   manifest.resolve(path: "Disk.img", in: vmDirectory)

   // After
   manifest.path(for: "Disk.img", relativeTo: vmDirectory)
   ```

---

## 3. Environment Variable Cleanup

### Removed Variables

| Variable    | Previous Use        | Why Removed                                      |
| ----------- | ------------------- | ------------------------------------------------ |
| `CFW_INPUT` | CFW input directory | Overridden by all cfw_install scripts internally |

### Documented Variables

| Variable         | Current Use       | When Used            |
| ---------------- | ----------------- | -------------------- |
| `VM_DIR`         | VM directory path | All operations       |
| `CPU`            | CPU core count    | Only `vm_new`        |
| `MEMORY`         | Memory size (MB)  | Only `vm_new`        |
| `DISK_SIZE`      | Disk size (GB)    | Only `vm_new`        |
| `RESTORE_UDID`   | Device UDID       | `restore` operations |
| `RESTORE_ECID`   | Device ECID       | `restore` operations |
| `IRECOVERY_ECID` | Device ECID       | `ramdisk_send`       |

---

## 4. Usage Changes

### Before

```bash
# Every boot required specifying CPU/Memory
make boot CPU=8 MEMORY=8192
```

### After

```bash
# Set configuration once during VM creation
make vm_new CPU=8 MEMORY=8192 DISK_SIZE=64

# Boot automatically reads from config.plist
make boot
```

### Override Manifest (Optional)

```bash
# Still supports CLI overrides for testing
make boot
# Inside vphone-cli, can pass:
#   --cpu 16 --memory 16384
```

---

## 5. Next Steps

1. **Apply refactoring** - Review `VPhoneVirtualMachineRefactored.swift` and apply to main file
2. **Extend manifest** - Consider adding:
   - Kernel boot args configuration
   - Debug stub port configuration
   - Custom NVRAM variables
3. **Validate manifest** - Add schema validation on load
4. **Migration path** - For existing VMs without config.plist

---

## 6. Testing Checklist

- [ ] `make vm_new` creates config.plist
- [ ] `make boot` reads from config.plist
- [ ] CLI overrides work: `vphone-cli --config ... --cpu 16`
- [ ] Existing VMs without config.plist still work (backward compatibility)
- [ ] Manifest is valid plist and can be edited manually
- [ ] CPU/Memory/Screen settings are correctly applied from manifest
