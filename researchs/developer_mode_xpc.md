# Developer Mode via AMFI XPC

How iOS developer mode is enabled programmatically, based on TrollStore's implementation.

## XPC Service

**Mach service:** `com.apple.amfi.xpc`

AMFI (Apple Mobile File Integrity) daemon exposes an XPC endpoint for developer mode control on iOS 16+.

## Required Entitlement

```
com.apple.private.amfi.developer-mode-control = true
```

Without this entitlement the XPC connection to amfid is rejected.

## Message Protocol

Messages are serialized using private CoreFoundation-XPC bridge functions:

```objc
extern xpc_object_t _CFXPCCreateXPCMessageWithCFObject(CFTypeRef obj);
extern CFTypeRef _CFXPCCreateCFObjectFromXPCMessage(xpc_object_t obj);
```

### Request

NSDictionary with a single key:

```objc
@{@"action": @(action)}
```

### Actions

| Action | Value | Behavior |
|--------|-------|---------|
| `kAMFIActionArm` | 0 | Arm developer mode — takes effect on next reboot, user must select "Turn On" |
| `kAMFIActionDisable` | 1 | Disable developer mode immediately |
| `kAMFIActionStatus` | 2 | Query current state |

### Response

XPC reply dict contains a `"cfreply"` key holding the CF-serialized response:

```objc
xpc_object_t cfReply = xpc_dictionary_get_value(reply, "cfreply");
NSDictionary *dict = _CFXPCCreateCFObjectFromXPCMessage(cfReply);
```

Response fields:

| Key | Type | Description |
|-----|------|-------------|
| `success` | BOOL | Whether the XPC call succeeded |
| `status` | BOOL | Current developer mode state (for Status action) |
| `armed` | BOOL | Whether armed for reboot (for Arm action) |
| `error` | NSString | Error description if success is false |

## Arming Flow

1. Query status (`kAMFIActionStatus`)
2. If already enabled, done
3. Send arm (`kAMFIActionArm`)
4. Device must reboot; user selects "Turn On" in the prompt
5. Developer mode is now active

Arming does **not** enable developer mode immediately. It sets a flag that triggers the enable prompt on the next reboot. Disabling (`kAMFIActionDisable`) takes effect immediately.

## TrollStore Reference

Source: `references/TrollStore/RootHelper/devmode.m`

TrollStore separates privileges: the main app has no AMFI entitlement; all privileged operations go through RootHelper which has `com.apple.private.amfi.developer-mode-control`.

Key functions:
- `checkDeveloperMode()` — returns current state, YES on iOS <16 (devmode doesn't exist)
- `armDeveloperMode(BOOL *alreadyEnabled)` — check + arm in one call
- `startConnection()` — creates and resumes XPC connection to `com.apple.amfi.xpc`
- `sendXPCRequest()` — CF dict → XPC message → sync reply → CF dict

## vphoned Implementation

Added as `devmode` capability in vphoned guest agent:

### Protocol Messages

**Status query:**
```json
{"t": "devmode", "action": "status"}
→ {"t": "ok", "enabled": true}
```

**Enable (arm):**
```json
{"t": "devmode", "action": "enable"}
→ {"t": "ok", "already_enabled": false, "msg": "developer mode armed, reboot to activate"}
```

### Entitlements

Added to `scripts/vphoned/entitlements.plist`:
```xml
<key>com.apple.private.amfi.developer-mode-control</key>
<true/>
```

### Host-Side API (VPhoneControl.swift)

```swift
control.sendDevModeStatus()    // query current state
control.sendDevModeEnable()    // arm developer mode
```

Responses arrive via the existing read loop and are logged to console.
