
Comprehensive BuildManifest.plist Comparison Results
The analysis script is saved at /Users/qaq/Documents/GitHub/vphone-cli/Scripts/analyze_manifests.py and the full output is available at the tool results path. Here is the synthesized analysis:
---
1. Identity Count Overview
┌────────────────┬────────────┬─────────────────────────────────────────────────────────┐
│     Source     │ Identities │                      DeviceClasses                      │
├────────────────┼────────────┼─────────────────────────────────────────────────────────┤
│ iPhone 26.1    │ 5          │ All d47ap                                               │
├────────────────┼────────────┼─────────────────────────────────────────────────────────┤
│ iPhone 26.3    │ 5          │ All d47ap                                               │
├────────────────┼────────────┼─────────────────────────────────────────────────────────┤
│ CloudOS 26.1   │ 6          │ j236cap, j475dap, vphone600ap (x2), vresearch101ap (x2) │
├────────────────┼────────────┼─────────────────────────────────────────────────────────┤
│ KnownWork 26.1 │ 5          │ All vresearch101ap                                      │
└────────────────┴────────────┴─────────────────────────────────────────────────────────┘
---
2. CloudOS 26.1 Identity Structure (6 identities)
┌───────┬────────────────┬─────────────────────────────────────────────────────┬────────────────────────────────────────────────────┬────────────────────────────────────────────────────────────────────┐
│ Index │  DeviceClass   │                       Variant                       │                     BuildStyle                     │                           Manifest Keys                            │
├───────┼────────────────┼─────────────────────────────────────────────────────┼────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────┤
│ [0]   │ j236cap        │ Darwin Cloud Customer Erase Install (IPSW)          │ LLB/iBSS/iBEC -> release                           │ 37 keys (server hardware: ANE, ANS, CIO, TMU, GFX, PMP, SIO, etc.) │
├───────┼────────────────┼─────────────────────────────────────────────────────┼────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────┤
│ [1]   │ j475dap        │ Darwin Cloud Customer Erase Install (IPSW)          │ unknown (no path)                                  │ 0 keys (empty placeholder)                                         │
├───────┼────────────────┼─────────────────────────────────────────────────────┼────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────┤
│ [2]   │ vphone600ap    │ Darwin Cloud Customer Erase Install (IPSW)          │ LLB/iBSS/iBEC -> research (RELEASE build)          │ 29 keys (includes Battery/Logo UI assets)                          │
├───────┼────────────────┼─────────────────────────────────────────────────────┼────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────┤
│ [3]   │ vresearch101ap │ Darwin Cloud Customer Erase Install (IPSW)          │ LLB/iBSS/iBEC -> research (RELEASE build)          │ 20 keys (no UI assets -- stripped down)                            │
├───────┼────────────────┼─────────────────────────────────────────────────────┼────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────┤
│ [4]   │ vphone600ap    │ Research Darwin Cloud Customer Erase Install (IPSW) │ LLB/iBSS/iBEC -> research (RESEARCH_RELEASE build) │ 29 keys (research kernelcache, RESEARCH_RELEASE boot chain)        │
├───────┼────────────────┼─────────────────────────────────────────────────────┼────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────┤
│ [5]   │ vresearch101ap │ Research Darwin Cloud Customer Erase Install (IPSW) │ LLB/iBSS/iBEC -> research (RESEARCH_RELEASE build) │ 20 keys (research kernelcache, RESEARCH_RELEASE boot chain)        │
└───────┴────────────────┴─────────────────────────────────────────────────────┴────────────────────────────────────────────────────┴────────────────────────────────────────────────────────────────────┘
Key distinction between pairs:
- CloudOS[2] vs [4] (both vphone600ap): [2] uses RELEASE boot chain + release kernelcache; [4] uses RESEARCH_RELEASE boot chain + research kernelcache + txm.iphoneos.research.im4p (vs .release)
- CloudOS[3] vs [5] (both vresearch101ap): Same pattern -- [3] is RELEASE, [5] is RESEARCH_RELEASE
- vphone600ap identities have 29 keys (includes UI: AppleLogo, Battery*, RecoveryMode, RestoreLogo)
- vresearch101ap identities have 20 keys (no UI assets at all)
---
3. KnownWork 26.1 Identity Structure (5 identities)
All 5 identities have DeviceClass=vresearch101ap and Variant=Darwin Cloud Customer Erase Install (IPSW). They differ in what they contain:
┌───────┬──────┬────────────────────────────────────────────────────────────────────────────────────────────────────┬─────────────────────────────────────────┬────────────────────────────────────┐
│ Index │ Keys │                                        Notable Differences                                         │                 OS DMG                  │           RestoreRamDisk           │
├───────┼──────┼────────────────────────────────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────┼────────────────────────────────────┤
│ [0]   │ 21   │ Minimal + RecoveryMode; has Cryptex1 size hints in Info; LLB=RELEASE but iBoot=RESEARCH_RELEASE    │ 043-53486-120.dmg.aea (iPhone)          │ 043-53775-129.dmg (CloudOS)        │
├───────┼──────┼────────────────────────────────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────┼────────────────────────────────────┤
│ [1]   │ 29   │ Full: includes Cryptex1 (6 keys from iPhone) + all UI assets; RESEARCH_RELEASE boot chain          │ 043-53486-120.dmg.aea (iPhone)          │ 043-54236-129.dmg (iPhone Upgrade) │
├───────┼──────┼────────────────────────────────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────┼────────────────────────────────────┤
│ [2]   │ 23   │ UI assets (AppleLogo, RecoveryMode, RestoreLogo) but no Cryptex1; RESEARCH_RELEASE                 │ 043-53486-120.dmg.aea (iPhone)          │ 043-53775-129.dmg (CloudOS)        │
├───────┼──────┼────────────────────────────────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────┼────────────────────────────────────┤
│ [3]   │ 23   │ Identical structure to [2] but different RestoreRamDisk                                            │ 043-53486-120.dmg.aea (iPhone)          │ 043-54236-129.dmg (iPhone Upgrade) │
├───────┼──────┼────────────────────────────────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────┼────────────────────────────────────┤
│ [4]   │ 16   │ Most stripped: no LLB, no iBoot, no SEP, no RestoreSEP, no RestoreDeviceTree; uses Recovery OS DMG │ 043-53377-129.dmg.aea (Recovery iPhone) │ 043-53775-129.dmg (CloudOS)        │
└───────┴──────┴────────────────────────────────────────────────────────────────────────────────────────────────────┴─────────────────────────────────────────┴────────────────────────────────────┘
---
4. iPhone 26.1 vs 26.3 Comparison
Both have identical identity structure (5 identities, all d47ap):
- [0] Customer Erase Install (103 keys)
- [1] Customer Upgrade Install (103 keys)
- [2] Research Customer Erase Install (103 keys)
- [3] Research Customer Upgrade Install (103 keys)
- [4] Recovery Customer Install (30 keys)
Only DMG filename numbers changed between 26.1 and 26.3 -- no structural key additions or removals. The changes are:
- OS DMG: 043-53486-120 -> 043-48577-143 (and 043-53377-129 -> 043-47439-152 for Recovery)
- Cryptex1 DMGs: 043-54062-129/043-54303-126 -> 043-48216-152/043-48700-151
- RestoreRamDisk: 043-53775-129/043-54236-129 -> 043-48593-153/043-48665-152
- ExclaveOS: 043-54839-128 -> 043-48043-152
- BasebandFirmware: Mav24-2.10.03.Release -> Mav24-2.40.01.Release
- All firmware .im4p paths are identical (same hardware generation)
---
5. CRITICAL: KnownWork Entry Source Tracing
This is the most important finding. Here is where each component type in KnownWork comes from:
Boot Chain Components (from CloudOS)
All vresearch101 boot chain firmware is exclusively from CloudOS, specifically from the Research identities [4] and [5]:
┌────────────────────┬──────────────────────────────────────────┬───────────────────────────────────────────────┐
│     Component      │               Path Pattern               │            Primary CloudOS Source             │
├────────────────────┼──────────────────────────────────────────┼───────────────────────────────────────────────┤
│ LLB                │ LLB.vresearch101.RELEASE.im4p            │ CloudOS[2]/[3] (non-research)                 │
├────────────────────┼──────────────────────────────────────────┼───────────────────────────────────────────────┤
│ LLB                │ LLB.vresearch101.RESEARCH_RELEASE.im4p   │ CloudOS[4]/[5] (research)                     │
├────────────────────┼──────────────────────────────────────────┼───────────────────────────────────────────────┤
│ iBSS               │ iBSS.vresearch101.RELEASE.im4p           │ CloudOS[2]/[3]                                │
├────────────────────┼──────────────────────────────────────────┼───────────────────────────────────────────────┤
│ iBSS               │ iBSS.vresearch101.RESEARCH_RELEASE.im4p  │ CloudOS[4]/[5]                                │
├────────────────────┼──────────────────────────────────────────┼───────────────────────────────────────────────┤
│ iBEC               │ iBEC.vresearch101.RELEASE.im4p           │ CloudOS[2]/[3]                                │
├────────────────────┼──────────────────────────────────────────┼───────────────────────────────────────────────┤
│ iBEC               │ iBEC.vresearch101.RESEARCH_RELEASE.im4p  │ CloudOS[4]/[5]                                │
├────────────────────┼──────────────────────────────────────────┼───────────────────────────────────────────────┤
│ iBoot              │ iBoot.vresearch101.RESEARCH_RELEASE.im4p │ CloudOS[4]/[5] only                           │
├────────────────────┼──────────────────────────────────────────┼───────────────────────────────────────────────┤
│ DeviceTree         │ DeviceTree.vphone600ap.im4p              │ CloudOS[2]/[4] (vphone600ap identities)       │
├────────────────────┼──────────────────────────────────────────┼───────────────────────────────────────────────┤
│ KernelCache        │ kernelcache.research.vphone600           │ CloudOS[4] only (research vphone600ap)        │
├────────────────────┼──────────────────────────────────────────┼───────────────────────────────────────────────┤
│ RestoreKernelCache │ kernelcache.release.vphone600            │ CloudOS[2]/[4]                                │
├────────────────────┼──────────────────────────────────────────┼───────────────────────────────────────────────┤
│ SEP/RestoreSEP     │ sep-firmware.vphone600.RELEASE.im4p      │ CloudOS[2]/[4] (for KW[0])                    │
├────────────────────┼──────────────────────────────────────────┼───────────────────────────────────────────────┤
│ SEP/RestoreSEP     │ sep-firmware.vresearch101.RELEASE.im4p   │ CloudOS[3]/[5] (for KW[1-4])                  │
├────────────────────┼──────────────────────────────────────────┼───────────────────────────────────────────────┤
│ SPTM               │ sptm.vresearch1.release.im4p             │ CloudOS[2]/[3]/[4]/[5] (all vresearch/vphone) │
├────────────────────┼──────────────────────────────────────────┼───────────────────────────────────────────────┤
│ TXM (research)     │ txm.iphoneos.research.im4p               │ CloudOS[4]/[5]                                │
└────────────────────┴──────────────────────────────────────────┴───────────────────────────────────────────────┘
OS & Data DMGs (from iPhone 26.1)
The actual OS system images come from the iPhone 26.1 IPSW, not from CloudOS:
┌──────────────────────────────────┬──────────────────────────────────┬─────────────────────────────────────┐
│            Component             │               Path               │               Source                │
├──────────────────────────────────┼──────────────────────────────────┼─────────────────────────────────────┤
│ OS                               │ 043-53486-120.dmg.aea            │ iPhone26.1[0-3] (main system image) │
├──────────────────────────────────┼──────────────────────────────────┼─────────────────────────────────────┤
│ Ap,SystemVolumeCanonicalMetadata │ 043-53486-120.dmg.aea.mtree      │ iPhone26.1[0-3]                     │
├──────────────────────────────────┼──────────────────────────────────┼─────────────────────────────────────┤
│ StaticTrustCache                 │ 043-53486-120.dmg.aea.trustcache │ iPhone26.1[0-3]                     │
├──────────────────────────────────┼──────────────────────────────────┼─────────────────────────────────────┤
│ SystemVolume                     │ 043-53486-120.dmg.aea.root_hash  │ iPhone26.1[0-3]                     │
└──────────────────────────────────┴──────────────────────────────────┴─────────────────────────────────────┘
For KnownWork[4] (the Recovery identity), the OS is 043-53377-129.dmg.aea from iPhone26.1[4] (Recovery).
Cryptex1 Components (from iPhone 26.1 ONLY)
These exist only in KnownWork[1] and come entirely from iPhone, never from CloudOS:
┌────────────────────────────────┬───────────────────────┬─────────────────┐
│           Component            │         Path          │     Source      │
├────────────────────────────────┼───────────────────────┼─────────────────┤
│ Cryptex1,AppOS                 │ 043-54062-129.dmg     │ iPhone26.1[0-3] │
├────────────────────────────────┼───────────────────────┼─────────────────┤
│ Cryptex1,SystemOS              │ 043-54303-126.dmg.aea │ iPhone26.1[0-3] │
├────────────────────────────────┼───────────────────────┼─────────────────┤
│ + TrustCache + Volume for each │                       │ iPhone26.1[0-3] │
└────────────────────────────────┴───────────────────────┴─────────────────┘
RestoreRamDisk (mixed sources)
- KnownWork[0], [2], [4] use 043-53775-129.dmg -- shared path between CloudOS (all identities) and iPhone26.1 Erase identities
- KnownWork[1], [3] use 043-54236-129.dmg -- from iPhone26.1 Upgrade identities [1]/[3] only
UI Assets (from CloudOS Research vphone600ap)
- AppleLogo -> researchlogo@2556~iphone.im4p -- from CloudOS[4] (Research vphone600ap)
- RecoveryMode -> recoverymode@2556~iphone-USBc.im4p -- shared by CloudOS[2]/[4] and iPhone26.1
- RestoreLogo -> researchlogo@2556~iphone.im4p -- from CloudOS[4]
Info Dict Differences (KnownWork vs CloudOS)
The RecoveryMode entry has a notable Info dict difference:
- KnownWork sets IsiBootEANFirmware=True (CloudOS sets False)
- CloudOS has IsFirmwarePayload key that KnownWork removes
KnownWork[0] uniquely has extra Info keys: Cryptex1,AppOSSize=14 and Cryptex1,SystemOSSize=4722 even though it does not actually carry Cryptex1 manifest entries.
---
6. Key Universe Summary
- 115 total unique Manifest keys across all sources
- 63 keys are iPhone-only (hardware-specific: AOP, AVE, Baseband, DCP, ISP, Multitouch, Savage, Yonkers, eUICC, etc.)
- 23 keys are shared across all 4 sources (the core boot/restore chain)
- 12 keys are CloudOS-only (server hardware: ANE1, CIO, TMU, Battery UI assets)
- 11 keys are shared between CloudOS and iPhone but absent from KnownWork (ANE, ANS, GFX, PMP, SIO, ftap/ftsp/rfta/rfts, iBootData)
- 6 keys are in KnownWork + iPhone only (the Cryptex1 entries -- absent from CloudOS)
---
Practical Takeaway for Building a Minimal vresearch1 Manifest
To build a working vresearch1 manifest, you need to combine:
1. Boot chain from CloudOS vresearch101ap Research identities [4]/[5]: LLB, iBSS, iBEC, iBoot (all RESEARCH_RELEASE), SPTM, TXM (research)
2. Device-specific firmware from CloudOS vphone600ap [2]/[4]: DeviceTree, KernelCache (research), RestoreKernelCache, SEP
3. OS system image from iPhone IPSW: OS DMG, mtree, trustcache, root_hash, RestoreRamDisk
4. Optionally Cryptex1 from iPhone IPSW (only if you need the full runtime with App/System cryptexes)
5. UI assets from CloudOS vphone600ap Research [4] if you want boot logos and recovery mode graphics
6. Set DeviceClass=vresearch101ap, Variant=Darwin Cloud Customer Erase Install (IPSW), FDRSupport=False
