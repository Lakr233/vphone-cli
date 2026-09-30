# The two gates between Xcode and a vphone guest

Measured 2026-09-30 on `05-mis-test` (iPhone base 26.6.2 / 23G90, cloudOS 26.4
/ 23E5207q, `jb` variant), booted, with `mis_trust_auth` applied.

`xcrun devicectl device install app` refuses two different things, in two
different processes, and they need separate answers:

| What you hand it | Refused by | Error |
| --- | --- | --- |
| An app not signed by an Apple leaf | installd | `0xE8008014` / `0xE800801C` |
| A profile that does not name this device | misagent | `0xE8008012` |

Everything *behind* both refusals already accepts unsigned code, so neither is
a deep problem — each has one cause and one place to answer it.

Part one is the signature. Part two, further down, is the device identity.

## What was measured

A throwaway app (`wiki.qaq.vphone.signtest`, one UIKit view controller) built
with no team, no provisioning profile and no Apple certificate, offered to the
guest three ways:

| Signature | `devicectl device install app` |
| --- | --- |
| none | `0xE800801C` No code signature found. |
| `ldid -S` (the project's own shape: no CMS blob, no ad-hoc flag) | `0xE800801C` |
| `codesign --sign -` (ad-hoc, `flags=0x2(adhoc)`, sealed `_CodeSignature`) | `0xE8008014` The executable contains an invalid signature. |

All three fail in the same frame:

```
Failed to verify code signature of
  /var/installd/Library/Caches/com.apple.mobile.installd.staging/temp.*/extracted/SignTest.app
  (MIInstallerErrorDomain error 13)
    FunctionName = +[MICodeSigningVerifier _validateSignatureAndCopyInfoForURL:withOptions:error:]
    LegacyErrorString = ApplicationVerificationFailed
```

which calls `MISValidateSignatureAndCopyInfo` in `/usr/lib/libmis.dylib`.

## Everything past that gate already passes

The same app, pushed in through vphoned's `apps.install` — which re-signs in
the container with `vp_sign_app_for_install` and registers the bundle itself,
never touching installd or misagent — installs and runs:

```
apps.install → {"bundle_id":"wiki.qaq.vphone.signtest","containerized":true,…}
apps.launch  → {"frontmost_verified":true,"pid":591}
SpringBoard: … taskState: Running; visibility: Foreground
```

So the kernel side (`amfi_trustcache`, `jb.post_validation`,
`jb.amfi_execve`, `jb.cred_label_update_execve`), lsd registration and
SpringBoard's launch path all accept a bundle with no certificate and no
profile. Only installd's install-time check does not.

That also means SpringBoard does **not** reject an ad-hoc signature at launch.
The `0xE8008026` SpringBoard logs in the free-certificate case is a different
gate — online authorization — and is what `mis_trust_auth` covers.

## libmis takes an option for exactly this

`MISValidateSignatureAndCopyInfo`'s options dictionary is read by string key.
The keys are in libmis's cstring section and are, in cache order:

```
UnauthoritativeLaunch  AuthoritativeLaunch  ExpectedHash  AllowAdHocSigning
ValidateSignatureOnly  LogResourceErrors  UniversalFileOffset
UseSoftwareSigningCert  OnlineAuthorization  OnlineCheckType
RespectUppTrustAndAuthorization  HonorBlocklist  DetachedSignature
TrustCacheOnly  SkipProfileIdentifierPolicy  AllowLaunchWarnings
GetLocalLaunchWarningData  MainExecutablePath
OnlineAuthorizationOnAllMatchingProfiles
```

and the keys it returns in `info`:

```
ValidatedByProfile  ValidatedByUniversalProfile  ValidatedByLocalProfile
SignerType  SignerCertificate  SigningID  SigningTime  TeamID  CdHash
SignatureVersion  ProfileUUID  IsNativeForPlatform  LaunchWarningData
```

There is no SDK header for these; the symbols `kMISValidationOption*` are not
in libmis's export trie, so searching for the symbol name finds nothing and
searching for the string value finds everything.

A probe app — unsandboxed (`com.apple.private.security.no-container`,
`no-sandbox`), so it could read the subject out of `/private/var/tmp` — called
the function directly against the `codesign --sign -` bundle:

```
[no options]                                          -> 0xE8008014
[AllowAdHocSigning]                                   -> 0x0
    info keys: CdHash, Entitlements, IsNativeForPlatform, SignatureVersion,
               SignerType, SigningID, ValidatedByLocalProfile,
               ValidatedByProfile, ValidatedByUniversalProfile
    SignerType = 1   SigningID = wiki.qaq.vphone.signtest
    ValidatedByProfile = 0   CdHash = <20 bytes>
[ValidateSignatureOnly]                               -> 0xE8008014
[AllowAdHocSigning + ValidateSignatureOnly]           -> 0x0
[AllowAdHocSigning + SkipProfileIdentifierPolicy]     -> 0x0
[TrustCacheOnly]                                      -> 0xE8008014
```

Two things follow. The option alone is sufficient — installd simply never
passes it. And MIS fills the whole info dictionary itself on success, so
nothing has to be synthesised; a hook that faked a return code without
`CdHash` and `Entitlements` would break installd further along.

Against the *ldid*-shaped signature the project's own signer writes, the same
call returns `0xE800801C` with or without the option. "No signature at all" is
therefore out of reach and is not worth pursuing: everything downstream needs
the cdhash only a signature carries, and Xcode's "Sign to Run Locally"
(`CODE_SIGN_IDENTITY = "-"`) supplies one for free.

## Two details that cost time

The first argument is a **path string**, not a URL. Handing it an `NSURL`
aborts the calling process inside libmis with
`-[NSURL length]: unrecognized selector sent to instance`.

On arm64e the `__DATA,__interpose` section the compiler is asked for lands in
`__AUTH_CONST` instead, because its pointers are signed. dyld honours it
anyway — verified by loading the real `libmisfix.dylib` from a probe app's own
bundle through a load command and calling the linked symbol:

```
linked call, no options -> 0x0        (0xE8008014 without the hook)
```

## What was built

`system-installd-cfw-adhoc_signature` — `VPhoneGuestComponents/MISFix/MISFix-vphone.c`,
built as `/usr/lib/libmisfix.dylib`, attached to `/usr/libexec/installd` by a
`LC_LOAD_WEAK_DYLIB` that `cfw install` inserts. It interposes
`MISValidateSignatureAndCopyInfo` and
`MISValidateSignatureAndCopyInfoWithProgress`, adds `AllowAdHocSigning` to the
caller's options, and calls through. Nothing in the dyld shared cache is
touched — deliberately, since issue #532 is `mis_trust_auth` writing a cache
code page and leaving a 27.0 guest unable to boot.

### Still open

`MICodeSigningVerifier` lives in MobileInstallation, a shared-cache dylib, so
its call into libmis is cache-internal. dyld's interposition is documented to
patch the cache's own uses of an interposed symbol, and the probe above
confirms the section shape is honoured on arm64e, but the cache-internal case
itself has not been observed yet — that needs the hook running inside installd
on a guest, which is the 27.0 integration test.

Only installd carries the hook. SpringBoard was left alone on purpose: the
evidence above says it does not reject an ad-hoc signature, and a mistake
there is a black screen rather than a failed install.

---

# Part two: the device the profile names

A real, paid-team app fails a step later. `AirBuild-Debug-main-da1b84d8.ipa`,
signed `Apple Development: Lakr Aream (ZL3L65D2SL)`, team `QDJ93ZUQ9B`, whose
embedded profile provisions eight real devices and no VM:

```
Failed to install embedded profile for plus.yellow.AirBuild : 0xE8008012
  (This provisioning profile cannot be installed on this device.)
  -[MIInstallableBundle _installEmbeddedProfilesWithError:]
```

This one is correct behaviour and always has been: the VM's UDID is in nobody's
`ProvisionedDevices`. Xcode papers over it for a *free* personal team by
registering whatever device is plugged in — which is why
`iOS Team Provisioning Profile: wiki.qaq.vphone.test` (team `M4Z5DVY94F`) lists
both `0000FE01-04A9F39591FF643D` and `0000FE01-5F651C7ECC040381`. For a paid
team there is no auto-registration, and a fresh `vm create` means doing it
again by hand.

## Which process decides, and what it asks

installd reports the error but does not make the decision; misagent does. Its
imports and strings give the whole algorithm away:

```
$ nm -u misagent | grep '^_MIS'
_MISProfileCreateDataRepresentation  _MISProfileCreateWithData
_MISProfileCreateWithFile            _MISProfileGetValue
_MISProfileIsDEREncoded              _MISProfileValidateSignature
```

No `MISProvisioningProfileIncludesDevice` — misagent reads `ProvisionedDevices`
itself and does its own comparison. Its strings, in the order the code uses
them:

```
amfi_emulate_device_udid   "Using emulated device UDID: %{public}@"
"got NULL when querying UDID"   "got non-string when querying UDID"
"could not get device UDID"   deviceUDID   UniqueDeviceID
ProvisionedDevices   ProvisionsAllDevices
```

So it first looks for an emulated UDID in the kernel's codesigning
configuration, then falls back. Measured in the guest:

```
sysctlbyname("security.codesigning.config") -> 0, size 4, bytes 0x000000CC
MGCopyAnswer(UniqueDeviceID)     = 0000FE01-5F651C7ECC040381
MGCopyAnswer(UniqueDeviceIDData) = <25 bytes, the same string>
MGCopyAnswer(SerialNumber)       = vphone-1337
MGCopyAnswer(UniqueChipID)       = 6873931737165202305   (0x5F651C7ECC040381)
```

`security.codesigning.config` is a four-byte flags word, not a dictionary — it
cannot carry a UDID, and `amfi_emulate_device_udid` appears in neither the
vphone600 kernelcache nor TXM. That path is dead on this board, so the
MobileGestalt fallback is what always runs.

`MGCopyAnswer` is exported from libMobileGestalt, and misagent imports it
across an image boundary, so it is interposable.

## Where the guest's own UDID comes from

Worth writing down, because it rules out the alternatives. TXM builds it,
before the kernel runs, out of the device tree:

```
/chosen/chip-id            CPID        (0x0000FE01, fixed by the virtual SoC)
/chosen/unique-chip-id     ECID
/product/udid-version      picks the v2 or v3 format
```

TXM's strings: `successfully queried the UniqueDeviceIDv2 from the device
tree`, `unsupported UniqueDeviceID version: %u`, `unable to find udid-version
property in /product`.

The host predicts the same string from the same inputs —
`VPhoneVirtualMachine.resolveDeviceIdentity` reads `_ECID` off the
`VZMacMachineIdentifier` and formats `"%08X-%016llX"` against
`VPhoneHardware.udidChipID = 0xFE01`, then writes `udid-prediction.txt`. The
prediction is reliable because both sides compute it the same way.

Two consequences. `data_ark.plist` does **not** hold it — a live guest's copy
has eleven keys and `UniqueDeviceID` is not among them — so no daemon can
change it by writing a file. And reproducing a real iPhone's UDID is
impossible even in principle: `chip-id` is fixed at `0x0000FE01`, while a real
device's is something like `0x00008150`, and `unique-chip-id` is the ECID the
guest's SHSH blob is issued against, so changing it means restoring the VM
again.

## What was built

`system-misagent-cfw-device_identity` — the same `libmisfix.dylib`, attached to
`/usr/libexec/misagent`, interposing `MGCopyAnswer` and `MGCopyAnswerWithError`
and answering `UniqueDeviceID` with the value in `libmisfix.plist`. Set it to a
device the team has already registered and that team's profiles install here,
with no portal round trip and nothing to redo after a rebuild. Absent or empty,
the hook is inert.

The settings file is read from `/var/db/vphone/misfix.plist` first and
`/usr/lib/libmisfix.plist` second, cached against mtime and size so an edit
takes effect on the next query with nothing restarted. The data-volume path is
the one a running guest can be reconfigured through; the `/usr/lib` copy is
what `cfw install` ships, and it is only written when the guest has none, so
re-running the installer never puts an empty file over a UDID someone set.

### The inconsistency this creates

The guest now answers two ways about which device it is. Xcode, `devicectl`
and lockdown still see its own UDID; only the processes carrying the hook see
the configured one. That is deliberate and was accepted explicitly — making
the two agree would mean a re-restore for a UDID that still could not match a
real device's.
