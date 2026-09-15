# vphone-cli: App Login & Device Identity Research Notes

> Third-party research notes from an outside evaluation of this repository.
> Scope: can vphone-cli be used to run and log into real third-party apps
> (e.g. Instagram) with a throwaway account, and what role Apple ID /
> iCloud plays (or doesn't) in that.

## TL;DR

- **No iCloud / Apple ID account is needed.** Activation is bypassed
  ("hackivation"): `mobileactivationd` is patched so that
  `-[DeviceType should_hactivate]` always returns `YES`, so the VM
  self-activates without talking to Apple's activation servers.
- **Apple ID / iCloud sign-in does not work** (no Secure Enclave in the VM,
  no clear path). The App Store does not work either — apps must be
  sideloaded as `.ipa` / `.tipa`.
- **Third-party app logins that don't depend on Apple ID** (Instagram,
  TikTok, etc. use their own username/password auth) are *possible in
  principle* but explicitly **off the project's supported path**. Some
  users report these apps crashing on launch, and the maintainer has
  stated that bypassing those apps' security checks is not something this
  project helps with.

## Activation & identity: what is patched, what is left alone

Relevant sources in this repo:

| Component | What happens | Where |
| --------- | ------------ | ----- |
| `mobileactivationd` | `-[DeviceType should_hactivate]` IMP is patched to return `YES` (activation-lock-free self-activation) | `scripts/patchers/cfw_patch_mobileactivationd.py` |
| `kern.hv_vmm_present` sysctl | Renamed in the kernel (`h` → `X`), so most consumers get `ENOENT` and conclude "not a VM". Blacklisted sign-in-adjacent dylibs are left *unpatched* so they keep their stock behavior. | `scripts/patchers/cfw_patch_hv_vmm_dsc.py`, `cfw_patch_hv_vmm_rootfs.py` |
| Apple ID / activation daemons | Deliberately **excluded** from the hv_vmm_present mangle: `mobileactivationd`, `adid`, `fairplaydeviceidentityd`, `AuthKit`, `AAAFoundation`, `IDSFoundation`, `DeviceIdentity`, `DeviceCheckInternal`, `MobileActivation.framework`, APS, StoreKit/appstored, FindMy, CDP, etc. | `DONT_PATCH_ROOTFS_PATHS` / `DONT_PATCH_INSTALL_NAMES` |

The intent of the blacklist is to avoid breaking the *plumbing* that
sign-in-adjacent daemons rely on (see
`research/hv_vmm_present_usermode_xrefs.md`, which describes the blacklist
as "high-leverage for 'make iMessage/iCloud trust this device'"), but in
practice full Apple ID sign-in still fails — see below.

## Apple ID / iCloud / App Store status (from upstream issues)

| Issue | Outcome |
| ----- | ------- |
| [#326 — Cannot log in the Apple ID](https://github.com/Lakr233/vphone-cli/issues/326) | "this is currently not yet supported" |
| [#393 — Does App Store Sign In Works?](https://github.com/Lakr233/vphone-cli/issues/393) | "apple id sign in is not working and is blocked due to SEP issues, currently we do not have a clear way of making it work" |
| [#158 — Unable to Add iCloud Account (Jailbreak)](https://github.com/Lakr233/vphone-cli/issues/158) | "Verification failed" after correct Apple ID + password; not fixed |
| [#282 — Does appstore work?](https://github.com/Lakr233/vphone-cli/issues/282) | App Store does not work; workaround for IPA sourcing: `https://armconverter.com/decryptedappstore/us` |
| [#14 — App Store support](https://github.com/Lakr233/vphone-cli/issues/14) | App Store "too complex to handle", not planned |

Root cause per the maintainer: **SEP** (Secure Enclave) — a VM has none,
and there is no clear way to satisfy the SEP-derived device attestation
that Apple ID sign-in and App Store purchase flows require.

## Third-party app logins (Instagram as the example)

### What works / should work

- Instagram auth is **app-level** (Instagram's own username/password or
  OAuth), not Apple ID–based. Installing an Instagram `.ipa` (via the
  VM's Install menu or the `ipa_install` control command) and typing a
  test-account login over VNC or injected touches does not depend on the
  broken Apple ID stack.
- SMS/email 2FA and verification-code flows work like on any device.
- The automation surface (touch injection, screenshots, clipboard,
  `open_url`, accessibility tree, GPS spoofing) is sufficient to drive a
  login flow end-to-end.

### What is fragile or broken

- **Launch-time crashes**: [#212](https://github.com/Lakr233/vphone-cli/issues/212)
  (also #211, #165) report Instagram / TikTok / YouTube / WeChat crashing
  on launch. The maintainer's response: the project "isn't meant for TT
  or WeChat", those apps' security checks exist, and *bypassing them is
  not allowed to be shared within this project*. The `exp` variant's
  anti-VM-detection patches are framed as research, not as a supported
  path for specific consumer apps.
- **Push notifications**: APNs token provisioning rides on the device
  identity / activation stack that cannot fully sign in, so push is
  expected to be degraded or broken even if the app itself runs.
- **Account risk**: sideloaded decrypted IPA + jailbroken VM + automated
  touches is a classic anti-abuse fingerprint. Expect possible
  verification challenges, and don't use an account you care about.

### Practical recipe (unsupported, at your own risk)

1. Create the VM with `--variant jb` (or `exp` if you are researching
   detection behavior). During iOS setup **do not pick Japan or the EU**
   as region (regulatory checks the VM can't satisfy) — see README FAQ.
2. Skip Apple ID during setup; activation is already bypassed.
3. Sideload the target app's `.ipa` (Install menu, `ipa_install`, or the
   `--packages` launch flag).
4. Log in with a throwaway account via VNC (`vnc://<vm-ip>:5901`) or the
   control socket / vphone-mcp.

If reliable production-grade automation for a specific consumer app is
the goal, a physical test iPhone is the robust route; vphone-cli is
strongest for app testing / research where you control the app.

## Host security posture reminder

Running vphone-cli requires SIP/AMFI relaxation on the host (full SIP
disable + `amfi_get_out_of_my_way=1`, or the debug-relaxed SIP +
`vphone-amfidont` allowlist route). This weakens macOS security; use a
dedicated test machine, not a daily driver.
